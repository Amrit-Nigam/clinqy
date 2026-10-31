//! The background browser: a separate headless Chrome (or Edge, or Brave) with its own profile, driven directly over
//! the DevTools protocol. It never touches the user's browser, windows, mouse, keyboard or clipboard, and if it's
//! unavailable a task fails rather than falling back to them. Pages are read and acted on with the same extension
//! helpers (`extension/page.js`), injected into an isolated world of each frame, so it answers the commands the
//! extension does and the agent can't tell them apart.

use crate::background::{route, Route};
use crate::page::Page;
use anyhow::{anyhow, bail, Result};
use futures_util::{SinkExt, StreamExt};
use parking_lot::Mutex;
use serde_json::{json, Value};
use std::collections::{BTreeMap, HashMap};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, OnceLock};
use std::time::Duration;
use tokio::sync::{mpsc, oneshot};
use tokio_tungstenite::tungstenite::Message;

/// The connection id of pages in the background browser.
pub const CONNECTION: u64 = u64::MAX;
/// What stands for the background browser where an app's executable goes.
pub const EXE: &str = "clinqy-worker";
pub const VIEWPORT: (f64, f64) = (1440.0, 900.0);
const PAGE_SCRIPT: &str = include_str!("../../../../extension/page.js");
/// An idle worker is quit after this long; its profile (and sign-ins) stay on disk for the next run.
const IDLE_LIFETIME: Duration = Duration::from_secs(600);

fn gone() -> anyhow::Error {
    anyhow!("The background browser's tab is gone. Your own browser wasn't used.")
}

/// One DevTools connection (the browser's, or a tab's).
struct Cdp {
    tx: mpsc::UnboundedSender<Message>,
    pending: Arc<Mutex<HashMap<u64, oneshot::Sender<Result<Value>>>>>,
    next: AtomicU64,
    chooser: Arc<Mutex<Option<Value>>>,
    /// Bumped when a page's scripting contexts go away, so injected helpers are made again.
    revision: Arc<AtomicU64>,
    connected: Arc<AtomicBool>,
}

impl Cdp {
    async fn connect(url: &str) -> Result<Arc<Cdp>> {
        let (socket, _) = tokio_tungstenite::connect_async(url).await.map_err(|e| anyhow!("couldn't reach the background browser: {e}"))?;
        let (mut write, mut read) = socket.split();
        let (tx, mut rx) = mpsc::unbounded_channel::<Message>();
        let cdp = Arc::new(Cdp {
            tx,
            pending: Arc::new(Mutex::new(HashMap::new())),
            next: AtomicU64::new(0),
            chooser: Arc::new(Mutex::new(None)),
            revision: Arc::new(AtomicU64::new(0)),
            connected: Arc::new(AtomicBool::new(true)),
        });
        tokio::spawn(async move {
            while let Some(m) = rx.recv().await {
                if write.send(m).await.is_err() {
                    break;
                }
            }
        });
        let (pending, chooser, revision, connected) = (cdp.pending.clone(), cdp.chooser.clone(), cdp.revision.clone(), cdp.connected.clone());
        tokio::spawn(async move {
            while let Some(Ok(message)) = read.next().await {
                let text = match message {
                    Message::Text(t) => t,
                    Message::Binary(b) => String::from_utf8_lossy(&b).into_owned(),
                    Message::Close(_) => break,
                    _ => continue,
                };
                let Ok(body) = serde_json::from_str::<Value>(&text) else { continue };
                if let Some(id) = body["id"].as_u64() {
                    if let Some(waiter) = pending.lock().remove(&id) {
                        let reply = match body["error"]["message"].as_str() {
                            Some(e) => Err(anyhow!("{e}")),
                            None => Ok(body["result"].clone()),
                        };
                        let _ = waiter.send(reply);
                    }
                } else if let Some(method) = body["method"].as_str() {
                    if method == "Page.fileChooserOpened" {
                        *chooser.lock() = Some(body["params"].clone());
                    }
                    if ["Runtime.executionContextsCleared", "Runtime.executionContextDestroyed", "Page.frameNavigated"].contains(&method) {
                        revision.fetch_add(1, Ordering::Relaxed);
                    }
                }
            }
            connected.store(false, Ordering::Relaxed);
            for (_, waiter) in pending.lock().drain() {
                let _ = waiter.send(Err(anyhow!("The background browser disconnected. No other browser will be used.")));
            }
        });
        Ok(cdp)
    }

    async fn call(&self, method: &str, params: Value) -> Result<Value> {
        self.call_for(method, params, 12.0).await
    }

    async fn call_for(&self, method: &str, params: Value, timeout: f64) -> Result<Value> {
        let t0 = std::time::Instant::now();
        let r = self.call_inner(method, params, timeout).await;
        if t0.elapsed() > Duration::from_millis(800) {
            crate::log::write(&format!("    background browser: {method} took {} ms{}", t0.elapsed().as_millis(), if r.is_err() { " and failed" } else { "" }));
        }
        r
    }

    async fn call_inner(&self, method: &str, params: Value, timeout: f64) -> Result<Value> {
        if !self.connected.load(Ordering::Relaxed) {
            bail!("The background browser disconnected. No other browser will be used.");
        }
        let id = self.next.fetch_add(1, Ordering::Relaxed) + 1;
        let (tx, rx) = oneshot::channel();
        self.pending.lock().insert(id, tx);
        let _ = self.tx.send(Message::Text(json!({"id": id, "method": method, "params": params}).to_string()));
        match tokio::time::timeout(Duration::from_secs_f64(timeout), rx).await {
            Ok(Ok(reply)) => reply,
            Ok(Err(_)) => bail!("The background browser disconnected. No other browser will be used."),
            Err(_) => {
                self.pending.lock().remove(&id);
                bail!("The background browser didn't answer {method} in time")
            }
        }
    }

    fn close(&self) {
        self.connected.store(false, Ordering::Relaxed);
        let _ = self.tx.send(Message::Close(None));
    }
}

struct Element {
    frame: String,
    local: i64,
    offset: (f64, f64),
}

#[derive(Default)]
struct TabState {
    elements: HashMap<i64, Element>,
    keys: HashMap<String, i64>,
    next_element: i64,
    page: String,
    frames: Vec<String>,
    focused_frame: Option<String>,
    incomplete: bool,
    uploads: Vec<PathBuf>,
    helpers: HashMap<String, i64>,
    revision: u64,
}

struct Tab {
    target: String,
    cdp: Arc<Cdp>,
    /// Commands on one tab run one at a time.
    state: tokio::sync::Mutex<TabState>,
    /// Its page is frozen (no scripts, timers or animations) because no run is using it.
    frozen: AtomicBool,
    /// The last picture of a finished run's page, kept so showing it never wakes the page.
    last_image: Mutex<Option<String>>,
}

