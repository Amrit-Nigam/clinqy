//! Clinqy's two keys, watched by one low-level keyboard hook:
//! - the summon chord, modifiers only (Ctrl+Alt by default, like ⌃⌥ on the Mac), tapped to open the command bar. Any
//!   other key while it's held means the chord belongs to another shortcut. Right Alt (AltGr, which types characters
//!   on many layouts) never counts as Alt.
//! - push-to-talk, modifiers + a key (Ctrl+H by default): Clinqy listens only while it's held. Its key is swallowed
//!   while held, so the app in front doesn't also get it.
//! Clinqy's own injected keys are ignored.

use std::sync::{OnceLock, RwLock};
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
    /// Pause or stop, while a task runs.
    TaskKey(TaskKey),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskKey {
    Pause,
    Stop,
    /// A background task: the app in front had this press, and a second one acts.
    PauseHint,
    StopHint,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum TaskMode {
    Off,
    /// The task has the screen, so one press acts.
    Foreground,
    /// The user is working: Ctrl+S has to stay Save, so it takes a second press.
    Background,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum TaskKeyPress {
    Pass,
    Swallow,
    Hint,
    Act,
}

const SECOND_PRESS: std::time::Duration = std::time::Duration::from_secs(2);

/// What a press of a task key does. `since` is how long ago the same key was last pressed.
fn task_key_press(mode: TaskMode, repeat: bool, since: Option<std::time::Duration>) -> TaskKeyPress {
    match mode {
        TaskMode::Off => TaskKeyPress::Pass,
        TaskMode::Foreground if repeat => TaskKeyPress::Swallow,
        TaskMode::Foreground => TaskKeyPress::Act,
        TaskMode::Background if repeat => TaskKeyPress::Pass,
        TaskMode::Background if since.is_some_and(|s| s <= SECOND_PRESS) => TaskKeyPress::Act,
        TaskMode::Background => TaskKeyPress::Hint,
    }
}

static TASK_MODE: RwLock<TaskMode> = RwLock::new(TaskMode::Off);
static TASK_KEYS: RwLock<[Option<(Mods, u16)>; 2]> = RwLock::new([None, None]);
/// The task key being held and its latest event, and the last one pressed and when.
static TASK_HELD: parking_lot::Mutex<(u16, Option<std::time::Instant>, Option<(u16, std::time::Instant)>)> = parking_lot::Mutex::new((0, None, None));
/// Longer than Windows' longest delay before a held key repeats. A key-up can go missing (a swallowed key's often
/// does when the window in front changes), so "held" can't last longer than this without another event.
const REPEAT_GAP: std::time::Duration = std::time::Duration::from_millis(1100);

/// Pause and stop while a task runs ("off" turns one off).
pub fn set_task_keys(pause: &str, stop: &str) {
    *TASK_KEYS.write().unwrap_or_else(|e| e.into_inner()) = [parse_talk(pause), parse_talk(stop)];
}

/// Tests may send input that counts as the user's (CLINQY_ACCEPT_SYNTHETIC_KEYS=1).
pub(crate) fn accept_synthetic() -> bool {
    *ACCEPT_SYNTHETIC.get_or_init(|| std::env::var("CLINQY_ACCEPT_SYNTHETIC_KEYS").as_deref() == Ok("1"))
}

pub fn set_task_mode(mode: TaskMode) {
    let mut current = TASK_MODE.write().unwrap_or_else(|e| e.into_inner());
    if *current != mode {
        TASK_HELD.lock().0 = 0;
    }
    *current = mode;
}

/// A task key going down or up, with the Mods exactly as held. True when the app in front mustn't get it.
fn task_key(vk: u16, mods: Mods, down: bool, on: &(dyn Fn(HotEvent) + Send + Sync)) -> bool {
    let mode = *TASK_MODE.read().unwrap_or_else(|e| e.into_inner());
    let mut held = TASK_HELD.lock();
    if !down {
        if held.0 == vk {
            held.0 = 0;
        }
        return false;
    }
    if mode == TaskMode::Off {
        return false;
    }
    let keys = *TASK_KEYS.read().unwrap_or_else(|e| e.into_inner());
    let Some(which) = keys.iter().position(|k| *k == Some((mods, vk))) else { return false };
    let now = std::time::Instant::now();
    let repeat = held.0 == vk && held.1.is_some_and(|at| now - at < REPEAT_GAP);
    let since = held.2.filter(|(last, _)| *last == vk).map(|(_, at)| now - at);
    held.0 = vk;
    held.1 = Some(now);
    if !repeat {
        held.2 = Some((vk, now));
    }
    drop(held);
    let press = task_key_press(mode, repeat, since);
    match (press, which) {
        (TaskKeyPress::Act, 0) => on(HotEvent::TaskKey(TaskKey::Pause)),
        (TaskKeyPress::Act, _) => on(HotEvent::TaskKey(TaskKey::Stop)),
        (TaskKeyPress::Hint, 0) => on(HotEvent::TaskKey(TaskKey::PauseHint)),
        (TaskKeyPress::Hint, _) => on(HotEvent::TaskKey(TaskKey::StopHint)),
        _ => {}
    }
    matches!(press, TaskKeyPress::Act | TaskKeyPress::Swallow)
}

#[derive(Clone, Copy, Default, PartialEq, Eq, Debug)]
struct Mods {
    ctrl: bool,
    alt: bool,
    shift: bool,
    win: bool,
}

#[derive(Clone, Copy)]
struct HookConfig {
    want: Mods,
    talk: Option<(Mods, u16)>,
}

struct Hook {
    config: RwLock<HookConfig>,
    on: Box<dyn Fn(HotEvent) + Send + Sync>,
}

/// Push-to-talk is held (its key's events are swallowed until it comes up).
static TALKING: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
static ENABLED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(true);

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

/// Whether a shortcut contains only supported modifier keys with no duplicates.
pub fn valid_summon(spec: &str) -> bool {
    let mut seen = Mods::default();
    let parts: Vec<_> = spec.to_lowercase().split('+').map(|p| p.trim().to_string()).collect();
    if parts.is_empty() { return false; }
    for part in parts {
        let slot = match part.as_str() {
            "ctrl" | "control" => &mut seen.ctrl,
            "alt" | "option" | "opt" => &mut seen.alt,
            "shift" => &mut seen.shift,
            "win" | "windows" | "super" => &mut seen.win,
            _ => return false,
        };
        if *slot { return false; }
        *slot = true;
    }
    seen != Mods::default()
}

/// Parses "ctrl+h", "ctrl+shift+space"…: modifiers plus one key (a letter, digit, space or F1–F12).
fn parse_talk(spec: &str) -> Option<(Mods, u16)> {
    let mut m = Mods::default();
    let mut key = None;
    for p in spec.to_lowercase().split('+') {
        match p.trim() {
            "ctrl" | "control" if !m.ctrl => m.ctrl = true,
            "alt" | "option" | "opt" if !m.alt => m.alt = true,
            "shift" if !m.shift => m.shift = true,
            "win" | "windows" | "super" if !m.win => m.win = true,
            "space" if key.is_none() => key = Some(0x20),
            k if key.is_none() && k.len() == 1 && k.chars().all(|c| c.is_ascii_alphanumeric()) => key = Some(k.to_ascii_uppercase().as_bytes()[0] as u16),
            k if key.is_none() && k.starts_with('f') && k[1..].parse::<u16>().map(|n| (1..=12).contains(&n)).unwrap_or(false) => key = Some(0x6F + k[1..].parse::<u16>().unwrap()),
            _ => return None,
        }
    }
    key.filter(|_| m != Mods::default()).map(|k| (m, k))
}

/// Whether a push-to-talk shortcut has supported modifiers and one supported key.
pub fn valid_talk(spec: &str) -> bool {
    parse_talk(spec).is_some()
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
        if !injected && ENABLED.load(std::sync::atomic::Ordering::Relaxed) {
            if let Some(h) = HOOK.get() {
                let config = *h.config.read().unwrap_or_else(|e| e.into_inner());
                let down = matches!(wp.0 as u32, WM_KEYDOWN | WM_SYSKEYDOWN);
                let vk = VIRTUAL_KEY(k.vkCode as u16);
                let mut st = STATE.lock();
                let mods = &mut st.0;
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
                if !is_mod {
                    let held = *mods;
                    drop(st);
                    if task_key(vk.0, held, down, h.on.as_ref()) {
                        return LRESULT(1);
                    }
                    st = STATE.lock();
                }
                let (mods, held, spoiled) = &mut *st;
                let mut event = None;
                // Push-to-talk: its key with exactly its modifiers. Held, its key is swallowed (repeats too).
                if let Some((tm, tk)) = config.talk {
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
                } else if !*held && *mods == config.want {
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
                } else if *held && *mods != config.want {
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
    if HOOK.set(Hook { config: RwLock::new(HookConfig { want: parse(spec), talk: parse_talk(talk) }), on: Box::new(on) }).is_err() {
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

/// Updates the active hotkeys without restarting the low-level keyboard hook.
pub fn configure(spec: &str, talk: &str) {
    let Some(hook) = HOOK.get() else { return; };
    let was_talking = TALKING.swap(false, std::sync::atomic::Ordering::Relaxed);
    SWALLOW_UP.store(false, std::sync::atomic::Ordering::Relaxed);
    if let Ok(mut config) = hook.config.write() {
        *config = HookConfig { want: parse(spec), talk: parse_talk(talk) };
    }
    *STATE.lock() = (Mods::default(), false, false);
    if was_talking {
        (hook.on)(HotEvent::TalkUp);
    }
}

/// Temporarily suspends global shortcut recognition while the dashboard records a new binding.
pub fn set_enabled(enabled: bool) {
    ENABLED.store(enabled, std::sync::atomic::Ordering::Relaxed);
    if enabled { return; }
    let was_talking = TALKING.swap(false, std::sync::atomic::Ordering::Relaxed);
    SWALLOW_UP.store(false, std::sync::atomic::Ordering::Relaxed);
    *STATE.lock() = (Mods::default(), false, false);
    if was_talking {
        if let Some(hook) = HOOK.get() { (hook.on)(HotEvent::TalkUp); }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn task_keys_leave_save_alone_during_background_work() {
        let (fg, bg, soon, late) = (TaskMode::Foreground, TaskMode::Background, std::time::Duration::from_secs(1), std::time::Duration::from_secs(3));
        assert_eq!(task_key_press(TaskMode::Off, false, Some(soon)), TaskKeyPress::Pass);
        assert_eq!(task_key_press(fg, false, None), TaskKeyPress::Act);
        assert_eq!(task_key_press(fg, true, None), TaskKeyPress::Swallow);
        assert_eq!(task_key_press(bg, false, None), TaskKeyPress::Hint);
        assert_eq!(task_key_press(bg, false, Some(late)), TaskKeyPress::Hint);
        assert_eq!(task_key_press(bg, false, Some(soon)), TaskKeyPress::Act);
        assert_eq!(task_key_press(bg, true, Some(soon)), TaskKeyPress::Pass);
    }

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
