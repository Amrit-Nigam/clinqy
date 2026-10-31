//! `clinqy update`: finds the newest Windows release, checks the download against GitHub's SHA-256 and runs its own
//! installer, which replaces the old version and keeps settings and data. The app looks once at launch and offers it.

use anyhow::{anyhow, Context, Result};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::Duration;

const RELEASES: &str = "https://api.github.com/repos/Amrit-Nigam/clinqy/releases?per_page=50";
const ZIP: &str = "Clinqy-windows-x64.zip";
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Debug, PartialEq)]
pub struct Release {
    pub version: String,
    pub url: String,
    pub sha256: String,
}

fn parts(version: &str) -> Option<(u32, u32, u32)> {
    let mut p = version.split('.').map(|n| n.parse::<u32>().ok());
    Some((p.next()??, p.next()??, p.next()??))
}

/// True when `version` is later than `than`.
pub fn newer(version: &str, than: &str) -> bool {
    matches!((parts(version), parts(than)), (Some(a), Some(b)) if a > b)
}

/// The newest published Windows release in GitHub's list. Mac releases share the repo, so "latest" can't be trusted.
fn newest(releases: &Value) -> Option<Release> {
    releases
        .as_array()?
        .iter()
        .filter(|r| r["draft"] != true && r["prerelease"] != true)
        .filter_map(|r| {
            let version = r["tag_name"].as_str()?.strip_prefix("windows-v")?.to_string();
            parts(&version)?;
            let zip = r["assets"].as_array()?.iter().find(|a| a["name"] == ZIP)?;
            Some(Release {
                version,
                url: zip["browser_download_url"].as_str()?.to_string(),
                sha256: zip["digest"].as_str().and_then(|d| d.strip_prefix("sha256:")).unwrap_or("").to_string(),
            })
        })
        .max_by_key(|r| parts(&r.version))
}

fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder().user_agent(concat!("Clinqy/", env!("CARGO_PKG_VERSION"))).connect_timeout(Duration::from_secs(15)).build()?)
}

pub async fn latest() -> Result<Release> {
    let list: Value = client()?.get(RELEASES).timeout(Duration::from_secs(20)).send().await?.error_for_status()?.json().await?;
    newest(&list).ok_or_else(|| anyhow!("no Windows release found"))
}

/// A newer version than this one, if there is one. For the app's check at launch.
pub fn available() -> Option<String> {
    let rt = tokio::runtime::Builder::new_current_thread().enable_all().build().ok()?;
    let release = rt.block_on(latest()).ok()?;
    newer(&release.version, env!("CARGO_PKG_VERSION")).then_some(release.version)
}

fn install_dir() -> Result<PathBuf> {
    Ok(PathBuf::from(std::env::var("LOCALAPPDATA").context("LOCALAPPDATA isn't set")?).join("Programs").join("Clinqy"))
}

fn powershell() -> Command {
    let mut c = Command::new("powershell");
    c.args(["-NoProfile", "-ExecutionPolicy", "Bypass"]);
    c
}

/// Checks the zip against its SHA-256 and unpacks it. Nothing is installed unless they match.
fn verify_and_unpack(zip: &Path, to: &Path, sha256: &str) -> Result<()> {
    let script = "if ((Get-FileHash -LiteralPath $env:CLINQY_ZIP -Algorithm SHA256).Hash -ne $env:CLINQY_SHA) { exit 3 }; \
                  Expand-Archive -LiteralPath $env:CLINQY_ZIP -DestinationPath $env:CLINQY_TO -Force";
    let status = powershell().args(["-Command", script]).env("CLINQY_ZIP", zip).env("CLINQY_SHA", sha256).env("CLINQY_TO", to).status()?;
    match status.code() {
        Some(0) => Ok(()),
        Some(3) => Err(anyhow!("the download doesn't match the release's SHA-256, so nothing was installed")),
        _ => Err(anyhow!("couldn't unpack the download")),
    }
}

/// Downloads, verifies and installs `release`, then starts the new version without opening the bar.
fn install(release: &Release, rt: &tokio::runtime::Runtime) -> Result<()> {
    if release.sha256.is_empty() {
        return Err(anyhow!("this release has no SHA-256 to check against, so nothing was installed"));
    }
    let temp = std::env::temp_dir().join(format!("clinqy-update-{}", uuid::Uuid::new_v4()));
    std::fs::create_dir_all(&temp)?;
    let result = (|| {
        println!("Downloading Clinqy {}…", release.version);
        let zip = temp.join(ZIP);
        let bytes = rt.block_on(async { client()?.get(&release.url).send().await?.error_for_status()?.bytes().await.map_err(anyhow::Error::from) })?;
        std::fs::write(&zip, &bytes)?;
        println!("Checking it…");
        let unpacked = temp.join("x");
        verify_and_unpack(&zip, &unpacked, &release.sha256)?;
        println!("Installing…");
        let ok = powershell().arg("-File").arg(unpacked.join("install.ps1")).arg("-NoStart").status()?.success();
        if !ok {
            return Err(anyhow!("the installer failed"));
        }
        Ok(())
    })();
    let _ = std::fs::remove_dir_all(&temp);
    // The installer stops the app before it can fail, so start it whichever way that went.
    let _ = crate::ipc::start_detached(&install_dir()?.join("ClinqyApp.exe"), true);
    result
}

