//! Clinqy's Windows platform layer. `WindowsPlatform` implements the agent's `Platform` trait and `Overlay` its
//! `Buddy` (the companion cursor); `hotkey` watches for the summon chord.

pub mod apps;
pub mod badge;
pub mod circle;
pub mod clipboard;
pub mod com;
pub mod hotkey;
pub mod input;
pub mod island;
pub mod ocr;
pub mod overlay;
pub mod platform;
pub mod screen;
pub mod system;
pub mod text;
pub mod uia;

pub use overlay::Overlay;
pub use platform::WindowsPlatform;

/// Process-wide setup, before any window exists: physical-pixel coordinates on every monitor. (COM is joined per
/// worker thread by `com::ensure`; the UI thread stays in the single-threaded apartment its windows need.)
pub fn init_process() {
    use windows::Win32::UI::HiDpi::{SetProcessDpiAwarenessContext, DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2};
    unsafe {
        let _ = SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2);
    }
}
