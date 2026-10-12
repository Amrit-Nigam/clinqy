//! Keyboard and mouse through SendInput, like a person's: real clicks (the user's pointer put back after), keys
//! on the user's layout with Shift where needed, Unicode for characters no key makes, chords like ctrl+shift+t.
//! Keys only go out while the target app is in front, so they can't land in some other window.

use clinqy_core::platform::Point;
use parking_lot::Mutex;
use std::time::Duration;
use windows::Win32::Foundation::POINT;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::{GetCursorPos, GetSystemMetrics, SetCursorPos, SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN};

/// Marks our own injected input, so the hotkey hook can ignore it.
pub const INJECTED_TAG: usize = 0x434C_4E51; // "CLNQ"

/// The window keys are meant for (None = whatever is in front).
static TARGET: Mutex<Option<isize>> = Mutex::new(None);

pub fn set_target(hwnd: Option<isize>) {
    *TARGET.lock() = hwnd;
}

/// Keys may go out: the target (if any) is in front, or can be brought there.
fn target_ready() -> bool {
    let Some(t) = *TARGET.lock() else { return true };
    if crate::apps::foreground().map(|f| f.0 == t || f.1.is_some() && crate::apps::root_owner(f.1.unwrap()) == t).unwrap_or(false) {
        return true;
    }
    crate::apps::bring_to_front(t)
}

fn send(inputs: &[INPUT]) {
    unsafe {
        SendInput(inputs, std::mem::size_of::<INPUT>() as i32);
    }
}

fn key_input(vk: VIRTUAL_KEY, scan: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: vk, wScan: scan, dwFlags: flags, time: 0, dwExtraInfo: INJECTED_TAG } },
    }
}

fn is_extended(vk: VIRTUAL_KEY) -> bool {
    matches!(
        vk,
        VK_LEFT | VK_RIGHT | VK_UP | VK_DOWN | VK_HOME | VK_END | VK_PRIOR | VK_NEXT | VK_INSERT | VK_DELETE | VK_RMENU | VK_RCONTROL | VK_LWIN | VK_RWIN | VK_APPS | VK_DIVIDE | VK_NUMLOCK
    )
}

fn vk_down_up(vk: VIRTUAL_KEY) -> (INPUT, INPUT) {
    let scan = unsafe { MapVirtualKeyW(vk.0 as u32, MAPVK_VK_TO_VSC) } as u16;
    let ext = if is_extended(vk) { KEYEVENTF_EXTENDEDKEY } else { KEYBD_EVENT_FLAGS(0) };
    (key_input(vk, scan, ext), key_input(vk, scan, ext | KEYEVENTF_KEYUP))
}

fn named_key(name: &str) -> Option<VIRTUAL_KEY> {
    Some(match name {
        "return" | "enter" => VK_RETURN,
        "tab" => VK_TAB,
        "space" | "spacebar" => VK_SPACE,
        "backspace" => VK_BACK,
        "delete" | "del" | "forwarddelete" => VK_DELETE,
        "esc" | "escape" => VK_ESCAPE,
        "home" => VK_HOME,
        "end" => VK_END,
        "pageup" | "pgup" => VK_PRIOR,
        "pagedown" | "pgdn" => VK_NEXT,
        "left" => VK_LEFT,
        "right" => VK_RIGHT,
        "up" => VK_UP,
        "down" => VK_DOWN,
        "insert" | "ins" => VK_INSERT,
        "printscreen" | "prtsc" => VK_SNAPSHOT,
        "capslock" => VK_CAPITAL,
        "menu" | "apps" | "contextmenu" => VK_APPS,
        "win" | "windows" | "super" | "meta" => VK_LWIN,
        "volumeup" => VK_VOLUME_UP,
        "volumedown" => VK_VOLUME_DOWN,
        "mute" | "volumemute" => VK_VOLUME_MUTE,
        "playpause" | "play" => VK_MEDIA_PLAY_PAUSE,
        "nexttrack" => VK_MEDIA_NEXT_TRACK,
        "prevtrack" | "previoustrack" => VK_MEDIA_PREV_TRACK,
        f if f.len() >= 2 && f.starts_with('f') && f[1..].parse::<u16>().map(|n| (1..=24).contains(&n)).unwrap_or(false) => {
            VIRTUAL_KEY(VK_F1.0 + f[1..].parse::<u16>().unwrap() - 1)
        }
        _ => return None,
    })
}

fn named_char(name: &str) -> Option<char> {
    Some(match name {
        "minus" | "hyphen" | "dash" => '-',
        "plus" => '+',
        "equal" | "equals" => '=',
        "comma" => ',',
        "period" | "dot" => '.',
        "slash" => '/',
        "backslash" => '\\',
        "semicolon" => ';',
        "quote" => '\'',
        "backtick" | "grave" => '`',
        "leftbracket" => '[',
        "rightbracket" => ']',
        _ => return None,
    })
}

