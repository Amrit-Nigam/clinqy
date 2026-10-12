//! The summon key: a modifier-only chord (Ctrl+Alt by default, like ⌃⌥ on the Mac), tapped to open the command bar
//! or held to talk. A low-level keyboard hook sees press and release; any other key while it's held means the chord
//! belongs to another shortcut. Right Alt (AltGr, which types characters on many layouts) never counts as Alt, and
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
    on: Box<dyn Fn(HotEvent) + Send + Sync>,
}

static HOOK: OnceLock<Hook> = OnceLock::new();
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

/// A label for menus: "Ctrl+Alt".
pub fn label(spec: &str) -> String {
    let m = parse(spec);
    [(m.ctrl, "Ctrl"), (m.alt, "Alt"), (m.shift, "Shift"), (m.win, "Win")].iter().filter(|x| x.0).map(|x| x.1).collect::<Vec<_>>().join("+")
}

unsafe extern "system" fn proc_(code: i32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if code >= 0 {
        let k = &*(lp.0 as *const KBDLLHOOKSTRUCT);
        let injected = k.flags.0 & LLKHF_INJECTED.0 != 0 || k.dwExtraInfo == crate::input::INJECTED_TAG;
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

/// Starts watching for the chord (once). `on` runs on the hook's thread: keep it quick.
pub fn start(spec: &str, on: impl Fn(HotEvent) + Send + Sync + 'static) {
    if HOOK.set(Hook { want: parse(spec), on: Box::new(on) }).is_err() {
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
