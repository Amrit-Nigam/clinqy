//! First run and setup: the settings file, Open at login, the browser extension's folder, and a "Check setup"
//! card that says what's ready and what isn't (model, browser extension, voice, Outlook).

use clinqy_core::history::{CardItem, ResultCard};
use clinqy_core::provider::Provider;
use windows::core::PCWSTR;
use windows::Win32::System::Registry::*;

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// True once: the first launch after install (then marks it).
pub fn first_run() -> bool {
    let marker = clinqy_core::paths::data_dir().join(".welcomed");
    if marker.exists() {
        return false;
    }
    let _ = std::fs::write(&marker, chrono::Utc::now().to_rfc3339());
    ensure_env_file();
    true
}

/// ~/.config/clinqy/env from the template (with every option, commented), when there isn't one.
pub fn ensure_env_file() {
    let p = clinqy_core::paths::env_file();
    if !p.exists() {
        let _ = std::fs::write(&p, include_str!("../../../env.windows.example"));
    }
}

pub fn starts_at_login() -> bool {
    let key = wide(RUN_KEY);
    let name = wide("Clinqy");
    let mut size = 0u32;
    unsafe { RegGetValueW(HKEY_CURRENT_USER, PCWSTR(key.as_ptr()), PCWSTR(name.as_ptr()), RRF_RT_REG_SZ, None, None, Some(&mut size)) }.is_ok()
}

pub fn set_start_at_login(on: bool) {
    let key = wide(RUN_KEY);
    let name = wide("Clinqy");
    unsafe {
        let mut h = HKEY::default();
        if RegOpenKeyExW(HKEY_CURRENT_USER, PCWSTR(key.as_ptr()), 0, KEY_SET_VALUE, &mut h).is_err() {
            return;
        }
        if on {
            let exe = std::env::current_exe().map(|p| format!("\"{}\" --login", p.display())).unwrap_or_default();
            let v: Vec<u8> = wide(&exe).iter().flat_map(|u| u.to_le_bytes()).collect();
            let _ = RegSetValueExW(h, PCWSTR(name.as_ptr()), 0, REG_SZ, Some(&v));
        } else {
            let _ = RegDeleteValueW(h, PCWSTR(name.as_ptr()));
        }
        let _ = RegCloseKey(h);
    }
}

/// A string value under HKEY_CURRENT_USER (`name` None: the key's default value), creating the key.
fn set_user_string(key: &str, name: Option<&str>, value: &str) {
    let k = wide(key);
    let n = name.map(wide);
    unsafe {
        let mut h = HKEY::default();
        if RegCreateKeyExW(HKEY_CURRENT_USER, PCWSTR(k.as_ptr()), 0, None, REG_OPTION_NON_VOLATILE, KEY_SET_VALUE, None, &mut h, None).is_err() {
            return;
        }
        let v: Vec<u8> = wide(value).iter().flat_map(|u| u.to_le_bytes()).collect();
        let _ = RegSetValueExW(h, n.as_ref().map(|n| PCWSTR(n.as_ptr())).unwrap_or(PCWSTR::null()), 0, REG_SZ, Some(&v));
        let _ = RegCloseKey(h);
    }
}

/// clinqy:// links (QA runs, workflows, "open Clinqy" from a web page) go to the `clinqy` command next to the app,
/// as on the Mac. Re-registered at each launch, so it follows the app when it moves.
pub fn register_links() {
    let Some(cli) = std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.join("clinqy.exe"))).filter(|c| c.is_file()) else { return };
    set_user_string(r"Software\Classes\clinqy", None, "URL:Clinqy");
    set_user_string(r"Software\Classes\clinqy", Some("URL Protocol"), "");
    set_user_string(r"Software\Classes\clinqy\DefaultIcon", None, &format!("{},0", cli.with_file_name("ClinqyApp.exe").display()));
    set_user_string(r"Software\Classes\clinqy\shell\open\command", None, &format!("\"{}\" url \"%1\"", cli.display()));
}

