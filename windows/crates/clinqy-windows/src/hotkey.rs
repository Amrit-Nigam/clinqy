//! Clinqy's two keys, watched by one low-level keyboard hook:
//! - the summon chord, modifiers only (Ctrl+Alt by default, like ⌃⌥ on the Mac), tapped to open the command bar. Any
//!   other key while it's held means the chord belongs to another shortcut. Right Alt (AltGr, which types characters
//!   on many layouts) never counts as Alt.
//! - push-to-talk, modifiers + a key (Ctrl+H by default): Clinqy listens only while it's held. Its key is swallowed
//!   while held, so the app in front doesn't also get it.
//! Clinqy's own injected keys are ignored.

use std::sync::OnceLock;
use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::*;
use windows::Win32::UI::WindowsAndMessaging::*;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HotEvent {
    Pressed,
    Released,
    /// Another key went down while the chord was held: someone else's shortcut.
    Spoiled,
    /// Push-to-talk went down / came up (its key or its modifiers let go).
    TalkDown,
    TalkUp,
}

#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
struct Mods {
    ctrl: bool,
    alt: bool,
    shift: bool,
    win: bool,
}

struct Hook {
    want: Mods,
    talk: Option<(Mods, u16)>,
    on: Box<dyn Fn(HotEvent) + Send + Sync>,
}

/// Push-to-talk is held (its key's events are swallowed until it comes up).
static TALKING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

static HOOK: OnceLock<Hook> = OnceLock::new();
static ACCEPT_SYNTHETIC: OnceLock<bool> = OnceLock::new();
/// The talk key's own key-up still to swallow after its modifier let go first.
static SWALLOW_UP: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static STATE: parking_lot::Mutex<(Mods, bool, bool)> = parking_lot::Mutex::new((Mods { ctrl: false, alt: false, shift: false, win: false }, false, false));

/// Parses "ctrl+alt", "ctrl+win", "ctrl+shift"… (modifiers only).
fn parse(spec: &str) -> Mods {
    let mut m = Mods::default();
    for p in spec.to_lowercase().split('+') {
        match p.trim() {
            "ctrl" | "control" => m.ctrl = true,
            "alt" | "option" | "opt" => m.alt = true,
            "shift" => m.shift = true,
            "win" | "windows" | "super" => m.win = true,
            _ => {}
        }
    }
    if m == Mods::default() {
        m.ctrl = true;
        m.alt = true;
    }
    m
}

/// Parses "ctrl+h", "ctrl+shift+space"…: modifiers plus one key (a letter, digit, space or F1–F12).
fn parse_talk(spec: &str) -> Option<(Mods, u16)> {
    let mut m = Mods::default();
    let mut key = None;
    for p in spec.to_lowercase().split('+') {
        match p.trim() {
            "ctrl" | "control" => m.ctrl = true,
            "alt" | "option" | "opt" => m.alt = true,
            "shift" => m.shift = true,
            "win" | "windows" | "super" => m.win = true,
            "space" => key = Some(0x20),
            k if k.len() == 1 && k.chars().all(|c| c.is_ascii_alphanumeric()) => key = Some(k.to_ascii_uppercase().as_bytes()[0] as u16),
            k if k.starts_with('f') && k[1..].parse::<u16>().map(|n| (1..=12).contains(&n)).unwrap_or(false) => key = Some(0x6F + k[1..].parse::<u16>().unwrap()),
            _ => {}
        }
    }
    key.filter(|_| m != Mods::default()).map(|k| (m, k))
}

/// The push-to-talk key's label: "Ctrl+H".
pub fn talk_label(spec: &str) -> String {
    let Some((m, k)) = parse_talk(spec) else { return String::new() };
    let key = match k {
        0x20 => "Space".to_string(),
        0x70..=0x7B => format!("F{}", k - 0x6F),
        _ => (k as u8 as char).to_string(),
    };
    [(m.ctrl, "Ctrl"), (m.alt, "Alt"), (m.shift, "Shift"), (m.win, "Win")].iter().filter(|x| x.0).map(|x| x.1.to_string()).chain(std::iter::once(key)).collect::<Vec<_>>().join("+")
}

/// A label for menus: "Ctrl+Alt".
pub fn label(spec: &str) -> String {
    let m = parse(spec);
    [(m.ctrl, "Ctrl"), (m.alt, "Alt"), (m.shift, "Shift"), (m.win, "Win")].iter().filter(|x| x.0).map(|x| x.1).collect::<Vec<_>>().join("+")
}