#[derive(Default)]
struct State {
    child: Option<Child>,
    browser: Option<Arc<Cdp>>,
    port: u16,
    login: bool,
    run_active: bool,
    generation: u64,
    next_tab: i64,
    tabs: BTreeMap<i64, Arc<Tab>>,
    selected: Option<i64>,
    idle: Option<tokio::task::JoinHandle<()>>,
    /// This run works in a tab of the user's own browser, through the extension on this connection.
    own: Option<u64>,
    /// The tab, document and snapshot of the last look there: the extension refuses an action without them.
    own_look: Option<(i64, String, String)>,
    /// The last run's tabs are still in the Clinqy tab group, to go when the next run opens one.
    retire: bool,
    /// The picture of the tab when the run ended: a finished run doesn't touch the user's browser again.
    own_last: Option<String>,
}

pub struct Worker {
    home: PathBuf,
    /// Starting and stopping happen one at a time.
    gate: tokio::sync::Mutex<()>,
    st: Mutex<State>,
}

pub fn worker() -> &'static Worker {
    static W: OnceLock<Worker> = OnceLock::new();
    W.get_or_init(|| Worker::new(crate::paths::local_dir().join("BackgroundBrowser")))
}

/// The folders browsers keep their everyday profiles in. Chrome refuses automation there, and only one browser can
/// use a profile at a time, so the worker never does.
fn everyday_profiles() -> Vec<PathBuf> {
    let Some(local) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from) else { return vec![] };
    [r"Google\Chrome\User Data", r"Google\Chrome Beta\User Data", r"Microsoft\Edge\User Data", r"BraveSoftware\Brave-Browser\User Data"].iter().map(|t| local.join(t)).collect()
}

/// Why `folder` can't be the background browser's profile, if it can't.
pub fn profile_problem(folder: &str) -> Option<String> {
    let path = Path::new(folder);
    if !path.is_absolute() {
        return Some("Use a full folder path, such as D:\\Clinqy\\Browser.".into());
    }
    let lower = |p: &Path| p.display().to_string().trim_end_matches('\\').to_lowercase();
    let wanted = lower(path);
    let everyday = everyday_profiles().iter().any(|e| wanted == lower(e) || wanted.starts_with(&format!("{}\\", lower(e))));
    everyday.then(|| "That's your everyday browser profile. Browsers don't allow automation there, so choose another folder and use Sign in… to sign in to your sites.".into())
}

/// Background tasks work in a tab of the user's own browser rather than the hidden one (BACKGROUND_BROWSER=chrome).
pub fn in_own_browser() -> bool {
    crate::config::value("BACKGROUND_BROWSER").as_deref() == Some("chrome")
}

/// The browser the worker runs: the same kind the user has, Chrome first. WORKER_BROWSER overrides it.
pub fn find_browser() -> Option<PathBuf> {
    if let Some(p) = crate::config::value("WORKER_BROWSER").map(PathBuf::from).filter(|p| p.is_file()) {
        return Some(p);
    }
    let roots: Vec<PathBuf> = ["ProgramFiles", "ProgramFiles(x86)", "LOCALAPPDATA"].iter().filter_map(|v| std::env::var_os(v).map(PathBuf::from)).collect();
    let tails = [r"Google\Chrome\Application\chrome.exe", r"Microsoft\Edge\Application\msedge.exe", r"BraveSoftware\Brave-Browser\Application\brave.exe"];
    tails.iter().flat_map(|t| roots.iter().map(move |r| r.join(t))).find(|p| p.is_file())
}

pub fn browser_name(path: &Path) -> &'static str {
    match path.file_stem().map(|s| s.to_string_lossy().to_lowercase()).as_deref() {
        Some("msedge") => "Microsoft Edge",
        Some("brave") => "Brave",
        _ => "Google Chrome",
    }
}

fn loopback(url: &str) -> bool {
    url::Url::parse(url).ok().and_then(|u| u.host_str().map(|h| h == "127.0.0.1" || h == "localhost")).unwrap_or(false)
}

fn http() -> reqwest::Client {
    reqwest::Client::builder().no_proxy().timeout(Duration::from_secs(3)).build().unwrap_or_default()
}

impl Worker {
    /// WORKER_PROFILE, else Clinqy's own folder.
    fn root(&self) -> PathBuf {
        crate::config::value("WORKER_PROFILE").filter(|f| !f.is_empty()).map(PathBuf::from).unwrap_or_else(|| self.home.clone())
    }

    pub fn profile(&self) -> PathBuf {
        self.root()
    }

    fn new(root: PathBuf) -> Worker {
        Worker { home: root, gate: tokio::sync::Mutex::new(()), st: Mutex::new(State { next_tab: 1_000_000, ..Default::default() }) }
    }

    pub fn connected(&self) -> bool {
        self.st.lock().browser.as_ref().map(|b| b.connected.load(Ordering::Relaxed)).unwrap_or(false)
    }

    pub fn in_login(&self) -> bool {
        self.st.lock().login
    }

    pub fn pid(&self) -> u32 {
        self.st.lock().child.as_ref().map(|c| c.id()).unwrap_or(0)
    }

    pub fn selected(&self) -> Option<i64> {
        self.st.lock().selected
    }

    pub fn has_tab(&self) -> bool {
        let s = self.st.lock();
        if s.own.is_some() {
            return s.selected.is_some();
        }
        s.selected.map(|t| s.tabs.contains_key(&t)).unwrap_or(false)
    }

    async fn start(&self) -> Result<()> {
        let _gate = self.gate.lock().await;
        if self.st.lock().login {
            bail!("Finish signing in to the background browser (Clinqy → Background) before starting background web tasks.");
        }
        if let Some(idle) = self.st.lock().idle.take() {
            idle.abort();
        }
        if self.connected() {
            return Ok(());
        }
        self.launch(true).await
    }

