//! System odds and ends: PowerShell, opening things, the Recycle Bin, whether a call is on (the mic in use) or
//! the PC is locked, the user's display name, which program owns a local socket, and Windows Search.

use crate::com::wide;
use clinqy_core::platform::{FileHit, FileQuery};
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;
use windows::core::PCWSTR;
use windows::Win32::UI::Shell::{ShellExecuteW, SHFileOperationW, FOF_ALLOWUNDO, FOF_NOCONFIRMATION, FOF_NOERRORUI, FOF_SILENT, FO_DELETE, SHFILEOPSTRUCTW};
use windows::Win32::UI::WindowsAndMessaging::SW_SHOWNORMAL;

const NO_WINDOW: u32 = 0x0800_0000;

/// A PowerShell script as an -EncodedCommand (no quoting trouble), output as UTF-8.
fn encoded(script: &str) -> String {
    let full = format!("$ProgressPreference='SilentlyContinue'; [Console]::OutputEncoding=[Text.Encoding]::UTF8; {script}");
    let bytes: Vec<u8> = full.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
    use base64::Engine;
    base64::engine::general_purpose::STANDARD.encode(bytes)
}

fn powershell_exe() -> PathBuf {
    let sys = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
    PathBuf::from(sys).join(r"System32\WindowsPowerShell\v1.0\powershell.exe")
}

/// Runs a script and returns its output (stdout and stderr), waiting at most `timeout` seconds.
pub fn powershell_sync(script: &str, timeout: u64) -> String {
    let Ok(mut child) = Command::new(powershell_exe())
        .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", &encoded(script)])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .creation_flags(NO_WINDOW)
        .spawn()
    else {
        return String::new();
    };
    let deadline = std::time::Instant::now() + Duration::from_secs(timeout);
    loop {
        if let Ok(Some(_)) = child.try_wait() {
            break;
        }
        if std::time::Instant::now() > deadline {
            let _ = child.kill();
            break;
        }
        std::thread::sleep(Duration::from_millis(30));
    }
    child.wait_with_output().map(|o| String::from_utf8_lossy(&o.stdout).into_owned() + &String::from_utf8_lossy(&o.stderr)).unwrap_or_default()
}

/// Runs a PowerShell command for the agent: (exit code, output), stopped after `timeout` seconds.
pub async fn powershell(script: &str, timeout: u64) -> (i32, String) {
    let child = tokio::process::Command::new(powershell_exe())
        .args(["-NoLogo", "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-EncodedCommand", &encoded(script)])
        .current_dir(clinqy_core::paths::home())
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .creation_flags(NO_WINDOW)
        .spawn();
    let Ok(child) = child else { return (-1, "couldn't start PowerShell".into()) };
    match tokio::time::timeout(Duration::from_secs(timeout), child.wait_with_output()).await {
        Ok(Ok(o)) => {
            let mut out = String::from_utf8_lossy(&o.stdout).trim_end().to_string();
            let err = String::from_utf8_lossy(&o.stderr);
            let err = err.trim();
            if !err.is_empty() {
                if !out.is_empty() {
                    out.push('\n');
                }
                out += err;
            }
            let code = o.status.code().unwrap_or(-1);
            // PowerShell exits 0 even when a cmdlet errored: an error record means it failed.
            let failed = code != 0 || (out.is_empty() && !err.is_empty()) || err.contains("FullyQualifiedErrorId");
            (if failed && code == 0 { 1 } else { code }, out)
        }
        Ok(Err(e)) => (-1, e.to_string()),
        Err(_) => (124, format!("stopped after {timeout} s (use media or pdf for long jobs)")),
    }
}

