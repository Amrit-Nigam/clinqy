//! Watch & learn: while it's on, every click the user makes is described (the control under the pointer, from UI
//! Automation) and text they type into a field is noted when they move on; stopping turns the recording into a
//! reusable skill with the model.

use crate::app::{Shared, UserEvent};
use parking_lot::Mutex;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use windows::Win32::Foundation::{LPARAM, LRESULT, WPARAM};
use windows::Win32::UI::WindowsAndMessaging::*;

static ON: AtomicBool = AtomicBool::new(false);
static LEARNING: AtomicBool = AtomicBool::new(false);
static STEPS: Mutex<Vec<String>> = Mutex::new(Vec::new());
static CLICKS: Mutex<Option<std::sync::mpsc::Sender<(i32, i32)>>> = Mutex::new(None);
static HOOK_THREAD: Mutex<Option<u32>> = Mutex::new(None);

pub fn is_recording() -> bool {
    ON.load(Ordering::Relaxed)
}

/// Turning a recording into a skill (the model is writing it).
pub fn is_learning() -> bool {
    LEARNING.load(Ordering::Relaxed)
}

unsafe extern "system" fn mouse(code: i32, wp: WPARAM, lp: LPARAM) -> LRESULT {
    if code >= 0 && wp.0 as u32 == WM_LBUTTONUP {
        let m = &*(lp.0 as *const MSLLHOOKSTRUCT);
        // Not Clinqy's own clicks.
        if m.flags & LLMHF_INJECTED == 0 {
            if let Some(tx) = CLICKS.lock().as_ref() {
                let _ = tx.send((m.pt.x, m.pt.y));
            }
        }
    }
    CallNextHookEx(None, code, wp, lp)
}

/// Starts or stops watching.
pub fn toggle(shared: Arc<Shared>) {
    if is_recording() {
        stop(shared);
    } else {
        start(shared);
    }
}

fn start(shared: Arc<Shared>) {
    ON.store(true, Ordering::Relaxed);
    STEPS.lock().clear();
    let (tx, rx) = std::sync::mpsc::channel::<(i32, i32)>();
    *CLICKS.lock() = Some(tx);
    shared.send(UserEvent::Notice("Watching: do the task once, then tap the hotkey (or the tray's Watch & learn) to stop".into()));
    std::thread::spawn(|| unsafe {
        *HOOK_THREAD.lock() = Some(windows::Win32::System::Threading::GetCurrentThreadId());
        let Ok(hook) = SetWindowsHookExW(WH_MOUSE_LL, Some(mouse), None, 0) else { return };
        let mut msg = MSG::default();
        while GetMessageW(&mut msg, None, 0, 0).as_bool() {
            let _ = TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        let _ = UnhookWindowsHookEx(hook);
    });
    std::thread::spawn(move || {
        clinqy_windows::com::ensure();
        let uia = clinqy_windows::uia::uia();
        let mut last_focus: Option<(u64, String, String)> = None;
        let note_typing = |last: &Option<(u64, String, String)>| {
            if let Some((handle, role, before)) = last {
                if let Some(now) = uia.value_of(*handle) {
                    if !now.is_empty() && &now != before {
                        STEPS.lock().push(format!("Typed “{}” into {role}", now.chars().take(120).collect::<String>()));
                    }
                }
            }
        };
        while let Ok((x, y)) = rx.recv() {
            if !is_recording() {
                break;
            }
            note_typing(&last_focus);
            std::thread::sleep(std::time::Duration::from_millis(120));
            let app = clinqy_windows::apps::foreground().and_then(|f| clinqy_windows::apps::app_ref(f.0)).map(|a| a.name).unwrap_or_default();
            let what = describe_at(x, y);
            STEPS.lock().push(format!("Click {what}{}", if app.is_empty() { String::new() } else { format!(" in {app}") }));
            last_focus = uia.focus().filter(|f| f.text_input).map(|f| (f.handle, f.role.clone(), f.value.unwrap_or_default()));
        }
        note_typing(&last_focus);
    });
}

fn describe_at(x: i32, y: i32) -> String {
    use windows::Win32::Foundation::POINT;
    let uia = clinqy_windows::uia::uia();
    unsafe {
        let Ok(el) = uia.automation.ElementFromPoint(POINT { x, y }) else { return "something".into() };
        let role = el.CurrentControlType().map(clinqy_windows::uia::role_name).unwrap_or("Control");
        let mut name = el.CurrentName().map(|b| b.to_string()).unwrap_or_default();
        if name.is_empty() {
            if let Ok(walker) = uia.automation.ControlViewWalker() {
                if let Ok(parent) = walker.GetParentElement(&el) {
                    name = parent.CurrentName().map(|b| b.to_string()).unwrap_or_default();
                }
            }
        }
        if name.is_empty() {
            role.to_string()
        } else {
            format!("{role} “{}”", name.chars().take(80).collect::<String>())
        }
    }
}

fn stop(shared: Arc<Shared>) {
    ON.store(false, Ordering::Relaxed);
    *CLICKS.lock() = None;
    if let Some(t) = HOOK_THREAD.lock().take() {
        unsafe {
            let _ = PostThreadMessageW(t, WM_QUIT, WPARAM(0), LPARAM(0));
        }
    }
    let steps = std::mem::take(&mut *STEPS.lock());
    shared.send(UserEvent::Notice(format!("Learning from {} steps…", steps.len())));
    LEARNING.store(true, Ordering::Relaxed);
    tokio::spawn(async move {
        let learned = clinqy_core::skills::learn(&steps).await;
        LEARNING.store(false, Ordering::Relaxed);
        match learned {
            Ok(s) => shared.send(UserEvent::Notice(format!("Learned the skill “{}” — find it under Skills", s.name))),
            Err(e) => shared.send(UserEvent::Notice(e)),
        }
    });
}