/// The key and the modifiers that make `ch` on the current layout (None: no key makes it).
fn key_for_char(ch: char) -> Option<(VIRTUAL_KEY, bool, bool, bool)> {
    let mut buf = [0u16; 2];
    if ch.encode_utf16(&mut buf).len() != 1 {
        return None;
    }
    let r = unsafe { VkKeyScanW(buf[0]) };
    if r == -1 {
        return None;
    }
    let vk = VIRTUAL_KEY((r & 0xff) as u16);
    let mods = (r >> 8) & 0xff;
    Some((vk, mods & 1 != 0, mods & 2 != 0, mods & 4 != 0))
}

/// Presses a chord like "ctrl+shift+t", "enter" or "alt+f4" (cmd counts as ctrl). Err for an unknown key.
pub fn press_combo(combo: &str) -> Result<(), String> {
    let mut mods: Vec<VIRTUAL_KEY> = vec![];
    let mut key: Option<VIRTUAL_KEY> = None;
    let mut shift_needed = false;
    let lower = combo.to_lowercase().replace(' ', "");
    let parts: Vec<&str> = if lower == "+" { vec!["+"] } else { lower.split('+').filter(|p| !p.is_empty()).collect() };
    if parts.is_empty() {
        return Err(format!("unknown key {combo}"));
    }
    for raw in parts {
        let part = if raw.len() > 1 { raw.replace(['_', '-'], "") } else { raw.to_string() };
        match part.as_str() {
            "ctrl" | "control" | "cmd" | "command" | "⌘" | "⌃" => mods.push(VK_CONTROL),
            "shift" | "⇧" => mods.push(VK_SHIFT),
            "alt" | "opt" | "option" | "⌥" => mods.push(VK_MENU),
            p => {
                if let Some(vk) = named_key(p) {
                    // "win" alone is a key; "win+e" makes it a modifier.
                    if key.is_some() && vk == VK_LWIN {
                        mods.push(VK_LWIN);
                    } else if let Some(prev) = key.replace(vk) {
                        if prev == VK_LWIN {
                            mods.push(VK_LWIN);
                        }
                    }
                    continue;
                }
                let ch = named_char(p).or_else(|| (p.chars().count() == 1).then(|| p.chars().next().unwrap()));
                let Some(ch) = ch else { return Err(format!("unknown key {raw:?} in {combo}")) };
                let Some((vk, shift, _, _)) = key_for_char(ch) else { return Err(format!("no key makes {ch:?} on this keyboard layout")) };
                if let Some(prev) = key.replace(vk) {
                    if prev == VK_LWIN {
                        mods.push(VK_LWIN);
                    }
                }
                shift_needed |= shift;
            }
        }
    }
    let Some(key) = key else {
        // Only modifiers ("win", "alt"): press and release them.
        if mods.is_empty() {
            return Err(format!("unknown key {combo}"));
        }
        let mut downs = vec![];
        let mut ups = vec![];
        for m in &mods {
            let (d, u) = vk_down_up(*m);
            downs.push(d);
            ups.insert(0, u);
        }
        if !target_ready() {
            return Err("the app lost focus before the keys could go to it".into());
        }
        send(&[downs, ups].concat());
        return Ok(());
    };
    if shift_needed && !mods.contains(&VK_SHIFT) {
        mods.push(VK_SHIFT);
    }
    mods.dedup();
    if !target_ready() {
        return Err("the app lost focus before the keys could go to it".into());
    }
    let mut seq = vec![];
    for m in &mods {
        seq.push(vk_down_up(*m).0);
    }
    let (d, u) = vk_down_up(key);
    seq.push(d);
    seq.push(u);
    for m in mods.iter().rev() {
        seq.push(vk_down_up(*m).1);
    }
    send(&seq);
    Ok(())
}

