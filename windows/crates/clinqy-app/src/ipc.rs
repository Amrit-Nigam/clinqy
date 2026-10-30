//! How the `clinqy` command (and the MCP server, and clinqy:// links) talk to the running app: JSON lines over a
//! per-user named pipe. Every request carries the token in ~/.config/clinqy/cli-token, as on the Mac, so nothing
//! else on the machine can start tasks. Long requests (run, qa) stream events back until they finish.

use anyhow::{anyhow, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::windows::named_pipe::{ClientOptions, NamedPipeClient};

pub fn pipe_name() -> String {
    let user: String = std::env::var("USERNAME").unwrap_or_else(|_| "user".into()).chars().filter(|c| c.is_alphanumeric()).collect();
    format!(r"\\.\pipe\clinqy-{user}")
}

/// The CLI token (created by the app on first launch).
pub fn token() -> String {
    let path = clinqy_core::paths::config_dir().join("cli-token");
    if let Ok(t) = std::fs::read_to_string(&path) {
        let t = t.trim().to_string();
        if !t.is_empty() {
            return t;
        }
    }
    let t = uuid::Uuid::new_v4().simple().to_string();
    let _ = std::fs::write(&path, &t);
    t
}

#[derive(Serialize, Deserialize, Debug, Clone)]
pub struct Request {
    pub token: String,
    pub cmd: String,
    #[serde(default)]
    pub args: Value,
}

/// One line back: {"event": "step"|"log"|"done"|"error"|"ok", ...}.
pub type Reply = Value;

async fn connect() -> Result<NamedPipeClient> {
    let name = pipe_name();
    for _ in 0..40 {
        match ClientOptions::new().open(&name) {
            Ok(c) => return Ok(c),
            // All instances busy: try again shortly.
            Err(e) if e.raw_os_error() == Some(231) => tokio::time::sleep(Duration::from_millis(50)).await,
            Err(e) => return Err(anyhow!("Clinqy isn't running ({e})")),
        }
    }
    Err(anyhow!("Clinqy is busy"))
}

/// Sends a request and calls `on` for every reply line until one says it's the end (`"end": true`).
pub async fn call(cmd: &str, args: Value, mut on: impl FnMut(&Reply)) -> Result<Reply> {
    let mut pipe = connect().await?;
    let req = Request { token: token(), cmd: cmd.into(), args };
    let mut line = serde_json::to_string(&req)?;
    line.push('\n');
    pipe.write_all(line.as_bytes()).await?;
    let mut lines = BufReader::new(pipe).lines();
    while let Some(l) = lines.next_line().await? {
        let Ok(v) = serde_json::from_str::<Value>(&l) else { continue };
        on(&v);
        if v["end"] == true {
            return Ok(v);
        }
    }
    Err(anyhow!("Clinqy closed the connection"))
}

/// Whether the app is up (its pipe answers).
pub async fn app_running() -> bool {
    ClientOptions::new().open(pipe_name()).is_ok() || matches!(ClientOptions::new().open(pipe_name()), Err(e) if e.raw_os_error() == Some(231))
}

/// Starts the app through the shell: a child of this process inherits its output handles even when redirected, and
/// whatever reads this process's output would then wait for the app to quit.
pub fn start_detached(exe: &std::path::Path, login: bool) -> std::io::Result<()> {
    use std::process::Stdio;
    let script = format!("Start-Process -FilePath $env:CLINQY_EXE{}", if login { " -ArgumentList '--login'" } else { "" });
    let status = std::process::Command::new("powershell")
        .args(["-NoProfile", "-Command", &script])
        .env("CLINQY_EXE", exe)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;
    status.success().then_some(()).ok_or_else(|| std::io::Error::other("Start-Process failed"))
}

/// Starts the app if it isn't running and waits for its pipe.
pub async fn ensure_app() -> Result<()> {
    if app_running().await {
        return Ok(());
    }
    let exe = app_exe().ok_or_else(|| anyhow!("ClinqyApp.exe isn't installed next to the clinqy command (run the installer again)"))?;
    start_detached(&exe, false).map_err(|e| anyhow!("couldn't start {}: {e}", exe.display()))?;
    for _ in 0..80 {
        tokio::time::sleep(Duration::from_millis(250)).await;
        if app_running().await {
            // Let a browser's extension reconnect.
            tokio::time::sleep(Duration::from_millis(800)).await;
            return Ok(());
        }
    }
    Err(anyhow!("Clinqy didn't start"))
}

/// ClinqyApp.exe: next to this executable, or in the install folder.
pub fn app_exe() -> Option<std::path::PathBuf> {
    let here = std::env::current_exe().ok()?.parent()?.to_path_buf();
    let mut spots = vec![here.join("ClinqyApp.exe"), here.join("..").join("ClinqyApp.exe")];
    if let Ok(local) = std::env::var("LOCALAPPDATA") {
        spots.push(std::path::PathBuf::from(local).join("Programs").join("Clinqy").join("ClinqyApp.exe"));
    }
    spots.into_iter().find(|p| p.is_file())
}