    async fn launch(&self, headless: bool) -> Result<()> {
        let exe = find_browser().ok_or_else(|| anyhow!("Install Google Chrome or Microsoft Edge to use background web tasks."))?;
        if let Some(problem) = profile_problem(&self.root().display().to_string()) {
            bail!("{problem}");
        }
        std::fs::create_dir_all(&self.root())?;
        let port_file = self.root().join("DevToolsActivePort");
        // Never attach to an old browser, or a normal session, merely because its endpoint file exists.
        self.drop_child();
        self.close_orphan(&exe, !headless).await?;
        self.close_strays(&exe).await;
        let _ = std::fs::remove_dir_all(self.root().join("Uploads"));
        let _ = std::fs::remove_file(&port_file);
        let mut args = vec![
            format!("--user-data-dir={}", self.root().display()),
            "--remote-debugging-address=127.0.0.1".to_string(),
            "--remote-debugging-port=0".to_string(),
            "--no-first-run".to_string(),
            "--no-default-browser-check".to_string(),
            "--disable-background-mode".to_string(),
            "--window-size=1440,900".to_string(),
        ];
        args.push(if headless { "--headless=new".to_string() } else { "about:blank".to_string() });
        let mut command = Command::new(&exe);
        command.args(&args).stdin(Stdio::null()).stdout(Stdio::null()).stderr(Stdio::null());
        if headless {
            use std::os::windows::process::CommandExt;
            command.creation_flags(crate::session::CREATE_NO_WINDOW);
        }
        let child = command.spawn().map_err(|e| anyhow!("couldn't start {}: {e}", browser_name(&exe)))?;
        let pid = child.id();
        self.st.lock().child = Some(child);
        for _ in 0..150 {
            let exited = self.st.lock().child.as_mut().map(|c| c.try_wait().ok().flatten().is_some()).unwrap_or(true);
            if exited {
                bail!("The background browser exited before it was ready. Your own browser wasn't used.");
            }
            if let Some(port) = std::fs::read_to_string(&port_file).ok().and_then(|t| t.lines().next().and_then(|l| l.trim().parse::<u16>().ok())) {
                let version = http().get(format!("http://127.0.0.1:{port}/json/version")).send().await;
                if let Ok(version) = version {
                    let body: Value = version.json().await.unwrap_or_default();
                    if let Some(socket) = body["webSocketDebuggerUrl"].as_str().filter(|s| loopback(s)) {
                        let browser = Cdp::connect(socket).await?;
                        browser.call("Browser.getVersion", json!({})).await?;
                        std::fs::write(self.root().join("owner.json"), json!({"pid": pid, "socket": socket, "headless": headless}).to_string())?;
                        let downloads = self.root().join("Downloads");
                        std::fs::create_dir_all(&downloads)?;
                        let _ = browser.call("Browser.setDownloadBehavior", json!({"behavior": "allow", "downloadPath": downloads.display().to_string()})).await;
                        let mut s = self.st.lock();
                        s.browser = Some(browser);
                        s.port = port;
                        drop(s);
                        crate::log::write(&format!("background browser: {} started (pid {pid}{})", browser_name(&exe), if headless { "" } else { ", visible for sign-in" }));
                        return Ok(());
                    }
                }
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        self.drop_child();
        bail!("The background browser didn't become ready. Your own browser wasn't used.")
    }

    fn drop_child(&self) {
        if let Some(mut child) = self.st.lock().child.take() {
            if child.try_wait().ok().flatten().is_none() {
                let _ = child.kill();
            }
            let _ = child.wait();
        }
    }

    /// A browser left on this profile holds it, and a new one then exits at once. The record of it can be gone (the app
    /// was killed), so this looks for the process itself. Only one with this exact profile and a debugging port can
    /// match, which the user's own browser never has.
    async fn close_strays(&self, exe: &Path) {
        use std::os::windows::process::CommandExt;
        let script = "Get-CimInstance Win32_Process -Filter \"Name='$env:CLINQY_NAME'\" |                       Where-Object { $_.CommandLine -and $_.CommandLine.Contains('--user-data-dir=' + $env:CLINQY_PROFILE) -and $_.CommandLine.Contains('--remote-debugging-port') -and -not $_.CommandLine.Contains('--type=') } |                       ForEach-Object { Stop-Process -Id $_.ProcessId -Force }";
        let name = exe.file_name().map(|n| n.to_string_lossy().to_string()).unwrap_or_default();
        let profile = self.root();
        let _ = tokio::task::spawn_blocking(move || {
            Command::new("powershell").args(["-NoProfile", "-NonInteractive", "-Command", script]).env("CLINQY_NAME", name).env("CLINQY_PROFILE", profile).creation_flags(crate::session::CREATE_NO_WINDOW).output()
        })
        .await;
    }

    /// After a crash: closes a browser only if its executable, profile and debugging flag all match what we recorded.
    /// Old tabs are discarded; nothing from an interrupted run is executed.
    async fn close_orphan(&self, exe: &Path, allow_headed: bool) -> Result<()> {
        let file = self.root().join("owner.json");
        let Some(owner) = std::fs::read_to_string(&file).ok().and_then(|t| serde_json::from_str::<Value>(&t).ok()) else { return Ok(()) };
        let (Some(pid), Some(socket)) = (owner["pid"].as_u64(), owner["socket"].as_str().filter(|s| loopback(s))) else {
            let _ = std::fs::remove_file(&file);
            return Ok(());
        };
        let line = command_line(pid).await.unwrap_or_default().to_lowercase();
        let ours = line.contains(&exe.display().to_string().to_lowercase()) && line.contains(&format!("--user-data-dir={}", self.root().display()).to_lowercase()) && line.contains("--remote-debugging-port=0");
        if !ours {
            let _ = std::fs::remove_file(&file);
            return Ok(());
        }
        if !allow_headed && owner["headless"] != true {
            bail!("Signing in to the background browser was interrupted. Open it from Clinqy → Background, then finish signing in.");
        }
        if let Ok(orphan) = Cdp::connect(socket).await {
            let _ = orphan.call_for("Browser.close", json!({}), 3.0).await;
            orphan.close();
        }
        for _ in 0..30 {
            if command_line(pid).await.map(|l| l.is_empty()).unwrap_or(true) {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        let _ = std::fs::remove_file(&file);
        Ok(())
    }

    /// Opens the background browser visibly, for the user to sign in to sites. Its profile keeps those logins.
    pub async fn open_login(&self) -> Result<()> {
        if self.st.lock().run_active {
            bail!("Wait for the background task to finish first.");
        }
        self.stop().await;
        let _gate = self.gate.lock().await;
        self.st.lock().login = true;
        if let Err(e) = self.launch(false).await {
            self.st.lock().login = false;
            return Err(e);
        }
        Ok(())
    }

    pub async fn finish_login(&self) {
        self.stop().await;
        self.st.lock().login = false;
    }

    /// A background run starts on no page, so it never sees the last task's; a follow-up keeps its place.
    pub fn run_started(&self, keep_page: bool) {
        let mut s = self.st.lock();
        s.generation += 1;
        s.run_active = true;
        s.own = if in_own_browser() { crate::bridge::bridge().own_browser() } else { None };
        if in_own_browser() && s.own.is_none() {
            crate::log::write("    background: the browser extension isn't connected, so this run uses the hidden browser");
        }
        if !keep_page {
            s.selected = None;
            s.retire = s.own.is_some();
        }
        s.own_last = None;
        if let Some(idle) = s.idle.take() {
            idle.abort();
        }
    }

    /// A run finished: every tab closes but the one its result shows, which is pictured and frozen so it stops using
    /// CPU, and the browser quits if nothing needs it for a while.
    pub async fn run_ended(&'static self) {
        if let Some(conn) = self.own() {
            let shot = self.picture(None, 80).await;
            {
                let mut s = self.st.lock();
                s.run_active = false;
                s.own_last = shot;
            }
            let _ = crate::bridge::bridge().ask(conn, "clinqyDone", json!({}), 5.0).await;
            return;
        }
        let (generation, keep, others, browser) = {
            let mut s = self.st.lock();
            s.run_active = false;
            let keep = s.selected;
            let others: Vec<(i64, Arc<Tab>)> = s.tabs.iter().filter(|(id, _)| Some(**id) != keep).map(|(id, t)| (*id, t.clone())).collect();
            for (id, _) in &others {
                s.tabs.remove(id);
            }
            (s.generation, keep, others, s.browser.clone())
        };
        for (_, tab) in others {
            if let Some(b) = &browser {
                let _ = b.call_for("Target.closeTarget", json!({"targetId": tab.target}), 3.0).await;
            }
            tab.cdp.close();
            for dir in tab.state.lock().await.uploads.drain(..) {
                let _ = std::fs::remove_dir_all(dir);
            }
        }
        if let Some(tab) = keep.and_then(|id| self.st.lock().tabs.get(&id).cloned()) {
            let shot = tab.cdp.call("Page.captureScreenshot", json!({"format": "jpeg", "quality": 80, "captureBeyondViewport": false})).await;
            let still_idle = { let s = self.st.lock(); s.generation == generation && !s.run_active };
            if still_idle {
                *tab.last_image.lock() = shot.ok().and_then(|r| r["data"].as_str().map(String::from));
                tab.frozen.store(true, Ordering::Relaxed);
                if tab.cdp.call_for("Page.setWebLifecycleState", json!({"state": "frozen"}), 3.0).await.is_err() {
                    tab.frozen.store(false, Ordering::Relaxed);
                }
            }
        }
        self.schedule_idle_stop();
    }

    fn schedule_idle_stop(&'static self) {
        let task = tokio::spawn(async move {
            tokio::time::sleep(IDLE_LIFETIME).await;
            let idle = { let s = self.st.lock(); !s.run_active && !s.login };
            if idle {
                self.stop().await;
            }
        });
        if let Some(old) = self.st.lock().idle.replace(task) {
            old.abort();
        }
    }

    /// Closes the browser. Its profile stays.
    pub async fn stop(&self) {
        let _gate = self.gate.lock().await;
        let (browser, tabs) = {
            let mut s = self.st.lock();
            if let Some(idle) = s.idle.take() {
                idle.abort();
            }
            s.selected = None;
            (s.browser.take(), std::mem::take(&mut s.tabs))
        };
        if let Some(b) = &browser {
            let _ = b.call_for("Browser.close", json!({}), 3.0).await;
            b.close();
        }
        for tab in tabs.values() {
            tab.cdp.close();
        }
        for _ in 0..30 {
            let exited = self.st.lock().child.as_mut().map(|c| c.try_wait().ok().flatten().is_some()).unwrap_or(true);
            if exited {
                break;
            }
            tokio::time::sleep(Duration::from_millis(100)).await;
        }
        self.drop_child();
        let _ = std::fs::remove_file(self.root().join("owner.json"));
    }

    /// On quitting the app: no browser is left behind.
    pub fn shutdown(&self) {
        self.drop_child();
        let _ = std::fs::remove_file(self.root().join("owner.json"));
    }

    /// The extension reconnects whenever Chrome restarts its worker, so the current connection, not the first one.
    fn own(&self) -> Option<u64> {
        let conn = self.st.lock().own?;
        crate::bridge::bridge().own_browser().or(Some(conn))
    }

    /// A tab for the run in the user's own browser: in the Clinqy tab group, never brought to the front.
    async fn own_tab(&self, conn: u64, url: &str) -> Result<i64> {
        let bridge = crate::bridge::bridge();
        if std::mem::take(&mut self.st.lock().retire) {
            let _ = bridge.ask(conn, "clinqyClear", json!({}), 5.0).await;
        }
        let made = bridge.ask(conn, "clinqyTab", json!({"url": url, "width": VIEWPORT.0, "height": VIEWPORT.1}), 15.0).await?;
        let id = made["id"].as_i64().ok_or_else(|| anyhow!("Your browser didn't open a tab for Clinqy"))?;
        self.st.lock().selected = Some(id);
        Ok(id)
    }

    /// `command` for a run in the user's own browser. The extension answers the same commands.
    async fn own_command(&self, conn: u64, command: &str, id: Option<i64>, args: Value) -> Result<Value> {
        let bridge = crate::bridge::bridge();
        let selected = self.selected();
        match command {
            "newTab" => Ok(json!({"id": self.own_tab(conn, args["url"].as_str().unwrap_or("about:blank")).await?})),
            "switchTab" => {
                self.st.lock().selected = id;
                Ok(json!({"id": id}))
            }
            "tabs" => {
                let Some(tab) = selected else { return Ok(json!({"tabs": []})) };
                let info = bridge.ask(conn, "tabInfo", json!({"tabId": tab}), 5.0).await?;
                Ok(json!({"tabs": [{"id": tab, "url": info["url"], "title": info["title"], "opened": true, "active": true}]}))
            }
            _ => {
                let tab = id.or(selected).ok_or_else(gone)?;
                let mut args = args;
                args["tabId"] = json!(tab);
                let look = self.st.lock().own_look.clone();
                if let Some((_, document, snapshot)) = look.filter(|l| l.0 == tab) {
                    args["documentID"] = json!(document);
                    args["snapshotID"] = json!(snapshot);
                }
                let result = bridge.ask(conn, command, args, 30.0).await?;
                if command == "snapshot" {
                    let tokens = result["documentID"].as_str().zip(result["snapshotID"].as_str());
                    self.st.lock().own_look = tokens.map(|(document, snapshot)| (tab, document.to_string(), snapshot.to_string()));
                }
                Ok(result)
            }
        }
    }

    /// A run in the user's browser when it isn't open: opens it minimized and waits for the extension. If that doesn't
    /// work, the run carries on in the hidden browser.
    async fn open_own_browser(&self) {
        let run_active = self.st.lock().run_active;
        if !run_active || !in_own_browser() || self.own().is_some() {
            return;
        }
        let Some(exe) = find_browser() else { return };
        crate::log::write("    background: opening your browser for the Clinqy tab");
        let _ = Command::new(exe).arg("--start-minimized").stdin(std::process::Stdio::null()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).spawn();
        for _ in 0..30 {
            tokio::time::sleep(Duration::from_millis(500)).await;
            if let Some(conn) = crate::bridge::bridge().own_browser() {
                let mut s = self.st.lock();
                s.own = Some(conn);
                s.retire = true;
                return;
            }
        }
        crate::log::write("    background: the browser extension didn't connect, so this run uses the hidden browser");
    }

    pub async fn new_tab(&self, url: &str) -> Result<i64> {
        self.open_own_browser().await;
        if let Some(conn) = self.own() {
            return self.own_tab(conn, url).await;
        }
        self.start().await?;
        let (browser, port) = {
            let s = self.st.lock();
            (s.browser.clone().ok_or_else(gone)?, s.port)
        };
        let made = browser.call("Target.createTarget", json!({"url": url, "background": true})).await?;
        let target = made["targetId"].as_str().ok_or_else(|| anyhow!("The background browser didn't make a tab"))?.to_string();
        let list: Value = http().get(format!("http://127.0.0.1:{port}/json/list")).send().await?.json().await?;
        let socket = list
            .as_array()
            .and_then(|a| a.iter().find(|t| t["id"] == target.as_str()))
            .and_then(|t| t["webSocketDebuggerUrl"].as_str())
            .filter(|s| loopback(s))
            .ok_or_else(|| anyhow!("The background browser's tab isn't reachable"))?
            .to_string();
        let cdp = Cdp::connect(&socket).await?;
        cdp.call("Page.enable", json!({})).await?;
        cdp.call("Runtime.enable", json!({})).await?;
        cdp.call("Page.setInterceptFileChooserDialog", json!({"enabled": true})).await?;
        cdp.call("Emulation.setDeviceMetricsOverride", json!({"width": VIEWPORT.0, "height": VIEWPORT.1, "deviceScaleFactor": 1, "mobile": false})).await?;
        let tab = Arc::new(Tab { target, cdp, state: tokio::sync::Mutex::new(TabState::default()), frozen: AtomicBool::new(false), last_image: Mutex::new(None) });
        let mut s = self.st.lock();
        s.next_tab += 1;
        let id = s.next_tab;
        s.tabs.insert(id, tab);
        s.selected = Some(id);
        Ok(id)
    }

    fn tab(&self, id: Option<i64>) -> Result<(i64, Arc<Tab>)> {
        let s = self.st.lock();
        let id = id.or(s.selected).ok_or_else(gone)?;
        let tab = s.tabs.get(&id).cloned().ok_or_else(gone)?;
        if !tab.cdp.connected.load(Ordering::Relaxed) {
            return Err(gone());
        }
        Ok((id, tab))
    }

    /// The page in the run's current tab.
    pub async fn snapshot(&self, id: Option<i64>) -> Option<Page> {
        let raw = self.command("snapshot", id, json!({})).await.ok()?;
        let mut page = Page::parse(&raw, CONNECTION);
        page.pinned = true;
        if self.own().is_some() {
            page.tab_id = id.or(self.selected());
        }
        page.estimated_area = Some(crate::platform::Rect::new(0.0, 0.0, page.viewport.0, page.viewport.1));
        Some(page)
    }

    /// A JPEG of the tab for the model or the live view. Between runs it's the picture kept at the end of the run.
    pub async fn picture(&self, id: Option<i64>, quality: u32) -> Option<String> {
        if let Some(conn) = self.own() {
            let (running, last) = { let s = self.st.lock(); (s.run_active, s.own_last.clone()) };
            if !running {
                return last;
            }
            let args = json!({"tabId": id.or(self.selected())?, "format": "jpeg", "quality": quality});
            let shot = crate::bridge::bridge().ask(conn, "captureTask", args, 10.0).await.ok()?;
            return shot["image"].as_str().map(String::from);
        }
        let (_, tab) = self.tab(id).ok()?;
        if tab.frozen.load(Ordering::Relaxed) {
            return tab.last_image.lock().clone();
        }
        let shot = tab.cdp.call("Page.captureScreenshot", json!({"format": "jpeg", "quality": quality, "optimizeForSpeed": true, "captureBeyondViewport": false})).await.ok()?;
        shot["data"].as_str().map(String::from)
    }

    /// A lossless picture of the tab, for a saved screenshot.
    pub async fn png(&self, id: Option<i64>) -> Option<Vec<u8>> {
        use base64::Engine;
        if let Some(conn) = self.own() {
            let shot = crate::bridge::bridge().ask(conn, "captureTask", json!({"tabId": id.or(self.selected())?}), 10.0).await.ok()?;
            return base64::engine::general_purpose::STANDARD.decode(shot["image"].as_str()?).ok();
        }
        let (_, tab) = self.tab(id).ok()?;
        let shot = tab.cdp.call("Page.captureScreenshot", json!({"format": "png", "captureBeyondViewport": false})).await.ok()?;
        base64::engine::general_purpose::STANDARD.decode(shot["data"].as_str()?).ok()
    }

    /// The same commands the extension answers, on one of the worker's own tabs.
    pub async fn command(&self, command: &str, id: Option<i64>, args: Value) -> Result<Value> {
        if let Some(conn) = self.own() {
            return self.own_command(conn, command, id, args).await;
        }
        match command {
            "newTab" => return Ok(json!({"id": self.new_tab(args["url"].as_str().unwrap_or("about:blank")).await?})),
            "tabs" => {
                let ids: Vec<i64> = self.st.lock().tabs.keys().copied().collect();
                let selected = self.selected();
                let mut tabs = vec![];
                for t in ids {
                    if let Ok(info) = Box::pin(self.command("tabInfo", Some(t), json!({}))).await {
                        tabs.push(json!({"id": t, "url": info["url"], "title": info["title"], "opened": true, "active": Some(t) == selected}));
                    }
                }
                return Ok(json!({"tabs": tabs}));
            }
            _ => {}
        }
        let (id, tab) = self.tab(id)?;
        if tab.frozen.swap(false, Ordering::Relaxed) {
            *tab.last_image.lock() = None;
            tab.cdp.call_for("Page.setWebLifecycleState", json!({"state": "active"}), 3.0).await?;
        }
        if let Some(idle) = self.st.lock().idle.take() {
            idle.abort();
        }
        let mut st = tab.state.lock().await;
        let cdp = &tab.cdp;
        match command {
            // A logical selection only: no window is ever brought forward.
            "switchTab" => {
                self.st.lock().selected = Some(id);
                Ok(json!({"id": id}))
            }
            "closeTab" => {
                let browser = self.st.lock().browser.clone();
                if let Some(b) = browser {
                    b.call("Target.closeTarget", json!({"targetId": tab.target})).await?;
                }
                cdp.close();
                for dir in st.uploads.drain(..) {
                    let _ = std::fs::remove_dir_all(dir);
                }
                let mut s = self.st.lock();
                s.tabs.remove(&id);
                if s.selected == Some(id) {
                    s.selected = s.tabs.keys().next_back().copied();
                }
                Ok(json!({"closed": id}))
            }
            "tabInfo" => {
                let info = evaluate(cdp, "({url:location.href,title:document.title})", None).await?;
                Ok(json!({"id": id, "url": info["url"], "title": info["title"], "focused": true}))
            }
            "navigate" => {
                cdp.call("Page.navigate", json!({"url": args["url"].as_str().unwrap_or("about:blank")})).await?;
                Ok(json!({"ok": true}))
            }
            "goBack" => {
                let history = cdp.call("Page.getNavigationHistory", json!({})).await?;
                let index = history["currentIndex"].as_i64().unwrap_or(0);
                if index > 0 {
                    if let Some(entry) = history["entries"][(index - 1) as usize]["id"].as_i64() {
                        cdp.call("Page.navigateToHistoryEntry", json!({"entryId": entry})).await?;
                    }
                }
                Ok(json!({"ok": true}))
            }
            "snapshot" => snapshot(cdp, &mut st, id).await,
            "cdpType" => {
                cdp.call("Input.insertText", json!({"text": args["text"].as_str().unwrap_or("")})).await?;
                Ok(json!({"typed": true}))
            }
            "cdpClick" => {
                let (x, y) = (args["x"].as_f64().unwrap_or(0.0), args["y"].as_f64().unwrap_or(0.0));
                for count in 1..=args["count"].as_i64().unwrap_or(1).max(1) {
                    cdp.call("Input.dispatchMouseEvent", json!({"type": "mousePressed", "button": "left", "buttons": 1, "x": x, "y": y, "clickCount": count})).await?;
                    cdp.call("Input.dispatchMouseEvent", json!({"type": "mouseReleased", "button": "left", "buttons": 0, "x": x, "y": y, "clickCount": count})).await?;
                }
                Ok(json!({"clicked": true}))
            }
            "cdpScroll" => {
                cdp.call("Input.dispatchMouseEvent", json!({"type": "mouseWheel", "x": args["x"].as_f64().unwrap_or(200.0), "y": args["y"].as_f64().unwrap_or(200.0), "deltaX": 0, "deltaY": args["dy"].as_f64().unwrap_or(0.0)})).await?;
                Ok(json!({"scrolled": true}))
            }
            "cdpKey" => key(cdp, args["keys"].as_str().unwrap_or("")).await,
            _ => page_command(self, cdp, &mut st, command, &args).await,
        }
    }
}

/// A process's command line, by asking Windows (only after a crash left an `owner.json` behind).
async fn command_line(pid: u64) -> Option<String> {
    use std::os::windows::process::CommandExt;
    let script = format!("(Get-CimInstance Win32_Process -Filter 'ProcessId={pid}').CommandLine");
    let out = tokio::task::spawn_blocking(move || {
        Command::new("powershell").args(["-NoProfile", "-NonInteractive", "-Command", &script]).creation_flags(crate::session::CREATE_NO_WINDOW).output()
    })
    .await
    .ok()?
    .ok()?;
    Some(String::from_utf8_lossy(&out.stdout).trim().to_string())
}

async fn evaluate(cdp: &Cdp, expression: &str, context: Option<i64>) -> Result<Value> {
    let mut args = json!({"expression": expression, "returnByValue": true, "awaitPromise": true, "userGesture": true});
    if let Some(c) = context {
        args["contextId"] = json!(c);
    }
    let result = cdp.call_for("Runtime.evaluate", args, 20.0).await?;
    if !result["exceptionDetails"].is_null() {
        bail!("The page operation failed. Take a fresh look before retrying.");
    }
    Ok(result["result"]["value"].clone())
}

/// Calls one of the page helpers in a frame, injecting them into an isolated world the first time.
async fn call(cdp: &Cdp, st: &mut TabState, frame: &str, function: &str, args: Value) -> Result<Value> {
    let revision = cdp.revision.load(Ordering::Relaxed);
    if st.revision != revision {
        st.helpers.clear();
        st.revision = revision;
    }
    let expression = format!("window.__clinqy[{}](...{})", json!(function), args);
    if let Some(context) = st.helpers.get(frame).copied() {
        match evaluate(cdp, &expression, Some(context)).await {
            Ok(v) => return Ok(v),
            // The page navigated before the browser said so: the helper never ran, so a fresh one can.
            Err(e) if e.to_string().contains("Cannot find context") => {
                st.helpers.remove(frame);
            }
            Err(e) => return Err(e),
        }
    }
    let world = cdp.call("Page.createIsolatedWorld", json!({"frameId": frame, "worldName": "ClinqyWorker"})).await?;
    let context = world["executionContextId"].as_i64().ok_or_else(|| anyhow!("An embedded frame isn't available to the background browser"))?;
    evaluate(cdp, PAGE_SCRIPT, Some(context)).await?;
    st.helpers.insert(frame.to_string(), context);
    evaluate(cdp, &expression, Some(context)).await
}

fn frame_list(tree: &Value, out: &mut Vec<String>) {
    if let Some(id) = tree["frame"]["id"].as_str() {
        out.push(id.to_string());
    }
    for child in tree["childFrames"].as_array().into_iter().flatten() {
        frame_list(child, out);
    }
}

async fn frame_offset(cdp: &Cdp, st: &TabState, frame: &str) -> Result<(f64, f64)> {
    if st.frames.first().map(String::as_str) == Some(frame) {
        return Ok((0.0, 0.0));
    }
    let owner = cdp.call("DOM.getFrameOwner", json!({"frameId": frame})).await?;
    let model = cdp.call("DOM.getBoxModel", json!({"backendNodeId": owner["backendNodeId"]})).await?;
    let quad = model["model"]["content"].as_array().ok_or_else(|| anyhow!("Can't locate an embedded frame"))?;
    Ok((quad.first().and_then(Value::as_f64).unwrap_or(0.0), quad.get(1).and_then(Value::as_f64).unwrap_or(0.0)))
}

/// The page with its frames merged: stable element numbers across the tab, coordinates in the top page.
async fn snapshot(cdp: &Cdp, st: &mut TabState, id: i64) -> Result<Value> {
    let tree = cdp.call("Page.getFrameTree", json!({})).await?;
    let mut frames = vec![];
    frame_list(&tree["frameTree"], &mut frames);
    st.frames = frames;
    st.incomplete = false;
    let top = st.frames.first().cloned().ok_or_else(|| anyhow!("The page has no frame"))?;
    let mut result = call(cdp, st, &top, "snapshot", json!([])).await?;
    let url = result["url"].as_str().unwrap_or("").to_string();
    if st.page != url {
        st.page = url;
        st.keys.clear();
        st.next_element = 0;
    }
    st.elements.clear();
    let mut elements = vec![];
    for frame in st.frames.clone() {
        let part = if frame == top { Ok(result.clone()) } else { call(cdp, st, &frame, "snapshot", json!([])).await };
        let merged: Result<()> = async {
            let part = part?;
            let origin = frame_offset(cdp, st, &frame).await?;
            for element in part["elements"].as_array().into_iter().flatten() {
                let Some(local) = element["i"].as_i64() else { continue };
                let key = format!("{frame}:{}", element["key"].as_str().map(String::from).unwrap_or_else(|| format!("{}:{}:{local}", element["role"], element["text"])));
                let global = match st.keys.get(&key) {
                    Some(g) => *g,
                    None => {
                        let g = st.next_element;
                        st.next_element += 1;
                        st.keys.insert(key, g);
                        g
                    }
                };
                let mut element = element.clone();
                element["i"] = json!(global);
                element["x"] = json!(element["x"].as_f64().unwrap_or(0.0) + origin.0);
                element["y"] = json!(element["y"].as_f64().unwrap_or(0.0) + origin.1);
                elements.push(element);
                st.elements.insert(global, Element { frame: frame.clone(), local, offset: origin });
            }
            Ok(())
        }
        .await;
        if let Err(e) = merged {
            if frame == top {
                return Err(e);
            }
            st.incomplete = true;
        }
    }
    result["elements"] = json!(elements);
    result["tabId"] = json!(id);
    result["focused"] = json!(true);
    result["window"] = json!({"left": 0, "top": 0, "width": VIEWPORT.0, "height": VIEWPORT.1});
    if st.incomplete {
        result["error"] = json!("An embedded frame could not be read safely. Its form review or upload needs attention.");
    }
    Ok(result)
}

async fn page_command(worker: &Worker, cdp: &Cdp, st: &mut TabState, command: &str, args: &Value) -> Result<Value> {
    let top = st.frames.first().cloned().ok_or_else(|| anyhow!("Take a look at the page first"))?;
    let index = args["index"].as_i64().unwrap_or(-1);
    let element = st.elements.get(&index).map(|e| (e.frame.clone(), e.local, e.offset));
    let missing = || anyhow!("That element no longer exists. Take a fresh look.");
    match command {
        "click" | "focus" | "value" | "isActive" | "prepare" | "state" | "chosen" | "alive" | "focusFor" => {
            let (frame, local, _) = element.ok_or_else(missing)?;
            call(cdp, st, &frame, command, json!([local])).await
        }
        "activeOption" => {
            let (frame, local, _) = element.ok_or_else(missing)?;
            call(cdp, st, &frame, command, json!([local, args["want"].as_str().unwrap_or("")])).await
        }
        "fill" => {
            let (frame, local, _) = element.ok_or_else(missing)?;
            call(cdp, st, &frame, command, json!([local, args["text"].as_str().unwrap_or("")])).await
        }
        "locate" | "findOption" => {
            let mut result = if command == "locate" {
                let (frame, local, _) = element.clone().ok_or_else(missing)?;
                call(cdp, st, &frame, command, json!([local])).await?
            } else {
                let (frame, local) = element.as_ref().map(|e| (e.0.clone(), e.1)).unwrap_or((top, -1));
                call(cdp, st, &frame, command, json!([args["text"].as_str().unwrap_or(""), local])).await?
            };
            let (ox, oy) = element.map(|e| e.2).unwrap_or((0.0, 0.0));
            for k in ["x", "px"] {
                if let Some(v) = result[k].as_f64() {
                    result[k] = json!(v + ox);
                }
            }
            for k in ["y", "py"] {
                if let Some(v) = result[k].as_f64() {
                    result[k] = json!(v + oy);
                }
            }
            Ok(result)
        }
        "review" | "read" | "tables" => {
            if st.incomplete {
                bail!("An embedded frame is unreadable; I won't present an incomplete form review.");
            }
            let function = if command == "read" { "readText" } else { command };
            let mut result = call(cdp, st, &top, function, json!([])).await?;
            for frame in st.frames.clone().into_iter().skip(1) {
                let part = call(cdp, st, &frame, function, json!([])).await?;
                if command == "read" {
                    result["text"] = json!(format!("{}\n{}", result["text"].as_str().unwrap_or(""), part["text"].as_str().unwrap_or("")));
                } else {
                    let keys: &[&str] = if command == "review" { &["items", "messages", "missing"] } else { &["tables"] };
                    for key in keys {
                        let mut merged = result[*key].as_array().cloned().unwrap_or_default();
                        merged.extend(part[*key].as_array().cloned().unwrap_or_default());
                        result[*key] = json!(merged);
                    }
                }
            }
            Ok(result)
        }
        "upload" => {
            let params = |local: i64| json!([local, args["name"].as_str().unwrap_or("attachment"), args["type"].as_str().unwrap_or(""), args["data"].as_str().unwrap_or("")]);
            if let Some((frame, local, _)) = element {
                return call(cdp, st, &frame, "upload", params(local)).await;
            }
            for frame in st.frames.clone() {
                if let Ok(r) = call(cdp, st, &frame, "upload", params(-1)).await {
                    if r["ok"] == true {
                        return Ok(r);
                    }
                }
            }
            bail!("No direct file input found. Use the site's upload button.")
        }
        "uploadVia" => {
            use base64::Engine;
            let (frame, local, _) = element.ok_or_else(missing)?;
            let data = base64::engine::general_purpose::STANDARD.decode(args["data"].as_str().unwrap_or("")).map_err(|_| anyhow!("The upload file is missing"))?;
            call(cdp, st, &frame, "markUpload", json!([local])).await?;
            let directory = worker.root().join("Uploads").join(uuid::Uuid::new_v4().to_string());
            std::fs::create_dir_all(&directory)?;
            st.uploads.push(directory.clone()); // The browser may read the file only when the form is submitted.
            let name = Path::new(args["name"].as_str().unwrap_or("attachment")).file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| "attachment".into());
            let file = directory.join(&name);
            std::fs::write(&file, data)?;
            *cdp.chooser.lock() = None;
            call(cdp, st, &frame, "click", json!([local])).await?;
            for _ in 0..30 {
                let node = cdp.chooser.lock().as_ref().map(|c| c["backendNodeId"].clone()).filter(|n| !n.is_null());
                if let Some(node) = node {
                    cdp.call("DOM.setFileInputFiles", json!({"backendNodeId": node, "files": [file.display().to_string()]})).await?;
                    return Ok(json!({"ok": true, "files": [name]}));
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            bail!("The site's file chooser wasn't available to the background browser. No file picker was opened on your desktop.")
        }
        "activeValue" => {
            for frame in st.frames.clone() {
                let r = call(cdp, st, &frame, "activeValue", json!([])).await?;
                if r["editable"] == true && r["hasFocus"] == true {
                    st.focused_frame = Some(frame);
                    return Ok(r);
                }
            }
            call(cdp, st, &top, "activeValue", json!([])).await
        }
        "fillActive" => {
            let frame = st.focused_frame.clone().unwrap_or(top);
            call(cdp, st, &frame, "fillActive", json!([args["text"].as_str().unwrap_or("")])).await
        }
        "scroll" => call(cdp, st, &top, "scroll", json!([args["dy"].as_f64().unwrap_or(0.0)])).await,
        "waitText" => call(cdp, st, &top, "waitText", json!([args["text"].as_str().unwrap_or(""), args["gone"].as_bool().unwrap_or(false), args["ms"].as_i64().unwrap_or(10000)])).await,
        other => bail!("The background browser doesn't support {other}"),
    }
}

async fn key(cdp: &Cdp, chord: &str) -> Result<Value> {
    let action = json!({"do": "key", "keys": chord});
    if route(action.as_object().unwrap(), true) != Route::Browser {
        bail!("This shortcut isn't allowed in the background browser");
    }
    let lower = chord.to_lowercase().replace(' ', "");
    let parts: Vec<&str> = lower.split('+').collect();
    let last = parts.last().copied().unwrap_or("");
    let upper = last.to_uppercase();
    let (key, code, vk): (&str, String, i64) = match last {
        "return" | "enter" => ("Enter", "Enter".into(), 13),
        "tab" => ("Tab", "Tab".into(), 9),
        "escape" | "esc" => ("Escape", "Escape".into(), 27),
        "backspace" => ("Backspace", "Backspace".into(), 8),
        "delete" | "del" => ("Delete", "Delete".into(), 46),
        "down" => ("ArrowDown", "ArrowDown".into(), 40),
        "up" => ("ArrowUp", "ArrowUp".into(), 38),
        "left" => ("ArrowLeft", "ArrowLeft".into(), 37),
        "right" => ("ArrowRight", "ArrowRight".into(), 39),
        "home" => ("Home", "Home".into(), 36),
        "end" => ("End", "End".into(), 35),
        "pageup" => ("PageUp", "PageUp".into(), 33),
        "pagedown" => ("PageDown", "PageDown".into(), 34),
        "space" => (" ", "Space".into(), 32),
        other => (other, format!("Key{upper}"), upper.encode_utf16().next().unwrap_or(0) as i64),
    };
    let has = |names: &[&str]| parts.iter().any(|p| names.contains(p));
    let modifiers = if has(&["shift"]) { 8 } else { 0 } | if has(&["cmd", "command", "meta"]) { 4 } else { 0 } | if has(&["ctrl", "control"]) { 2 } else { 0 };
    let mut args = json!({"type": "rawKeyDown", "key": key, "code": code, "windowsVirtualKeyCode": vk, "modifiers": modifiers});
    if last == "a" && modifiers != 0 {
        args["commands"] = json!(["selectAll"]);
    } else if key == "Enter" {
        args["text"] = json!("\r");
        args["type"] = json!("keyDown");
    }
    cdp.call("Input.dispatchKeyEvent", args.clone()).await?;
    args["type"] = json!("keyUp");
    let map = args.as_object_mut().unwrap();
    map.remove("commands");
    map.remove("text");
    cdp.call("Input.dispatchKeyEvent", args).await?;
    Ok(json!({"pressed": true}))
}

#[cfg(test)]
mod tests {
    #[test]
    fn everyday_browser_profiles_are_refused() {
        let local = std::env::var("LOCALAPPDATA").unwrap();
        for folder in [format!(r"{local}\Google\Chrome\User Data"), format!(r"{local}\google\chrome\user data\"), format!(r"{local}\Google\Chrome\User Data\Profile 1"), format!(r"{local}\Microsoft\Edge\User Data")] {
            assert!(super::profile_problem(&folder).is_some(), "{folder}");
        }
        assert!(super::profile_problem(r"D:\Clinqy\Browser").is_none());
        assert!(super::profile_problem(&format!(r"{local}\Google\Chrome\User Data2")).is_none());
        assert!(super::profile_problem("Browser").is_some());
    }

    use super::*;
    use base64::Engine;

    fn page_url() -> String {
        let html = "<title>Worker</title><label>Name<input id='name'></label><button onclick=\"document.body.dataset.sent='yes';this.textContent='Confirmed'\">Submit sample</button>";
        format!("data:text/html;base64,{}", base64::engine::general_purpose::STANDARD.encode(html))
    }

    /// A real headless browser, end to end: needs Chrome or Edge, so `cargo test -- --ignored`.
    #[tokio::test(flavor = "multi_thread")]
    #[ignore]
    async fn drives_a_page_without_any_window() {
        let w: &'static Worker = Box::leak(Box::new(Worker::new(std::env::temp_dir().join(format!("clinqy-worker-tests-{}", uuid::Uuid::new_v4())))));
        w.run_started(false);
        let id = w.new_tab(&page_url()).await.unwrap();
        tokio::time::sleep(Duration::from_millis(400)).await;
        let page = w.snapshot(Some(id)).await.expect("snapshot");
        assert_eq!(page.title, "Worker");
        let field = page.elements.iter().find(|e| e.editable).expect("field").index;
        let button = page.elements.iter().find(|e| e.text.contains("Submit")).expect("button").index;
        w.command("fill", Some(id), json!({"index": field, "text": "Clinqy"})).await.unwrap();
        let value = w.command("value", Some(id), json!({"index": field})).await.unwrap();
        assert_eq!(value["value"], "Clinqy", "{value}");
        // A real (trusted) click at the element's spot.
        let spot = w.command("locate", Some(id), json!({"index": button})).await.unwrap();
        let (x, y) = (spot["px"].as_f64().unwrap_or(spot["x"].as_f64().unwrap() + 5.0), spot["py"].as_f64().unwrap_or(spot["y"].as_f64().unwrap() + 5.0));
        let t0 = std::time::Instant::now();
        w.command("cdpClick", Some(id), json!({"x": x, "y": y})).await.unwrap();
        assert!(t0.elapsed() < Duration::from_secs(1), "a hidden tab mustn't stall input: {:?}", t0.elapsed());
        tokio::time::sleep(Duration::from_millis(200)).await;
        let page = w.snapshot(Some(id)).await.expect("snapshot");
        assert!(page.elements.iter().any(|e| e.text.contains("Confirmed")), "the click landed");
        assert!(w.picture(Some(id), 70).await.map(|p| p.len() > 1000).unwrap_or(false));
        assert!(w.command("cdpKey", Some(id), json!({"keys": "ctrl+v"})).await.is_err(), "no shared clipboard");
        w.run_ended().await;
        assert!(w.picture(None, 70).await.is_some(), "the final picture survives freezing");
        w.stop().await;
        assert!(!w.connected());
    }
}