unsafe extern "system" fn proc_(code: i32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if code >= 0 {
        let k = &*(lp.0 as *const KBDLLHOOKSTRUCT);
        // Keys other programs inject count only in tests (CLINQY_ACCEPT_SYNTHETIC_KEYS=1); Clinqy's own never do.
        let synthetic = k.flags.0 & LLKHF_INJECTED.0 != 0 && !*ACCEPT_SYNTHETIC.get_or_init(|| std::env::var("CLINQY_ACCEPT_SYNTHETIC_KEYS").map(|v| v == "1").unwrap_or(false));
        let injected = synthetic || k.dwExtraInfo == crate::input::INJECTED_TAG;
        if !injected {
            if let Some(h) = HOOK.get() {
                let down = matches!(wp.0 as u32, WM_KEYDOWN | WM_SYSKEYDOWN);
                let vk = VIRTUAL_KEY(k.vkCode as u16);
                let mut st = STATE.lock();
                let (mods, held, spoiled) = &mut *st;
                let is_mod = match vk {
                    VK_LCONTROL | VK_RCONTROL | VK_CONTROL => {
                        // AltGr sends a fake left Ctrl with this scan code first: ignore it.
                        if k.scanCode == 0x21D {
                            return CallNextHookEx(None, code, wp, lp);
                        }
                        mods.ctrl = down;
                        true
                    }
                    VK_LMENU | VK_MENU => {
                        mods.alt = down;
                        true
                    }
                    VK_RMENU => true, // AltGr: neither Alt nor another key
                    VK_LSHIFT | VK_RSHIFT | VK_SHIFT => {
                        mods.shift = down;
                        true
                    }
                    VK_LWIN | VK_RWIN => {
                        mods.win = down;
                        true
                    }
                    _ => false,
                };
                let mut event = None;
                // Push-to-talk: its key with exactly its modifiers. Held, its key is swallowed (repeats too).
                if let Some((tm, tk)) = h.talk {
                    let talking = TALKING.load(std::sync::atomic::Ordering::Relaxed);
                    if vk.0 == tk {
                        if down && (talking || *mods == tm) {
                            if !talking {
                                TALKING.store(true, std::sync::atomic::Ordering::Relaxed);
                                drop(st);
                                (h.on)(HotEvent::TalkDown);
                            }
                            return LRESULT(1);
                        }
                        if !down && talking {
                            TALKING.store(false, std::sync::atomic::Ordering::Relaxed);
                            drop(st);
                            (h.on)(HotEvent::TalkUp);
                            return LRESULT(1);
                        }
                    } else if is_mod && !down && talking && *mods != tm {
                        // A modifier let go while talking: that ends it too (the key's own up is still swallowed).
                        TALKING.store(false, std::sync::atomic::Ordering::Relaxed);
                        SWALLOW_UP.store(true, std::sync::atomic::Ordering::Relaxed);
                        drop(st);
                        (h.on)(HotEvent::TalkUp);
                        return CallNextHookEx(None, code, wp, lp);
                    }
                    if vk.0 == tk && !down && SWALLOW_UP.swap(false, std::sync::atomic::Ordering::Relaxed) {
                        return LRESULT(1);
                    }
                }
                if !is_mod {
                    if down && *held && !*spoiled {
                        *spoiled = true;
                        event = Some(HotEvent::Spoiled);
                    }
                } else if !*held && *mods == h.want {
                    *held = true;
                    *spoiled = false;
                    event = Some(HotEvent::Pressed);
                    // Releasing Alt (or Win) alone would open the window's menu (or Start): a dummy key between
                    // press and release stops that, the same trick PowerToys uses.
                    let k2 = |up: bool| INPUT {
                        r#type: INPUT_KEYBOARD,
                        Anonymous: INPUT_0 {
                            ki: KEYBDINPUT { wVk: VIRTUAL_KEY(0xE8), wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { Default::default() }, time: 0, dwExtraInfo: crate::input::INJECTED_TAG },
                        },
                    };
                    SendInput(&[k2(false), k2(true)], std::mem::size_of::<INPUT>() as i32);
                } else if *held && *mods != h.want {
                    *held = false;
                    if !*spoiled {
                        event = Some(HotEvent::Released);
                    }
                }
                drop(st);
                if let Some(e) = event {
                    (h.on)(e);
                }
            }
        }
    }
    CallNextHookEx(None, code, wp, lp)
}

/// Starts watching for the summon chord and push-to-talk (once; `talk` empty or "off" turns push-to-talk off).
/// `on` runs on the hook's thread: keep it quick.
pub fn start(spec: &str, talk: &str, on: impl Fn(HotEvent) + Send + Sync + 'static) {
    if HOOK.set(Hook { want: parse(spec), talk: parse_talk(talk), on: Box::new(on) }).is_err() {
        return;
    }
    std::thread::Builder::new()
        .name("clinqy-hotkey".into())
        .spawn(|| unsafe {
            let inst = GetModuleHandleW(None).unwrap_or_default();
            let Ok(hook) = SetWindowsHookExW(WH_KEYBOARD_LL, Some(proc_), inst, 0) else {
                clinqy_core::log::write("hotkey: couldn't install the keyboard hook");
                return;
            };
            let mut msg = MSG::default();
            while GetMessageW(&mut msg, None, 0, 0).as_bool() {
                let _ = TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
            let _ = UnhookWindowsHookEx(hook);
        })
        .ok();
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_talk_keys() {
        assert_eq!(parse_talk("ctrl+h"), Some((Mods { ctrl: true, ..Default::default() }, 0x48)));
        assert_eq!(parse_talk("ctrl+shift+space").map(|t| t.1), Some(0x20));
        assert_eq!(parse_talk("alt+f9").map(|t| t.1), Some(0x78));
        assert_eq!(parse_talk("h"), None);
        assert_eq!(parse_talk("off"), None);
        assert_eq!(talk_label("ctrl+h"), "Ctrl+H");
    }
}
