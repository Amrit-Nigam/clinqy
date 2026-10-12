//! Windows and the apps behind them: which app is in front, what a person calls it ("Google Chrome", not
//! chrome.exe), the apps running, the apps installed (Start menu), bringing a window forward reliably, and
//! window operations.

use crate::com::wide;
use clinqy_core::platform::{AppRef, Point, Rect, WindowOp};
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::OnceLock;
use std::time::{Duration, Instant};
use windows::core::PCWSTR;
use windows::Win32::Foundation::{BOOL, CloseHandle, FILETIME, HWND, LPARAM, RECT};
use windows::Win32::Graphics::Dwm::{DwmGetWindowAttribute, DWMWA_CLOAKED, DWMWA_EXTENDED_FRAME_BOUNDS};
use windows::Win32::Storage::FileSystem::{GetFileVersionInfoSizeW, GetFileVersionInfoW, VerQueryValueW};
use windows::Win32::System::Threading::{
    GetCurrentProcessId, GetProcessTimes, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};
use windows::Win32::UI::Input::KeyboardAndMouse::{SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYEVENTF_KEYUP, VIRTUAL_KEY};
use windows::Win32::UI::WindowsAndMessaging::*;

pub fn window_title(hwnd: isize) -> String {
    let mut buf = [0u16; 512];
    let n = unsafe { GetWindowTextW(HWND(hwnd as _), &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

pub fn class_name(hwnd: isize) -> String {
    let mut buf = [0u16; 256];
    let n = unsafe { GetClassNameW(HWND(hwnd as _), &mut buf) };
    String::from_utf16_lossy(&buf[..n.max(0) as usize])
}

pub fn find_window(class: &str) -> Option<isize> {
    let w = wide(class);
    let h = unsafe { FindWindowW(PCWSTR(w.as_ptr()), PCWSTR::null()) }.ok()?;
    (!h.0.is_null()).then_some(h.0 as isize)
}

pub fn pid_of(hwnd: isize) -> u32 {
    let mut pid = 0u32;
    unsafe { GetWindowThreadProcessId(HWND(hwnd as _), Some(&mut pid)) };
    pid
}

pub fn own_pid() -> u32 {
    unsafe { GetCurrentProcessId() }
}

pub fn is_window(hwnd: isize) -> bool {
    unsafe { IsWindow(HWND(hwnd as _)).as_bool() }
}

pub fn exe_path(pid: u32) -> Option<String> {
    unsafe {
        let h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let r = QueryFullProcessImageNameW(h, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut len);
        let _ = CloseHandle(h);
        r.ok()?;
        Some(String::from_utf16_lossy(&buf[..len as usize]))
    }
}

/// When the process started (100 ns ticks): with the pid, it tells a relaunch apart.
pub fn start_time(pid: u32) -> u64 {
    unsafe {
        let Ok(h) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return 0 };
        let (mut c, mut e, mut k, mut u) = (FILETIME::default(), FILETIME::default(), FILETIME::default(), FILETIME::default());
        let r = GetProcessTimes(h, &mut c, &mut e, &mut k, &mut u);
        let _ = CloseHandle(h);
        if r.is_err() {
            return 0;
        }
        ((c.dwHighDateTime as u64) << 32) | c.dwLowDateTime as u64
    }
}

/// The FileDescription of an executable ("Google Chrome"), cached.
fn file_description(path: &str) -> Option<String> {
    static CACHE: OnceLock<Mutex<HashMap<String, Option<String>>>> = OnceLock::new();
    let cache = CACHE.get_or_init(|| Mutex::new(HashMap::new()));
    if let Some(v) = cache.lock().get(path) {
        return v.clone();
    }
    let v = unsafe {
        (|| {
            let w = wide(path);
            let size = GetFileVersionInfoSizeW(PCWSTR(w.as_ptr()), None);
            if size == 0 {
                return None;
            }
            let mut data = vec![0u8; size as usize];
            GetFileVersionInfoW(PCWSTR(w.as_ptr()), 0, size, data.as_mut_ptr() as _).ok()?;
            // The first translation's language/codepage.
            let mut ptr = std::ptr::null_mut();
            let mut len = 0u32;
            let q = wide("\\VarFileInfo\\Translation");
            if !VerQueryValueW(data.as_ptr() as _, PCWSTR(q.as_ptr()), &mut ptr, &mut len).as_bool() || len < 4 {
                return None;
            }
            let pair = std::slice::from_raw_parts(ptr as *const u16, 2);
            let key = wide(&format!("\\StringFileInfo\\{:04x}{:04x}\\FileDescription", pair[0], pair[1]));
            let mut sptr = std::ptr::null_mut();
            let mut slen = 0u32;
            if !VerQueryValueW(data.as_ptr() as _, PCWSTR(key.as_ptr()), &mut sptr, &mut slen).as_bool() || slen == 0 {
                return None;
            }
            let s = String::from_utf16_lossy(std::slice::from_raw_parts(sptr as *const u16, slen as usize));
            let s = s.trim_end_matches('\0').trim().to_string();
            (!s.is_empty()).then_some(s)
        })()
    };
    cache.lock().insert(path.to_string(), v.clone());
    v
}

/// What a person calls the app behind a window.
pub fn friendly_name(hwnd: isize, exe_path: &str) -> String {
    let exe = std::path::Path::new(exe_path).file_name().map(|f| f.to_string_lossy().to_lowercase()).unwrap_or_default();
    let known = match exe.as_str() {
        "chrome.exe" => Some("Google Chrome"),
        "msedge.exe" => Some("Microsoft Edge"),
        "firefox.exe" => Some("Firefox"),
        "brave.exe" => Some("Brave"),
        "opera.exe" => Some("Opera"),
        "vivaldi.exe" => Some("Vivaldi"),
        "arc.exe" => Some("Arc"),
        "explorer.exe" => Some("File Explorer"),
        "notepad.exe" => Some("Notepad"),
        "windowsterminal.exe" => Some("Windows Terminal"),
        "code.exe" => Some("Visual Studio Code"),
        "winword.exe" => Some("Word"),
        "excel.exe" => Some("Excel"),
        "powerpnt.exe" => Some("PowerPoint"),
        "outlook.exe" | "olk.exe" => Some("Outlook"),
        "ms-teams.exe" | "teams.exe" => Some("Microsoft Teams"),
        "whatsapp.exe" | "whatsapp.root.exe" => Some("WhatsApp"),
        "spotify.exe" => Some("Spotify"),
        "slack.exe" => Some("Slack"),
        "discord.exe" => Some("Discord"),
        "systemsettings.exe" => Some("Settings"),
        _ => None,
    };
    if let Some(k) = known {
        return k.to_string();
    }
    // Store apps run inside a frame host: the window's title is the app's name.
    if exe == "applicationframehost.exe" {
        let t = window_title(hwnd);
        if !t.is_empty() {
            return t.rsplit(" - ").next().unwrap_or(&t).trim().to_string();
        }
    }
    file_description(exe_path)
        .filter(|d| d.len() <= 40)
        .unwrap_or_else(|| {
            let stem = std::path::Path::new(exe_path).file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
            let mut c = stem.chars();
            c.next().map(|f| f.to_uppercase().collect::<String>() + c.as_str()).unwrap_or_default()
        })
}

pub fn app_ref(hwnd: isize) -> Option<AppRef> {
    if hwnd == 0 || !is_window(hwnd) {
        return None;
    }
    let pid = pid_of(hwnd);
    let path = exe_path(pid).unwrap_or_default();
    let exe = std::path::Path::new(&path).file_name().map(|f| f.to_string_lossy().to_lowercase()).unwrap_or_default();
    Some(AppRef { pid, hwnd, name: friendly_name(hwnd, &path), exe, started: start_time(pid) })
}

/// The top-level window a dialog belongs to (itself when it's not owned).
pub fn root_owner(hwnd: isize) -> isize {
    let r = unsafe { GetAncestor(HWND(hwnd as _), GA_ROOTOWNER) };
    if r.0.is_null() {
        hwnd
    } else {
        r.0 as isize
    }
}

pub fn owner(hwnd: isize) -> Option<isize> {
    let o = unsafe { GetWindow(HWND(hwnd as _), GW_OWNER) }.ok()?;
    (!o.0.is_null()).then_some(o.0 as isize)
}

/// The foreground window, as (main window, dialog over it if any).
pub fn foreground() -> Option<(isize, Option<isize>)> {
    let fg = unsafe { GetForegroundWindow() };
    if fg.0.is_null() {
        return None;
    }
    let fg = fg.0 as isize;
    let main = root_owner(fg);
    Some(if main != fg { (main, Some(fg)) } else { (fg, if class_name(fg) == "#32770" { Some(fg) } else { None }) })
}

fn cloaked(hwnd: HWND) -> bool {
    let mut v: u32 = 0;
    unsafe { DwmGetWindowAttribute(hwnd, DWMWA_CLOAKED, &mut v as *mut u32 as _, 4) }.is_ok() && v != 0
}

/// Visible, real top-level windows (not tool windows, not cloaked), front to back.
pub fn top_windows() -> Vec<isize> {
    unsafe extern "system" fn each(h: HWND, l: LPARAM) -> BOOL {
        let v = &mut *(l.0 as *mut Vec<isize>);
        let ex = GetWindowLongW(h, GWL_EXSTYLE) as u32;
        if IsWindowVisible(h).as_bool()
            && GetWindow(h, GW_OWNER).map(|o| o.0.is_null()).unwrap_or(true)
            && ex & WS_EX_TOOLWINDOW.0 == 0
            && GetWindowTextLengthW(h) > 0
            && !cloaked(h)
        {
            v.push(h.0 as isize);
        }
        BOOL(1)
    }
    let mut v: Vec<isize> = vec![];
    unsafe {
        let _ = EnumWindows(Some(each), LPARAM(&mut v as *mut _ as isize));
    }
    v
}

pub fn running_apps() -> Vec<String> {
    let me = own_pid();
    let mut names: Vec<String> = vec![];
    for h in top_windows() {
        let pid = pid_of(h);
        if pid == me {
            continue;
        }
        let path = exe_path(pid).unwrap_or_default();
        let name = friendly_name(h, &path);
        let lower = name.to_lowercase();
        if !name.is_empty() && !names.iter().any(|n| n.to_lowercase() == lower) && !["program manager", "windows input experience", "textinputhost"].contains(&lower.as_str()) {
            names.push(name);
        }
    }
    names
}

/// The main window of a running app by name (friendly name, exe name or window title).
pub fn find_running(name: &str) -> Option<AppRef> {
    let want = name.to_lowercase().trim_end_matches(".exe").to_string();
    let me = own_pid();
    let mut best: Option<(AppRef, u8)> = None;
    for h in top_windows() {
        let Some(a) = app_ref(h) else { continue };
        if a.pid == me {
            continue;
        }
        let score = if a.name.to_lowercase() == want || a.exe.trim_end_matches(".exe") == want {
            3
        } else if a.name.to_lowercase().contains(&want) || (want.len() >= 4 && a.exe.contains(&want)) {
            2
        } else if want.len() >= 4 && window_title(h).to_lowercase().ends_with(&want) {
            1
        } else {
            0
        };
        if score > 0 && best.as_ref().map(|b| score > b.1).unwrap_or(true) {
            best = Some((a, score));
        }
    }
    best.map(|b| b.0)
}

pub fn window_rect(hwnd: isize) -> Option<Rect> {
    let mut r = RECT::default();
    unsafe {
        // The visible frame, without the invisible resize borders.
        if DwmGetWindowAttribute(HWND(hwnd as _), DWMWA_EXTENDED_FRAME_BOUNDS, &mut r as *mut RECT as _, std::mem::size_of::<RECT>() as u32).is_err() {
            GetWindowRect(HWND(hwnd as _), &mut r).ok()?;
        }
    }
    Some(Rect::new(r.left as f64, r.top as f64, (r.right - r.left) as f64, (r.bottom - r.top) as f64))
}

pub fn is_minimized(hwnd: isize) -> bool {
    unsafe { IsIconic(HWND(hwnd as _)).as_bool() }
}

fn tap_alt() {
    // Windows only lets the process that received the last input change the foreground window: a harmless key
    // (an unassigned virtual key) makes that us, and doesn't open any menu the way a bare Alt would.
    let k = |up: bool| INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 { ki: KEYBDINPUT { wVk: VIRTUAL_KEY(0xE8), wScan: 0, dwFlags: if up { KEYEVENTF_KEYUP } else { Default::default() }, time: 0, dwExtraInfo: 0 } },
    };
    unsafe {
        SendInput(&[k(false), k(true)], std::mem::size_of::<INPUT>() as i32);
    }
}

/// Brings a window to the front, restoring it when minimized; true when it's in front after.
pub fn bring_to_front(hwnd: isize) -> bool {
    let h = HWND(hwnd as _);
    unsafe {
        if IsIconic(h).as_bool() {
            let _ = ShowWindow(h, SW_RESTORE);
        }
        if GetForegroundWindow() == h {
            return true;
        }
        tap_alt();
        let _ = SetForegroundWindow(h);
        let _ = BringWindowToTop(h);
    }
    let deadline = Instant::now() + Duration::from_millis(400);
    while Instant::now() < deadline {
        if foreground().map(|f| f.0 == hwnd || f.1 == Some(hwnd)).unwrap_or(false) {
            return true;
        }
        std::thread::sleep(Duration::from_millis(20));
    }
    // Last resort: briefly topmost.
    unsafe {
        let _ = SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        let _ = SetWindowPos(h, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        tap_alt();
        let _ = SetForegroundWindow(h);
    }
    std::thread::sleep(Duration::from_millis(60));
    foreground().map(|f| f.0 == hwnd || f.1 == Some(hwnd)).unwrap_or(false)
}

pub const BROWSERS: &[&str] = &["chrome.exe", "msedge.exe", "brave.exe", "firefox.exe", "opera.exe", "vivaldi.exe", "arc.exe", "chromium.exe", "thorium.exe"];

pub fn is_browser_exe(exe: &str) -> bool {
    BROWSERS.contains(&exe.to_lowercase().as_str())
}

/// The default browser's name, from its https handler.
pub fn default_browser() -> Option<String> {
    use windows::Win32::System::Registry::{RegGetValueW, HKEY_CURRENT_USER, RRF_RT_REG_SZ};
    let key = wide(r"Software\Microsoft\Windows\Shell\Associations\UrlAssociations\https\UserChoice");
    let val = wide("ProgId");
    let mut buf = [0u16; 256];
    let mut len = (buf.len() * 2) as u32;
    unsafe { RegGetValueW(HKEY_CURRENT_USER, PCWSTR(key.as_ptr()), PCWSTR(val.as_ptr()), RRF_RT_REG_SZ, None, Some(buf.as_mut_ptr() as _), Some(&mut len)) }.ok().ok()?;
    let prog = String::from_utf16_lossy(&buf[..(len as usize / 2).saturating_sub(1)]).to_lowercase();
    Some(
        if prog.starts_with("chrome") {
            "Google Chrome"
        } else if prog.starts_with("msedge") {
            "Microsoft Edge"
        } else if prog.starts_with("firefox") {
            "Firefox"
        } else if prog.starts_with("brave") {
            "Brave"
        } else if prog.starts_with("opera") {
            "Opera"
        } else if prog.starts_with("vivaldi") {
            "Vivaldi"
        } else if prog.contains("arc") {
            "Arc"
        } else {
            return Some(prog);
        }
        .to_string(),
    )
}

// MARK: - Installed apps (Start menu)

#[derive(Clone, Debug)]
pub struct StartApp {
    pub name: String,
    pub app_id: String,
}

static START_APPS: Mutex<Option<(Instant, Vec<StartApp>)>> = Mutex::new(None);

/// The Start menu's apps (Win32 and Store), cached for an hour. Read through PowerShell's Get-StartApps.
pub fn start_apps() -> Vec<StartApp> {
    if let Some((t, v)) = START_APPS.lock().as_ref() {
        if t.elapsed() < Duration::from_secs(3600) {
            return v.clone();
        }
    }
    let out = crate::system::powershell_sync("Get-StartApps | ForEach-Object { $_.Name + \"`t\" + $_.AppID }", 20);
    let apps: Vec<StartApp> = out
        .lines()
        .filter_map(|l| {
            let (n, id) = l.split_once('\t')?;
            Some(StartApp { name: n.trim().to_string(), app_id: id.trim().to_string() })
        })
        .collect();
    if !apps.is_empty() {
        *START_APPS.lock() = Some((Instant::now(), apps.clone()));
    }
    apps
}

pub fn warm_start_apps() {
    std::thread::spawn(|| {
        let _ = start_apps();
    });
}

/// The installed app a person means by `name` (exact, then starts-with, then contains; common aliases).
pub fn find_installed(name: &str) -> Option<StartApp> {
    let mut want = name.to_lowercase().trim_end_matches(".exe").trim().to_string();
    let alias = match want.as_str() {
        "chrome" => Some("google chrome"),
        "edge" => Some("microsoft edge"),
        "explorer" | "finder" | "files" => Some("file explorer"),
        "terminal" => Some("terminal"),
        "vscode" | "vs code" | "code" => Some("visual studio code"),
        "control panel" => Some("control panel"),
        "store" | "app store" => Some("microsoft store"),
        "calendar" => Some("outlook (new)"),
        "mail" => Some("outlook (new)"),
        "settings" | "system settings" | "system preferences" => Some("settings"),
        _ => None,
    };
    if let Some(a) = alias {
        want = a.to_string();
    }
    let apps = start_apps();
    let n = |a: &StartApp| a.name.to_lowercase();
    apps.iter()
        .find(|a| n(a) == want)
        .or_else(|| apps.iter().find(|a| n(a).starts_with(&want)))
        .or_else(|| apps.iter().find(|a| n(a).contains(&want)))
        .or_else(|| apps.iter().find(|a| want.len() >= 4 && a.app_id.to_lowercase().contains(&want.replace(' ', ""))))
        .cloned()
}

pub fn launch_app_id(app_id: &str) -> bool {
    crate::system::shell_open(&format!("shell:AppsFolder\\{app_id}"))
}

// MARK: - Window operations

pub fn window_op(hwnd: isize, op: WindowOp) -> (bool, String) {
    let h = HWND(hwnd as _);
    let settle = |check: &dyn Fn() -> bool| {
        let deadline = Instant::now() + Duration::from_millis(800);
        while Instant::now() < deadline {
            if check() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(40));
        }
        check()
    };
    unsafe {
        match op {
            WindowOp::Move(Point { x, y }) => {
                if IsZoomed(h).as_bool() {
                    let _ = ShowWindow(h, SW_RESTORE);
                }
                let _ = SetWindowPos(h, HWND::default(), x as i32, y as i32, 0, 0, SWP_NOSIZE | SWP_NOZORDER | SWP_NOACTIVATE);
                let ok = settle(&|| window_rect(hwnd).map(|r| (r.x - x).abs() <= 10.0 && (r.y - y).abs() <= 10.0).unwrap_or(false));
                (ok, if ok { format!("moved to {},{}", x as i64, y as i64) } else { "the window didn't move there".into() })
            }
            WindowOp::Resize(w, hgt) => {
                if IsZoomed(h).as_bool() {
                    let _ = ShowWindow(h, SW_RESTORE);
                }
                let _ = SetWindowPos(h, HWND::default(), 0, 0, w as i32, hgt as i32, SWP_NOMOVE | SWP_NOZORDER | SWP_NOACTIVATE);
                let ok = settle(&|| window_rect(hwnd).map(|r| (r.w - w).abs() <= 16.0 && (r.h - hgt).abs() <= 16.0).unwrap_or(false));
                let now = window_rect(hwnd).map(|r| format!("{}×{}", r.w as i64, r.h as i64)).unwrap_or_default();
                (ok, if ok { format!("resized to {}×{}", w as i64, hgt as i64) } else { format!("the app kept it at {now}") })
            }
            WindowOp::Minimize => {
                let _ = ShowWindow(h, SW_MINIMIZE);
                let ok = settle(&|| IsIconic(h).as_bool());
                (ok, if ok { "minimized".into() } else { "the window didn't minimize".into() })
            }
            WindowOp::Restore => {
                if !IsIconic(h).as_bool() && !IsZoomed(h).as_bool() {
                    return (true, "not minimized".into());
                }
                let _ = ShowWindow(h, SW_RESTORE);
                bring_to_front(hwnd);
                let ok = settle(&|| !IsIconic(h).as_bool());
                (ok, if ok { "restored".into() } else { "the window stayed minimized".into() })
            }
            WindowOp::Maximize(on) => {
                let _ = ShowWindow(h, if on { SW_MAXIMIZE } else { SW_RESTORE });
                let ok = settle(&|| IsZoomed(h).as_bool() == on);
                (ok, if !ok { "the window size didn't change".into() } else if on { "maximized".into() } else { "restored to its normal size".into() })
            }
            WindowOp::Close => {
                let _ = PostMessageW(h, WM_CLOSE, windows::Win32::Foundation::WPARAM(0), LPARAM(0));
                let ok = settle(&|| !IsWindow(h).as_bool() || !IsWindowVisible(h).as_bool());
                (ok, if ok { "closed".into() } else { "the window is still open (it may be asking something: look)".into() })
            }
            WindowOp::Raise => {
                let ok = bring_to_front(hwnd);
                (ok, if ok { "raised".into() } else { "the window didn't come forward".into() })
            }
        }
    }
}

/// The window of `app` whose title contains `title`.
pub fn window_titled(pid: u32, title: &str) -> Option<isize> {
    let want = title.to_lowercase();
    top_windows().into_iter().find(|h| pid_of(*h) == pid && window_title(*h).to_lowercase().contains(&want))
}

/// A friendly-name/exe lookup that also covers minimized windows of the app.
pub fn main_window_of(pid: u32) -> Option<isize> {
    top_windows().into_iter().find(|h| pid_of(*h) == pid)
}

/// The process owning the top-level window at a screen point. Apps built on WebView2 (WhatsApp, Teams, the new
/// Outlook…) draw their content in a child window of another process (msedgewebview2.exe); its top-level window is
/// still the app's.
pub fn root_pid_at(x: f64, y: f64) -> Option<u32> {
    unsafe {
        let h = WindowFromPoint(windows::Win32::Foundation::POINT { x: x as i32, y: y as i32 });
        if h.0.is_null() {
            return None;
        }
        let root = GetAncestor(h, GA_ROOT);
        Some(pid_of(if root.0.is_null() { h.0 as isize } else { root.0 as isize }))
    }
}