/// Types one character the way a keyboard does (its key on this layout), or as Unicode when no plain key makes it.
pub fn type_char(ch: char) -> bool {
    if !target_ready() {
        return false;
    }
    match ch {
        '\n' | '\r' => {
            let (d, u) = vk_down_up(VK_RETURN);
            send(&[d, u]);
            return true;
        }
        '\t' => {
            let (d, u) = vk_down_up(VK_TAB);
            send(&[d, u]);
            return true;
        }
        _ => {}
    }
    if ch.is_ascii() && !ch.is_ascii_control() {
        if let Some((vk, shift, ctrl, alt)) = key_for_char(ch) {
            // AltGr characters go as Unicode: injecting Ctrl+Alt could trigger shortcuts.
            if !ctrl && !alt {
                let mut seq = vec![];
                if shift {
                    seq.push(vk_down_up(VK_SHIFT).0);
                }
                let (d, u) = vk_down_up(vk);
                seq.push(d);
                seq.push(u);
                if shift {
                    seq.push(vk_down_up(VK_SHIFT).1);
                }
                send(&seq);
                return true;
            }
        }
    }
    let mut buf = [0u16; 2];
    let units = ch.encode_utf16(&mut buf);
    let mut seq = vec![];
    for u in units.iter() {
        seq.push(key_input(VIRTUAL_KEY(0), *u, KEYEVENTF_UNICODE));
        seq.push(key_input(VIRTUAL_KEY(0), *u, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
    }
    send(&seq);
    true
}

/// Types text quickly with no rhythm (for addresses and search boxes).
pub fn type_burst(text: &str) -> bool {
    for ch in text.chars() {
        if !type_char(ch) {
            return false;
        }
        std::thread::sleep(Duration::from_millis(4));
    }
    true
}

pub fn cursor() -> Point {
    let mut p = POINT::default();
    unsafe {
        let _ = GetCursorPos(&mut p);
    }
    Point::new(p.x as f64, p.y as f64)
}

pub fn set_cursor(p: Point) {
    unsafe {
        let _ = SetCursorPos(p.x.round() as i32, p.y.round() as i32);
    }
}

fn mouse_input(x: f64, y: f64, flags: MOUSE_EVENT_FLAGS, data: i32) -> INPUT {
    // Absolute coordinates over the whole virtual desktop, normalised to 0…65535.
    let (vx, vy, vw, vh) = unsafe {
        (GetSystemMetrics(SM_XVIRTUALSCREEN), GetSystemMetrics(SM_YVIRTUALSCREEN), GetSystemMetrics(SM_CXVIRTUALSCREEN), GetSystemMetrics(SM_CYVIRTUALSCREEN))
    };
    let nx = (((x - vx as f64) * 65535.0) / (vw.max(2) - 1) as f64).round() as i32;
    let ny = (((y - vy as f64) * 65535.0) / (vh.max(2) - 1) as f64).round() as i32;
    INPUT {
        r#type: INPUT_MOUSE,
        Anonymous: INPUT_0 {
            mi: MOUSEINPUT { dx: nx, dy: ny, mouseData: data as u32, dwFlags: flags | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK, time: 0, dwExtraInfo: INJECTED_TAG },
        },
    }
}

/// A real left click at `p`; the user's pointer is put back where it was.
pub fn click(p: Point) {
    let saved = cursor();
    send(&[mouse_input(p.x, p.y, MOUSEEVENTF_MOVE, 0)]);
    std::thread::sleep(Duration::from_millis(12));
    send(&[mouse_input(p.x, p.y, MOUSEEVENTF_LEFTDOWN, 0)]);
    std::thread::sleep(Duration::from_millis(15));
    send(&[mouse_input(p.x, p.y, MOUSEEVENTF_LEFTUP, 0)]);
    std::thread::sleep(Duration::from_millis(25));
    set_cursor(saved);
}

pub fn double_click(p: Point) {
    let saved = cursor();
    send(&[mouse_input(p.x, p.y, MOUSEEVENTF_MOVE, 0)]);
    for _ in 0..2 {
        send(&[mouse_input(p.x, p.y, MOUSEEVENTF_LEFTDOWN, 0), mouse_input(p.x, p.y, MOUSEEVENTF_LEFTUP, 0)]);
        std::thread::sleep(Duration::from_millis(40));
    }
    set_cursor(saved);
}

/// Scrolls at `p` (positive is up), leaving the pointer there (the run's end puts it back).
pub fn scroll(p: Point, notches: i32) {
    send(&[mouse_input(p.x, p.y, MOUSEEVENTF_MOVE, 0)]);
    std::thread::sleep(Duration::from_millis(10));
    send(&[mouse_input(p.x, p.y, MOUSEEVENTF_WHEEL, notches * 120)]);
}

/// Lets go of any mouse button or modifier our input might have left down (after a cancel or crash).
pub fn release_all() {
    unsafe {
        for vk in [VK_CONTROL, VK_SHIFT, VK_MENU, VK_LWIN] {
            if GetAsyncKeyState(vk.0 as i32) as u16 & 0x8000 != 0 {
                let (_, u) = vk_down_up(vk);
                send(&[u]);
            }
        }
        if GetAsyncKeyState(VK_LBUTTON.0 as i32) as u16 & 0x8000 != 0 {
            let p = cursor();
            send(&[mouse_input(p.x, p.y, MOUSEEVENTF_LEFTUP, 0)]);
        }
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn chords_parse() {
        // Only checks the parser accepts them (nothing is sent without a desktop in tests).
        assert!(super::named_key("pagedown").is_some());
        assert!(super::named_key("f12").is_some());
        assert!(super::named_char("minus").is_some());
    }
}