/// Opens a file, folder, URL or shell: target with its default handler.
pub fn shell_open(target: &str) -> bool {
    let op = wide("open");
    let t = wide(target);
    let r = unsafe { ShellExecuteW(None, PCWSTR(op.as_ptr()), PCWSTR(t.as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL) };
    r.0 as isize > 32
}

/// Selects files in a File Explorer window.
pub fn reveal(paths: &[PathBuf]) {
    if let Some(first) = paths.first() {
        let _ = Command::new("explorer.exe").raw_arg(format!("/select,\"{}\"", first.display())).spawn();
    }
}

/// To the Recycle Bin (recoverable).
pub fn trash(paths: &[PathBuf]) -> Result<usize, String> {
    let mut list: Vec<u16> = vec![];
    for p in paths {
        list.extend(p.display().to_string().encode_utf16());
        list.push(0);
    }
    list.push(0);
    let mut op = SHFILEOPSTRUCTW {
        wFunc: FO_DELETE,
        pFrom: PCWSTR(list.as_ptr()),
        fFlags: (FOF_ALLOWUNDO | FOF_NOCONFIRMATION | FOF_SILENT | FOF_NOERRORUI).0 as u16,
        ..Default::default()
    };
    let r = unsafe { SHFileOperationW(&mut op) };
    if r != 0 {
        return Err(format!("Windows couldn't move them to the Recycle Bin (error {r})"));
    }
    Ok(paths.iter().filter(|p| !p.exists()).count())
}

/// Another app is using the microphone right now (a call or meeting), from Windows' privacy bookkeeping.
pub fn mic_in_use() -> bool {
    use windows::Win32::System::Registry::*;
    let me = std::env::current_exe().ok().map(|p| p.display().to_string().replace('\\', "#").to_lowercase()).unwrap_or_default();
    let root = r"Software\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\microphone";
    let in_use = |path: &str, name_hint: &str| -> bool {
        if !me.is_empty() && name_hint.to_lowercase() == me {
            return false;
        }
        let k = wide(path);
        let v = wide("LastUsedTimeStop");
        let mut data: u64 = 1;
        let mut size = 8u32;
        let r = unsafe { RegGetValueW(HKEY_CURRENT_USER, PCWSTR(k.as_ptr()), PCWSTR(v.as_ptr()), RRF_RT_REG_QWORD, None, Some(&mut data as *mut u64 as _), Some(&mut size)) };
        if r.is_err() {
            return false;
        }
        let start = wide("LastUsedTimeStart");
        let mut s: u64 = 0;
        let mut size = 8u32;
        let _ = unsafe { RegGetValueW(HKEY_CURRENT_USER, PCWSTR(k.as_ptr()), PCWSTR(start.as_ptr()), RRF_RT_REG_QWORD, None, Some(&mut s as *mut u64 as _), Some(&mut size)) };
        data == 0 && s != 0
    };
    let subkeys = |path: &str| -> Vec<String> {
        let mut out = vec![];
        unsafe {
            let k = wide(path);
            let mut h = HKEY::default();
            if RegOpenKeyExW(HKEY_CURRENT_USER, PCWSTR(k.as_ptr()), 0, KEY_READ, &mut h).is_err() {
                return out;
            }
            let mut i = 0;
            loop {
                let mut buf = [0u16; 512];
                let mut len = buf.len() as u32;
                if RegEnumKeyExW(h, i, windows::core::PWSTR(buf.as_mut_ptr()), &mut len, None, windows::core::PWSTR::null(), None, None).is_err() {
                    break;
                }
                out.push(String::from_utf16_lossy(&buf[..len as usize]));
                i += 1;
            }
            let _ = RegCloseKey(h);
        }
        out
    };
    for name in subkeys(root) {
        if name == "NonPackaged" {
            for app in subkeys(&format!("{root}\\NonPackaged")) {
                if in_use(&format!("{root}\\NonPackaged\\{app}"), &app) {
                    return true;
                }
            }
        } else if in_use(&format!("{root}\\{name}"), &name) {
            return true;
        }
    }
    false
}

/// The workstation is locked (the input desktop isn't the user's).
pub fn screen_locked() -> bool {
    use windows::Win32::System::StationsAndDesktops::{CloseDesktop, OpenInputDesktop, DESKTOP_CONTROL_FLAGS, DESKTOP_SWITCHDESKTOP};
    unsafe {
        match OpenInputDesktop(DESKTOP_CONTROL_FLAGS(0), false, DESKTOP_SWITCHDESKTOP) {
            Ok(h) => {
                let _ = CloseDesktop(h);
                false
            }
            Err(_) => true,
        }
    }
}

/// The user's display name ("Amrit Nigam"), else their account name.
pub fn full_user_name() -> String {
    use windows::Win32::Security::Authentication::Identity::{GetUserNameExW, NameDisplay};
    let mut buf = [0u16; 256];
    let mut len = buf.len() as u32;
    if unsafe { GetUserNameExW(NameDisplay, windows::core::PWSTR(buf.as_mut_ptr()), &mut len) }.as_bool() && len > 0 {
        let s = String::from_utf16_lossy(&buf[..len as usize]);
        if !s.trim().is_empty() {
            return s;
        }
    }
    // Local accounts: the full name Windows keeps for the account.
    let out = powershell_sync("(Get-LocalUser -Name $env:USERNAME -ErrorAction SilentlyContinue).FullName", 8);
    let n = out.trim();
    if !n.is_empty() && !n.contains("Get-LocalUser") {
        return n.to_string();
    }
    std::env::var("USERNAME").unwrap_or_default()
}

/// The program (exe name) on the other end of a local TCP connection whose port is `port`.
pub fn owner_of_port(port: u16) -> Option<String> {
    use windows::Win32::NetworkManagement::IpHelper::{GetExtendedTcpTable, MIB_TCPTABLE_OWNER_PID, TCP_TABLE_OWNER_PID_ALL};
    use windows::Win32::Networking::WinSock::AF_INET;
    unsafe {
        let mut size = 0u32;
        let _ = GetExtendedTcpTable(None, &mut size, false, AF_INET.0 as u32, TCP_TABLE_OWNER_PID_ALL, 0);
        let mut buf = vec![0u8; size as usize + 1024];
        if GetExtendedTcpTable(Some(buf.as_mut_ptr() as _), &mut size, false, AF_INET.0 as u32, TCP_TABLE_OWNER_PID_ALL, 0) != 0 {
            return None;
        }
        let table = &*(buf.as_ptr() as *const MIB_TCPTABLE_OWNER_PID);
        let rows = std::slice::from_raw_parts(table.table.as_ptr(), table.dwNumEntries as usize);
        let me = crate::apps::own_pid();
        for r in rows {
            let local = u16::from_be((r.dwLocalPort & 0xffff) as u16);
            if local == port && r.dwOwningPid != me {
                let path = crate::apps::exe_path(r.dwOwningPid)?;
                return Path::new(&path).file_name().map(|f| f.to_string_lossy().to_lowercase());
            }
        }
    }
    None
}

// MARK: - Windows Search

fn sql_quote(s: &str) -> String {
    s.replace('\'', "''")
}

fn kind_clause(kind: &str) -> String {
    let exts = |list: &[&str]| format!("({})", list.iter().map(|e| format!("System.FileExtension = '.{e}'")).collect::<Vec<_>>().join(" OR "));
    let k = kind.trim().trim_start_matches('.').to_lowercase();
    let k = k.strip_suffix('s').filter(|_| k.len() > 3).map(String::from).unwrap_or(k);
    match k.as_str() {
        "pdf" => exts(&["pdf"]),
        "image" | "photo" | "picture" => "System.Kind = 'picture'".into(),
        "video" | "movie" => "System.Kind = 'video'".into(),
        "audio" | "music" | "song" => "System.Kind = 'music'".into(),
        "document" | "doc" => "(System.Kind = 'document' OR System.FileExtension = '.pdf')".into(),
        "spreadsheet" | "sheet" | "excel" => exts(&["xlsx", "xls", "csv", "ods"]),
        "presentation" | "slide" | "deck" => exts(&["pptx", "ppt", "odp"]),
        "archive" | "zip" => exts(&["zip", "rar", "7z", "tar", "gz"]),
        "folder" | "directory" => "System.Kind = 'folder'".into(),
        "app" | "program" => exts(&["exe", "msi", "lnk"]),
        other => exts(&[other]),
    }
}

/// Where a downloaded file came from (its Zone.Identifier stream: the page and the file's address).
pub fn downloaded_from(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(format!("{}:Zone.Identifier", path.display())).ok()?;
    let mut parts = vec![];
    for line in text.lines() {
        if let Some(v) = line.strip_prefix("ReferrerUrl=").or_else(|| line.strip_prefix("HostUrl=")) {
            parts.push(v.trim().to_string());
        }
    }
    (!parts.is_empty()).then(|| parts.join(" "))
}

pub fn search_files(q: &FileQuery) -> Vec<FileHit> {
    let home = clinqy_core::paths::home();
    let scope = q.folder.clone().unwrap_or_else(|| home.clone());
    let limit = q.limit.clamp(1, 50);
    let mut clauses = vec![format!("SCOPE='file:{}'", sql_quote(&scope.display().to_string().replace('\\', "/")))];
    for w in q.words.as_deref().unwrap_or("").split_whitespace().filter(|w| w.chars().count() >= 2) {
        let w = sql_quote(&w.replace(['"', '%', '*'], ""));
        clauses.push(format!("(System.FileName LIKE '%{w}%' OR CONTAINS(*, '\"{w}*\"'))"));
    }
    if let Some(k) = q.kind.as_deref().filter(|k| !k.is_empty()) {
        clauses.push(kind_clause(k));
    }
    let days = q.days.filter(|d| *d > 0);
    if let Some(d) = days.or(if q.words.is_none() && q.kind.is_none() && q.from.is_none() { Some(7) } else { None }) {
        let since = (chrono::Local::now() - chrono::Duration::days(d as i64)).format("%Y-%m-%d").to_string();
        clauses.push(format!("(System.DateModified >= '{since}' OR System.DateCreated >= '{since}')"));
    }
    let from = q.from.as_deref().map(|f| f.to_lowercase()).filter(|f| !f.is_empty());
    let top = if from.is_some() { 300 } else { limit * 3 };
    let sql = format!(
        "SELECT TOP {top} System.ItemPathDisplay, System.Size, System.DateModified FROM SystemIndex WHERE {} ORDER BY System.DateModified DESC",
        clauses.join(" AND ")
    );
    let script = format!(
        "$c = New-Object -ComObject ADODB.Connection; $c.Open(\"Provider=Search.CollatorDSO;Extended Properties='Application=Windows';\"); $r = $c.Execute(\"{}\"); while (-not $r.EOF) {{ $d = $r.Fields.Item('System.DateModified').Value; \"$($r.Fields.Item('System.ItemPathDisplay').Value)`t$($r.Fields.Item('System.Size').Value)`t$(if ($d) {{ ([datetime]$d).ToString('yyyy-MM-dd HH:mm') }})\"; $r.MoveNext() }}",
        sql.replace('"', "\"\"").replace('`', "``").replace('$', "`$")
    );
    let out = powershell_sync(&script, 15);
    let junk = ["\\appdata\\", "\\node_modules\\", "\\.git\\", "\\$recycle.bin\\", "\\windows\\winsxs"];
    let mut hits: Vec<FileHit> = out
        .lines()
        .filter_map(|l| {
            let mut p = l.split('\t');
            let path = PathBuf::from(p.next()?.trim());
            if !path.is_absolute() || junk.iter().any(|j| path.display().to_string().to_lowercase().contains(j)) {
                return None;
            }
            Some(FileHit { size: p.next().and_then(|s| s.trim().parse().ok()).unwrap_or(0), modified: p.next().unwrap_or("").trim().to_string(), from: downloaded_from(&path), path })
        })
        .collect();
    // The index can be off (or not cover a folder): look through the usual folders by name.
    if hits.is_empty() && !out.contains("System.ItemPathDisplay") {
        hits = walk_search(q, &scope);
    }
    if let Some(f) = &from {
        hits.retain(|h| h.from.as_deref().map(|x| x.to_lowercase().contains(f.as_str())).unwrap_or(false) || h.path.display().to_string().to_lowercase().contains(f.as_str()));
    }
    hits.truncate(limit);
    hits
}

/// A plain walk of Desktop, Downloads and Documents (three levels), matching names.
fn walk_search(q: &FileQuery, scope: &Path) -> Vec<FileHit> {
    let home = clinqy_core::paths::home();
    let roots: Vec<PathBuf> = if scope == home { ["Desktop", "Downloads", "Documents", "Pictures", "Videos", "Music", "OneDrive"].iter().map(|d| home.join(d)).collect() } else { vec![scope.to_path_buf()] };
    let words: Vec<String> = q.words.as_deref().unwrap_or("").split_whitespace().map(|w| w.to_lowercase()).collect();
    let ext: Option<String> = q.kind.as_deref().map(|k| k.trim_start_matches('.').to_lowercase()).filter(|k| k.len() <= 5 && !["image", "video", "audio", "photo", "music"].contains(&k.as_str()));
    let since = q.days.map(|d| std::time::SystemTime::now() - Duration::from_secs(d as u64 * 86400));
    let mut out = vec![];
    let mut stack: Vec<(PathBuf, u32)> = roots.into_iter().map(|r| (r, 0)).collect();
    while let Some((dir, depth)) = stack.pop() {
        let Ok(rd) = std::fs::read_dir(&dir) else { continue };
        for e in rd.flatten() {
            let p = e.path();
            let name = e.file_name().to_string_lossy().to_lowercase();
            let Ok(m) = e.metadata() else { continue };
            if m.is_dir() {
                if depth < 3 && !name.starts_with('.') && name != "node_modules" {
                    stack.push((p, depth + 1));
                }
                continue;
            }
            if !words.iter().all(|w| name.contains(w.as_str())) {
                continue;
            }
            if let Some(x) = &ext {
                if !name.ends_with(&format!(".{x}")) {
                    continue;
                }
            }
            let modified = m.modified().unwrap_or(std::time::UNIX_EPOCH);
            if since.map(|s| modified < s).unwrap_or(false) {
                continue;
            }
            let when: chrono::DateTime<chrono::Local> = modified.into();
            out.push((modified, FileHit { size: m.len(), modified: when.format("%Y-%m-%d %H:%M").to_string(), from: downloaded_from(&p), path: p }));
        }
    }
    out.sort_by(|a, b| b.0.cmp(&a.0));
    out.into_iter().map(|x| x.1).take(200).collect()
}
