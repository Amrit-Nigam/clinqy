//! ClinqyApp.exe: the tray app. A second launch (or a clinqy:// link) hands over to the one already running.
#![windows_subsystem = "windows"]

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    // A clinqy:// link, or a second launch: pass it to the running app.
    let link = args.iter().find(|a| a.starts_with("clinqy://")).cloned();
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().expect("runtime");
    if rt.block_on(clinqy_app::ipc::app_running()) {
        let _ = rt.block_on(async {
            match link {
                Some(u) => clinqy_app::ipc::call("url", serde_json::json!({"url": u}), |_| {}).await,
                None => clinqy_app::ipc::call("show", serde_json::json!({}), |_| {}).await,
            }
        });
        return;
    }
    drop(rt);
    if let Err(e) = clinqy_app::app::run() {
        clinqy_core::log::write(&format!("ClinqyApp failed to start: {e:#}"));
        let msg: Vec<u16> = format!("Clinqy couldn't start:\n\n{e:#}").encode_utf16().chain([0]).collect();
        let title: Vec<u16> = "Clinqy".encode_utf16().chain([0]).collect();
        unsafe {
            windows::Win32::UI::WindowsAndMessaging::MessageBoxW(None, windows::core::PCWSTR(msg.as_ptr()), windows::core::PCWSTR(title.as_ptr()), windows::Win32::UI::WindowsAndMessaging::MB_ICONERROR);
        }
    }
}