/// Where the browser extension lives: next to the app when installed, else the repo's extension folder.
pub fn extension_dir() -> Option<std::path::PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let here = exe.parent()?;
    [here.join("extension"), here.join("..").join("extension"), here.join("..\\..\\..\\..\\extension"), here.join("..\\..\\..\\extension")]
        .into_iter()
        .find(|p| p.join("manifest.json").is_file())
        .map(|p| std::fs::canonicalize(&p).map(|c| std::path::PathBuf::from(c.display().to_string().trim_start_matches(r"\\?\"))).unwrap_or(p))
}

/// Opens the extension folder and the browser's extensions page, with what to do.
pub fn show_extension_help() {
    if let Some(dir) = extension_dir() {
        clinqy_windows::system::shell_open(&dir.display().to_string());
        let _ = clinqy_windows::clipboard::set_text(&dir.display().to_string(), false);
    }
    let page = match clinqy_windows::apps::default_browser().as_deref() {
        Some("Microsoft Edge") => "msedge.exe edge://extensions",
        Some("Brave") => "brave.exe brave://extensions",
        _ => "chrome.exe chrome://extensions",
    };
    let (exe, url) = page.split_once(' ').unwrap();
    let _ = std::process::Command::new("cmd").args(["/c", "start", "", exe, url]).spawn();
}

pub fn beep() {
    unsafe {
        let _ = windows::Win32::System::Diagnostics::Debug::MessageBeep(windows::Win32::UI::WindowsAndMessaging::MB_ICONASTERISK);
    }
}

/// What's ready: the model, the browser extension, voice, Outlook (email & calendar), Windows Search.
/// What's set up. `extension`: whether the browser extension is connected, when someone else (the running app)
/// knows better than this process.
pub fn check_card(extension: Option<bool>) -> ResultCard {
    let p = Provider::current();
    let mut items = vec![];
    let ok = |b: bool| if b { "✓ ready" } else { "✗ needs setup" };
    let model_ready = if p.is_cli() { p.cli().is_some() } else { p.key().is_some() || matches!(p, Provider::Ollama | Provider::Compatible) };
    items.push(CardItem {
        title: "Model".into(),
        subtitle: Some(format!("{} · model {}", p.label(), p.default_model())),
        detail: Some(ok(model_ready).into()),
        link: None,
    });
    let ext = extension.unwrap_or_else(|| clinqy_core::bridge::bridge().is_connected());
    items.push(CardItem {
        title: "Browser extension".into(),
        subtitle: Some(if ext {
            "connected — web pages are read and driven exactly".into()
        } else {
            format!("not connected: in Chrome/Edge open the extensions page, turn on Developer mode, Load unpacked → {}", extension_dir().map(|d| d.display().to_string()).unwrap_or_else(|| "the extension folder".into()))
        }),
        detail: Some(ok(ext).into()),
        link: None,
    });
    let voice = clinqy_core::paths::local_dir().join("voice").join("whisper").join("whisper-server.exe").is_file();
    items.push(CardItem {
        title: "Voice (on-device Whisper)".into(),
        subtitle: Some(if voice { "installed".into() } else { "downloads by itself the first time you hold the hotkey to talk".into() }),
        detail: Some(if voice { "✓ ready".into() } else { "• on first use".into() }),
        link: None,
    });
    let outlook = std::path::Path::new(r"C:\Program Files\Microsoft Office\root\Office16\OUTLOOK.EXE").exists()
        || std::path::Path::new(r"C:\Program Files (x86)\Microsoft Office\root\Office16\OUTLOOK.EXE").exists();
    items.push(CardItem {
        title: "Email & calendar in the background".into(),
        subtitle: Some(if outlook { "desktop Outlook found".into() } else { "no desktop Outlook: Clinqy uses your webmail and web calendar in the browser instead".into() }),
        detail: Some(if outlook { "✓ ready".into() } else { "• via browser".into() }),
        link: None,
    });
    items.push(CardItem {
        title: "Settings file".into(),
        subtitle: Some(clinqy_core::paths::env_file().display().to_string()),
        detail: None,
        link: None,
    });
    ResultCard { title: "Clinqy setup".into(), text: "Everything Clinqy does stays on this PC except the model calls, which go only to the provider above.".into(), items }
}
