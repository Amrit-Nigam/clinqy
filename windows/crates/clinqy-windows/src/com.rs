//! COM on whatever thread calls in: every UI Automation and WinRT call starts with `ensure()`, which joins the
//! thread to the multithreaded apartment once.

use std::cell::Cell;
use windows::Win32::System::Com::{CoInitializeEx, COINIT_MULTITHREADED};

thread_local! {
    static READY: Cell<bool> = const { Cell::new(false) };
}

pub fn ensure() {
    READY.with(|r| {
        if !r.get() {
            // S_FALSE (already initialised) and RPC_E_CHANGED_MODE (an STA thread, e.g. the UI's) are both fine:
            // UI Automation objects are free-threaded.
            unsafe {
                let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            }
            r.set(true);
        }
    });
}

/// The UI thread: its windows put it in the single-threaded apartment themselves, so never join it to the
/// multithreaded one (UI Automation works from there too).
pub fn mark_ui_thread() {
    READY.with(|r| r.set(true));
}

/// Wide string for Win32 calls.
pub fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}