/// `clinqy update [--check] [--force]`
pub fn command(rest: &[String]) -> i32 {
    let rt = crate::cli::rt();
    let current = env!("CARGO_PKG_VERSION");
    let release = match rt.block_on(latest()) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("Couldn't check for updates: {e}");
            return 1;
        }
    };
    let flag = |f: &str| rest.iter().any(|r| r == f);
    if !newer(&release.version, current) && !flag("--force") {
        println!("Clinqy {current} is up to date.");
        return 0;
    }
    if newer(&release.version, current) {
        println!("Clinqy {} is available (you have {current}).", release.version);
    }
    if flag("--check") {
        return 0;
    }
    let busy = rt.block_on(async {
        if !crate::ipc::app_running().await {
            return false;
        }
        crate::ipc::call("status", serde_json::json!({}), |_| {}).await.map(|v| v["snapshot"]["running"] == true).unwrap_or(false)
    });
    if busy {
        eprintln!("Clinqy is working on a task, and updating would stop it. Run this again when it's finished.");
        return 1;
    }
    match install(&release, &rt) {
        Ok(()) => {
            println!("Clinqy {} is installed. Restart any coding agent connected to Clinqy.", release.version);
            0
        }
        Err(e) => {
            eprintln!("Couldn't update: {e}");
            1
        }
    }
}

/// Runs `clinqy update` from the app, which it will restart. False if it failed before stopping the app.
pub fn run_from_app() -> bool {
    use std::os::windows::process::CommandExt;
    let Some(cli) = std::env::current_exe().ok().map(|e| e.with_file_name("clinqy.exe")) else { return false };
    Command::new(cli).arg("update").creation_flags(CREATE_NO_WINDOW).status().map(|s| s.success()).unwrap_or(false)
}

/// Deletes files the installer moved aside because they were running. One still in use stays for next time.
pub fn remove_old_files() {
    let Some(dir) = std::env::current_exe().ok().and_then(|e| e.parent().map(Path::to_path_buf)) else { return };
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().contains(".old-") {
            let _ = std::fs::remove_file(entry.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn release(tag: &str, draft: bool, prerelease: bool) -> Value {
        json!({"tag_name": tag, "draft": draft, "prerelease": prerelease, "assets": [
            {"name": ZIP, "browser_download_url": format!("https://x/{tag}.zip"), "digest": format!("sha256:{tag}")}
        ]})
    }

    #[test]
    fn compares_versions_as_numbers() {
        assert!(newer("0.3.1", "0.3.0"));
        assert!(newer("0.10.0", "0.9.9"));
        assert!(!newer("0.3.0", "0.3.0"));
        assert!(!newer("0.2.9", "0.3.0"));
        assert!(!newer("rubbish", "0.3.0"));
    }

    #[test]
    fn picks_the_newest_published_windows_release() {
        let list = json!([
            release("mac-v9.9.9", false, false),
            release("windows-v0.9.0", true, false),
            release("windows-v0.8.0", false, true),
            release("windows-v0.3.0", false, false),
            release("windows-v0.10.0", false, false),
        ]);
        let r = newest(&list).unwrap();
        assert_eq!((r.version.as_str(), r.sha256.as_str()), ("0.10.0", "windows-v0.10.0"));
    }

    #[test]
    fn a_release_without_the_zip_doesnt_count() {
        let list = json!([{"tag_name": "windows-v0.4.0", "assets": []}, release("windows-v0.3.0", false, false)]);
        assert_eq!(newest(&list).unwrap().version, "0.3.0");
    }

    #[test]
    fn no_digest_leaves_the_checksum_empty_so_install_refuses() {
        let list = json!([{"tag_name": "windows-v0.4.0", "assets": [{"name": ZIP, "browser_download_url": "https://x/z"}]}]);
        assert_eq!(newest(&list).unwrap().sha256, "");
        let rt = crate::cli::rt();
        assert!(install(&newest(&list).unwrap(), &rt).is_err());
    }
}
