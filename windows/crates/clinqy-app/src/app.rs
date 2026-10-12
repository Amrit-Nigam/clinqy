//! ClinqyApp: the tray icon, the command bar, the status island, and everything that wires the agent to them — the
//! hotkey (tap to open, hold to talk), the IPC pipe for the `clinqy` command, schedules and reminders.

use crate::ui::{Bar, Island, ResultPanel};
use clinqy_core::agent::{Context, Copied, Event as AgentEvent, RunOptions};
use clinqy_core::platform::{Mood, Platform};
use clinqy_core::{bridge, history, workflow, Agent};
use clinqy_windows::hotkey::{self, HotEvent};
use clinqy_windows::{Overlay, WindowsPlatform};
use parking_lot::Mutex;
use serde_json::{json, Value};
use std::sync::Arc;
use std::time::{Duration, Instant};
use tao::event::{Event, StartCause, WindowEvent};
use tao::event_loop::{ControlFlow, EventLoopBuilder, EventLoopProxy};
use tokio::sync::broadcast;
use tray_icon::menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem, Submenu};
use tray_icon::{TrayIconBuilder, TrayIconEvent};

#[derive(Debug, Clone)]
pub enum UserEvent {
    Agent(AgentEvent),
    Hot(HotEvent),
    HoldTimer(u64),
    Bar(String),
    Result(String),
    Menu(String),
    TrayClick,
    ShowBar,
    Notice(String),
    BarBlur,
    VoiceLevel(f32),
    VoiceText(String, bool),
    /// The loop the user drew with "Circle" (None: cancelled).
    Circled(Option<Vec<clinqy_core::platform::Point>>),
    Quit,
}

/// What the IPC server and other background parts need from the app.
pub struct Shared {
    pub agent: Arc<Agent>,
    pub platform: Arc<WindowsPlatform>,
    pub events: broadcast::Sender<AgentEvent>,
    pub proxy: Mutex<EventLoopProxy<UserEvent>>,
    pub voice: crate::voice::Voice,
}

impl Shared {
    pub fn send(&self, e: UserEvent) {
        let _ = self.proxy.lock().send_event(e);
    }
}

/// The clipboard's latest change (for "this" meaning what was just copied).
#[derive(Default, Clone)]
struct ClipState {
    seq: u32,
    at: Option<Instant>,
    text: Option<String>,
    files: Vec<std::path::PathBuf>,
}

pub fn run() -> anyhow::Result<()> {
    clinqy_windows::init_process();
    clinqy_windows::com::mark_ui_thread();
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().thread_name("clinqy-rt").build()?;
    let _guard = rt.enter();

    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();

    let overlay = Arc::new(Overlay::start());
    let platform = Arc::new(WindowsPlatform::new(overlay.clone()));
    let (events, _) = broadcast::channel::<AgentEvent>(512);
    let ev_tx = events.clone();
    let p2 = proxy.clone();
    let agent = Agent::new(platform.clone(), overlay.clone(), move |e| {
        let _ = ev_tx.send(e.clone());
        let _ = p2.send_event(UserEvent::Agent(e));
    });
    let p3 = proxy.clone();
    let voice = crate::voice::Voice::new(
        Box::new({
            let p = proxy.clone();
            move |l| {
                let _ = p.send_event(UserEvent::VoiceLevel(l));
            }
        }),
        Box::new(move |text, done| {
            let _ = p3.send_event(UserEvent::VoiceText(text, done));
        }),
    );
    let shared = Arc::new(Shared { agent: agent.clone(), platform: platform.clone(), events, proxy: Mutex::new(proxy.clone()), voice });
    let _ = crate::ipc::token();

    // The browser extension's bridge, and which browser each connection belongs to.
    bridge::bridge().set_owner_lookup(Box::new(clinqy_windows::system::owner_of_port));
    rt.spawn(async {
        if let Err(e) = bridge::bridge().start().await {
            clinqy_core::log::write(&format!("{e}"));
        }
    });
    rt.spawn(crate::server::serve(shared.clone()));
    agent.prewarm();

    // The summon chord.
    let hk = clinqy_core::config::value("HOTKEY").unwrap_or_else(|| "ctrl+alt".into());
    let hotkey_label = hotkey::label(&hk);
    {
        let p = proxy.clone();
        hotkey::start(&hk, move |e| {
            let _ = p.send_event(UserEvent::Hot(e));
        });
    }

    // Tray.
    let menu = Menu::new();
    let item = |id: &str, text: &str| MenuItem::with_id(id, text, true, None);
    let dry = CheckMenuItem::with_id("dry", "Dry run (show, don't do)", true, false, None);
    let login = CheckMenuItem::with_id("login", "Open at login", true, crate::setup::starts_at_login(), None);
    // Voice language: what Whisper listens for (saved as VOICE_LANGUAGE in the settings file).
    let current = crate::voice::language_setting();
    let languages: Vec<CheckMenuItem> = crate::voice::LANGUAGES
        .iter()
        .map(|(code, label)| CheckMenuItem::with_id(format!("lang:{code}"), *label, true, current == *code, None))
        .collect();
    let voice_menu = Submenu::with_id("voice", "Voice language", true);
    for l in &languages {
        let _ = voice_menu.append(l);
    }
    let _ = menu.append_items(&[
        &item("open", &format!("Open Clinqy\t{hotkey_label}")),
        &item("talk", &format!("Talk (hold {hotkey_label})")),
        &item("stop", "Stop the current task"),
        &PredefinedMenuItem::separator(),
        &item("circle", "Circle something…"),
        &item("watch", "Watch && learn…"),
        &item("history", "History"),
        &item("applications", "Applications…"),
        &item("stats", "Stats…"),
        &PredefinedMenuItem::separator(),
        &item("memory", "Edit memory…"),
        &item("profile", "Job profile…"),
        &item("settings", "Settings (model, keys)…"),
        &item("extension", "Browser extension…"),
        &item("check", "Check setup…"),
        &voice_menu,
        &dry,
        &login,
        &PredefinedMenuItem::separator(),
        &item("quit", "Quit Clinqy"),
    ]);
    let icon = {
        let img = image::load_from_memory(include_bytes!("../../../assets/tray.png"))?.to_rgba8();
        let (w, h) = img.dimensions();
        tray_icon::Icon::from_rgba(img.into_raw(), w, h)?
    };
    let _tray = TrayIconBuilder::new().with_menu(Box::new(menu)).with_tooltip(format!("Clinqy — {hotkey_label} to open")).with_icon(icon).build()?;
    {
        let p = proxy.clone();
        MenuEvent::set_event_handler(Some(move |e: MenuEvent| {
            let _ = p.send_event(UserEvent::Menu(e.id.0.clone()));
        }));
        let p = proxy.clone();
        TrayIconEvent::set_event_handler(Some(move |e: TrayIconEvent| {
            if let TrayIconEvent::Click { button: tray_icon::MouseButton::Left, button_state: tray_icon::MouseButtonState::Up, .. } = e {
                let _ = p.send_event(UserEvent::TrayClick);
            }
        }));
    }

    let bar = Bar::new(&event_loop, proxy.clone())?;
    let island = Island::new();
    let result = ResultPanel::new(&event_loop, proxy.clone())?;

    // The clipboard's recent history, for "this" when nothing is selected.
    let clip = Arc::new(Mutex::new(ClipState::default()));
    {
        let clip = clip.clone();
        let platform = platform.clone();
        std::thread::spawn(move || loop {
            std::thread::sleep(Duration::from_millis(900));
            let seq = platform.clipboard_sequence();
            let mut c = clip.lock();
            if seq != c.seq {
                let first = c.seq == 0;
                c.seq = seq;
                if !first {
                    c.at = Some(Instant::now());
                    c.text = platform.clipboard_text().filter(|t| !t.trim().is_empty() && t.len() < 20_000);
                    c.files = platform.clipboard_files();
                }
            }
        });
    }

    // Schedules, daily workflows and reminders.
    {
        let shared = shared.clone();
        rt.spawn(async move {
            loop {
                tokio::time::sleep(Duration::from_secs(20)).await;
                for r in clinqy_core::scheduler::due_reminders() {
                    shared.send(UserEvent::Notice(format!("⏰ {}{}", r.title, r.notes.map(|n| format!(" — {n}")).unwrap_or_default())));
                }
                if shared.agent.is_running() {
                    continue;
                }
                if let Some(item) = clinqy_core::scheduler::take_due() {
                    clinqy_core::log::write(&format!("scheduled run: {}", item.request));
                    shared.agent.submit(&item.request, RunOptions::default());
                    continue;
                }
                let hm = chrono::Local::now().format("%H:%M").to_string();
                let today = chrono::Local::now().format("%Y-%m-%d").to_string();
                for mut wf in workflow::workflows().all() {
                    if wf.schedule.as_deref() == Some(hm.as_str()) && !wf.last_scheduled_run.as_deref().map(|d| d.starts_with(&today)).unwrap_or(false) {
                        wf.last_scheduled_run = Some(chrono::Local::now().to_rfc3339());
                        workflow::workflows().update(wf.clone());
                        shared.agent.run_workflow(&wf.name, Default::default());
                        break;
                    }
                }
            }
        });
    }

    let mut ui = UiState {
        shared: shared.clone(),
        bar,
        island,
        result,
        island_on: false,
        notice: None,
        dry,
        languages,
        login,
        clip,
        hotkey_label,
        pressed_at: None,
        hold_id: 0,
        holding: false,
        voice_run: false,
        tab: "home".into(),
        island_until: None,
        follow_up: false,
    };
    let proxy_for_loop = proxy.clone();
    event_loop.run(move |event, _target, control_flow| {
        *control_flow = match ui.island_until {
            Some(t) => ControlFlow::WaitUntil(t),
            None => ControlFlow::Wait,
        };
        match event {
            Event::NewEvents(StartCause::Init) => {
                std::thread::spawn(crate::setup::register_links);
                if crate::setup::first_run() {
                    let _ = proxy_for_loop.send_event(UserEvent::Notice(format!("Clinqy is ready — tap {} to open it", ui.hotkey_label)));
                }
            }
            Event::NewEvents(StartCause::ResumeTimeReached { .. }) => {
                if ui.island_until.map(|t| Instant::now() >= t).unwrap_or(false) {
                    ui.island_until = None;
                    ui.notice = None;
                    if !ui.shared.agent.is_running() && !ui.shared.voice.is_listening() && !crate::recorder::is_recording() {
                        ui.island_on = false;
                        ui.island.hide();
                    } else {
                        ui.refresh_island();
                    }
                }
            }
            Event::UserEvent(e) => {
                if let UserEvent::Quit = e {
                    *control_flow = ControlFlow::Exit;
                    return;
                }
                ui.handle(e);
            }
            Event::WindowEvent { window_id, event: WindowEvent::Focused(false), .. } if window_id == ui.bar.window.id() => {
                // Clicking elsewhere puts the bar away, like Spotlight (not while it's asking something).
                // WebView2's own window taking the keyboard also blurs the bar, so check what's really in front.
                let p = proxy_for_loop.clone();
                tokio::spawn(async move {
                    tokio::time::sleep(Duration::from_millis(120)).await;
                    let _ = p.send_event(UserEvent::BarBlur);
                });
            }
            _ => {}
        }
    });
}

struct UiState {
    shared: Arc<Shared>,
    bar: Bar,
    island: Island,
    result: ResultPanel,
    island_on: bool,
    notice: Option<String>,
    dry: CheckMenuItem,
    languages: Vec<CheckMenuItem>,
    login: CheckMenuItem,
    clip: Arc<Mutex<ClipState>>,
    hotkey_label: String,
    pressed_at: Option<Instant>,
    hold_id: u64,
    holding: bool,
    voice_run: bool,
    tab: String,
    island_until: Option<Instant>,
    follow_up: bool,
}

impl UiState {
    fn agent(&self) -> &Arc<Agent> {
        &self.shared.agent
    }

    fn extras(&self) -> Value {
        let hist: Vec<Value> = history::history()
            .entries()
            .iter()
            .take(40)
            .map(|h| json!({"id": h.id, "date": h.date, "request": h.request, "answer": h.answer, "ok": h.ok, "result": h.result.is_some(), "trace": h.trace.as_ref().map(|t| !t.is_empty()).unwrap_or(false)}))
            .collect();
        let wfs: Vec<Value> = workflow::workflows().all().iter().map(|w| json!({"id": w.id, "name": w.name, "steps": w.steps.len(), "runs": w.runs, "schedule": w.schedule, "params": w.params})).collect();
        let skills: Vec<Value> = clinqy_core::skills::all().iter().map(|s| json!({"id": s.id, "name": s.name, "summary": s.summary, "parameters": s.parameters, "steps": s.steps})).collect();
        let provider = clinqy_core::provider::Provider::current();
        let ctx = self.agent().context.lock().clone();
        let name = |p: &std::path::Path| p.file_name().map(|f| f.to_string_lossy().into_owned()).unwrap_or_else(|| p.display().to_string());
        let copied = ctx.copied.as_ref().map(|c| {
            let what = c.text.as_ref().map(|t| format!("“{}”", t.chars().take(60).collect::<String>().replace(char::is_control, " "))).unwrap_or_else(|| c.files.iter().map(|f| name(f)).collect::<Vec<_>>().join(", "));
            format!("{what} · {}", if c.age_secs < 60 { "just now".to_string() } else { format!("{} min ago", c.age_secs / 60) })
        });
        let context = json!({
            "continuing": ctx.continuation.as_ref().map(|c| c.request.clone()),
            "selected": ctx.selected_text,
            "files": ctx.selected_files.iter().map(|f| name(f)).collect::<Vec<_>>(),
            "copied": copied,
            "circled": ctx.circled.as_deref().map(clinqy_core::agent::circle_bounds).map(|r| format!("{}×{}", r.w as i64, r.h as i64)),
        });
        let transcript = self.shared.voice.transcript();
        json!({
            "context": context, "recording": crate::recorder::is_recording(), "learning": crate::recorder::is_learning(),
            "transcribing": transcript == "Transcribing…",
            "snap": self.agent().snapshot(),
            "history": hist, "workflows": wfs, "skills": skills,
            "listening": self.shared.voice.is_listening(), "transcript": if transcript == "Transcribing…" { String::new() } else { transcript },
            "hotkey": self.hotkey_label, "model": format!("{} · {}", provider.id(), provider.default_model()),
        })
    }

    fn refresh_bar(&self) {
        if self.bar.visible() {
            self.bar.update(&self.extras());
        }
    }

    fn refresh_island(&self) {
        let mut v = serde_json::to_value(self.agent().snapshot()).unwrap_or_default();
        v["listening"] = json!(self.shared.voice.is_listening());
        let t = self.shared.voice.transcript();
        v["transcribing"] = json!(t == "Transcribing…");
        v["transcript"] = json!(if t == "Transcribing…" { String::new() } else { t });
        v["followUp"] = json!(self.follow_up);
        v["recording"] = json!(crate::recorder::is_recording());
        v["hotkey"] = json!(self.hotkey_label);
        if let Some(n) = &self.notice {
            v["notice"] = json!(n);
        }
        self.island.update(&v, self.island_on);
    }

    /// Notes what the user was looking at (the app, selected text, files, a recent copy) before the bar opens.
    fn capture_context_then_show(&self) {
        let agent = self.agent().clone();
        if agent.question().is_some() || agent.is_running() {
            self.shared.send(UserEvent::ShowBar);
            return;
        }
        let platform = self.shared.platform.clone();
        let clip = self.clip.lock().clone();
        let shared = self.shared.clone();
        tokio::spawn(async move {
            let target = platform.front_app();
            let mut ctx = Context { target: target.clone(), ..Default::default() };
            if let Some(t) = &target {
                if t.exe == "explorer.exe" {
                    // Files selected in File Explorer ride along ("compress this", "merge these").
                    let before = platform.clipboard_sequence();
                    let saved = platform.clipboard_text();
                    platform.set_target(Some(t));
                    let _ = platform.press("ctrl+c");
                    platform.set_target(None);
                    tokio::time::sleep(Duration::from_millis(150)).await;
                    if platform.clipboard_sequence() != before {
                        ctx.selected_files = platform.clipboard_files();
                        if let Some(s) = saved {
                            platform.set_clipboard_text(&s);
                        }
                    }
                }
                if ctx.selected_files.is_empty() {
                    ctx.selected_text = if platform.is_browser(t) && bridge::bridge().is_connected() {
                        bridge::bridge().selection(Some(&t.exe)).await
                    } else {
                        platform.selected_text(t).await
                    };
                }
            }
            if ctx.selected_text.is_none() && ctx.selected_files.is_empty() {
                if let Some(at) = clip.at.filter(|a| a.elapsed() < Duration::from_secs(600)) {
                    ctx.copied = Some(Copied { text: clip.text.clone(), files: clip.files.clone(), age_secs: at.elapsed().as_secs() });
                }
            }
            let keep_continuation = shared.agent.context.lock().continuation.clone();
            ctx.continuation = keep_continuation;
            *shared.agent.context.lock() = ctx;
            shared.send(UserEvent::ShowBar);
        });
    }

    /// Hides the bar, lets the user draw a loop around something, then brings the bar back with it attached.
    fn start_circling(&mut self) {
        self.bar.hide();
        let shared = self.shared.clone();
        let platform = self.shared.platform.clone();
        tokio::spawn(async move {
            if shared.agent.context.lock().target.is_none() {
                shared.agent.context.lock().target = platform.front_app();
            }
            let points = tokio::task::spawn_blocking(clinqy_windows::circle::pick).await.ok().flatten();
            shared.send(UserEvent::Circled(points));
        });
    }

    fn show_bar(&mut self) {
        self.bar.show(&self.extras());
    }

    fn submit(&mut self, text: &str, voice: bool) {
        self.voice_run = voice;
        self.bar.hide();
        self.bar.clear();
        let target = self.agent().context.lock().target.clone();
        let platform = self.shared.platform.clone();
        let agent = self.agent().clone();
        let text = text.to_string();
        tokio::spawn(async move {
            // The app the user was in comes back to the front first: keys and clicks go there.
            if let Some(t) = target {
                platform.bring_to_front(&t).await;
            }
            agent.submit(&text, RunOptions::default());
        });
    }

    fn start_listening(&mut self) {
        let a = self.agent().clone();
        if !a.is_running() && a.question().is_none() {
            // Context for a spoken request is captured at the start, while the user's app is in front.
            self.capture_context_silently();
        }
        self.shared.voice.start();
        self.shared.agent.buddy.set_mood(Mood::Listening);
        a.set_listening(true);
        self.island_until = None;
        self.island_on = true;
        self.refresh_island();
    }

    fn capture_context_silently(&self) {
        let platform = self.shared.platform.clone();
        let shared = self.shared.clone();
        tokio::spawn(async move {
            let target = platform.front_app();
            let mut ctx = shared.agent.context.lock().clone();
            ctx.target = target;
            *shared.agent.context.lock() = ctx;
        });
    }

    fn handle(&mut self, e: UserEvent) {
        match e {
            UserEvent::Agent(ev) => self.on_agent(ev),
            UserEvent::Hot(h) => self.on_hotkey(h),
            UserEvent::HoldTimer(id) => {
                if id == self.hold_id && self.pressed_at.is_some() && !self.holding {
                    self.holding = true;
                    self.bar.hide();
                    self.start_listening();
                }
            }
            UserEvent::ShowBar => self.show_bar(),
            UserEvent::TrayClick => {
                if self.agent().is_running() {
                    self.agent().cancel();
                } else if self.bar.visible() {
                    self.bar.hide();
                } else {
                    self.capture_context_then_show();
                }
            }
            UserEvent::Bar(msg) => self.on_bar(&msg),
            UserEvent::BarBlur => {
                let s = self.agent().snapshot();
                if self.bar.visible() && !self.bar.has_focus() && s.question.is_none() && s.review.is_none() && !self.shared.voice.is_listening() {
                    self.bar.hide();
                }
            }
            UserEvent::Result(msg) => self.on_result(&msg),
            UserEvent::Circled(points) => {
                let agent = self.agent().clone();
                let target = agent.context.lock().target.clone();
                // The user's app comes back to the front first (keys and clicks go there), then the bar over it.
                let reopen = !agent.is_running();
                if let Some(t) = target {
                    let p = self.shared.platform.clone();
                    let shared = self.shared.clone();
                    tokio::spawn(async move {
                        p.bring_to_front(&t).await;
                        if reopen {
                            shared.send(UserEvent::ShowBar);
                        }
                    });
                } else if reopen {
                    self.shared.send(UserEvent::ShowBar);
                }
                match points {
                    // While a task runs, the circle goes in as added context instead.
                    Some(pts) if agent.is_running() => {
                        let r = clinqy_core::agent::circle_bounds(&pts);
                        agent.add_context(&format!("I circled this area of the screen: x {}–{}, y {}–{} (screen pixels).", r.x as i64, r.max_x() as i64, r.y as i64, r.max_y() as i64));
                    }
                    Some(pts) => agent.context.lock().circled = Some(pts),
                    None => {}
                }
            }
            UserEvent::Menu(id) => self.on_menu(&id),
            UserEvent::Notice(text) => {
                crate::setup::beep();
                self.notice = Some(text);
                self.island_on = true;
                self.refresh_island();
                self.island_until = Some(Instant::now() + Duration::from_secs(8));
            }
            UserEvent::VoiceLevel(l) => {
                self.shared.agent.buddy.set_level(l);
                self.island.level(l);
                self.bar.level(l);
            }
            UserEvent::VoiceText(text, done) => {
                if !done {
                    self.refresh_island();
                    self.refresh_bar();
                    return;
                }
                self.agent().set_listening(false);
                self.shared.agent.buddy.set_mood(if self.agent().is_running() { Mood::Acting } else { Mood::Idle });
                let follow = std::mem::take(&mut self.follow_up);
                let text = text.trim().to_string();
                if text.is_empty() {
                    if !self.agent().is_running() {
                        self.island_on = false;
                        self.island_on = false;
                    self.island.hide();
                    }
                    return;
                }
                let a = self.agent().clone();
                if a.question().is_some() || a.snapshot().review.is_some() {
                    a.answer(Some(text));
                } else if a.is_running() {
                    a.add_context(&text);
                } else if follow && workflow::is_dismissal(&text) {
                    a.context.lock().continuation = None;
                    self.island_on = false;
                    self.island.hide();
                } else {
                    self.submit(&text, true);
                }
            }
            UserEvent::Quit => {}
        }
    }

    fn on_hotkey(&mut self, h: HotEvent) {
        match h {
            HotEvent::Pressed => {
                self.pressed_at = Some(Instant::now());
                self.holding = false;
                self.hold_id += 1;
                let id = self.hold_id;
                let p = self.shared.proxy.lock().clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_millis(320));
                    let _ = p.send_event(UserEvent::HoldTimer(id));
                });
            }
            HotEvent::Released => {
                let held = self.holding;
                self.pressed_at = None;
                self.holding = false;
                if held {
                    self.shared.voice.stop();
                } else if self.bar.visible() {
                    self.bar.hide();
                } else {
                    self.capture_context_then_show();
                }
            }
            HotEvent::Spoiled => {
                // Part of another shortcut: undo anything it started.
                if self.holding {
                    self.shared.voice.cancel();
                    self.agent().set_listening(false);
                    if !self.agent().is_running() {
                        self.island_on = false;
                        self.island_on = false;
                    self.island.hide();
                    }
                }
                self.pressed_at = None;
                self.holding = false;
            }
        }
    }

    fn on_agent(&mut self, ev: AgentEvent) {
        match ev {
            AgentEvent::Changed(_) => {
                self.refresh_island();
                self.refresh_bar();
            }
            AgentEvent::Started => {
                self.island_until = None;
                self.bar.hide();
                self.island_on = true;
                self.refresh_island();
            }
            AgentEvent::Question => {
                // Paused for the user's input: the bar comes up with the question.
                self.show_bar();
            }
            AgentEvent::Answered => {
                self.bar.hide();
                let target = self.agent().context.lock().target.clone();
                let platform = self.shared.platform.clone();
                if let Some(t) = target {
                    tokio::spawn(async move {
                        platform.bring_to_front(&t).await;
                    });
                }
            }
            AgentEvent::Result => {
                if let Some(card) = self.agent().snapshot().result {
                    self.result.show(&serde_json::to_value(card).unwrap_or_default());
                }
            }
            AgentEvent::Finished { answer, ok } => {
                self.refresh_island();
                let has_card = self.agent().snapshot().result.is_some();
                if !has_card {
                    self.island_until = Some(Instant::now() + Duration::from_millis(4500));
                }
                // Stopped by the user: the bar comes back so they can say what to do differently.
                if !ok && answer == "Stopped" && !self.voice_run {
                    self.show_bar();
                }
                let spoken = std::mem::take(&mut self.voice_run);
                if spoken && ok && clinqy_core::config::on("FOLLOW_UP", true) {
                    // Keep the mic open a few seconds for a follow-up ("now email that to Rahul").
                    self.follow_up = true;
                    self.agent().context.lock().continuation = history::history().latest();
                    let p = self.shared.proxy.lock().clone();
                    let voice = self.shared.voice.clone();
                    std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_millis(1200));
                        voice.start_auto(5.0);
                        let _ = p.send_event(UserEvent::VoiceLevel(0.0));
                    });
                }
            }
        }
    }

    fn on_bar(&mut self, raw: &str) {
        let Ok(m) = serde_json::from_str::<Value>(raw) else { return };
        let s = |k: &str| m[k].as_str().unwrap_or("").to_string();
        let agent = self.agent().clone();
        match m["type"].as_str().unwrap_or("") {
            "ready" => self.refresh_bar(),
            "resize" => self.bar.resize(m["height"].as_f64().unwrap_or(120.0)),
            "hide" => {
                if agent.question().is_some() {
                    agent.answer(None);
                }
                self.bar.hide();
            }
            "submit" => self.submit(&s("text"), false),
            "add" => {
                agent.add_context(&s("text"));
                self.bar.hide();
            }
            "answer" => agent.answer(Some(s("text"))),
            "review" => agent.decide_review(m["submit"] == true, Some(s("note")).filter(|n| !n.is_empty())),
            "cancel" => agent.cancel(),
            "dry" => {
                let on = !agent.dry_run.load(std::sync::atomic::Ordering::Relaxed);
                agent.dry_run.store(on, std::sync::atomic::Ordering::Relaxed);
                self.dry.set_checked(on);
                self.refresh_bar();
            }
            "mic" => {
                if self.shared.voice.is_listening() {
                    self.shared.voice.stop();
                } else {
                    self.start_listening();
                    self.refresh_bar();
                }
            }
            "tab" => self.tab = s("tab"),
            "continue" => {
                if let Some(h) = history::history().get(&s("id")) {
                    agent.context.lock().continuation = Some(h);
                    self.bar.update(&json!({"tab": "home"}));
                    self.bar.focus();
                }
            }
            "again" => {
                if let Some(h) = history::history().get(&s("id")) {
                    let req = h.request.trim_start_matches("Dry run: ").to_string();
                    self.submit(&req, false);
                }
            }
            "savewf" => {
                if let Some(w) = history::history().get(&s("id")).as_ref().and_then(workflow::Workflow::from_entry) {
                    workflow::workflows().add(w);
                    self.refresh_bar();
                }
            }
            "runwf" => {
                self.bar.hide();
                agent.run_workflow(&s("name"), Default::default());
            }
            "delwf" => {
                workflow::workflows().remove(&s("id"));
                self.refresh_bar();
            }
            "daily" => {
                if let Some(mut w) = workflow::workflows().all().into_iter().find(|w| w.id == s("id")) {
                    let t = s("time");
                    w.schedule = regex::Regex::new(r"^\d{1,2}:\d{2}$").unwrap().is_match(t.trim()).then(|| {
                        let (h, mm) = t.trim().split_once(':').unwrap();
                        format!("{:02}:{mm}", h.parse::<u32>().unwrap_or(9))
                    });
                    workflow::workflows().update(w);
                    self.refresh_bar();
                }
            }
            "delskill" => {
                clinqy_core::skills::remove(&s("id"));
                self.refresh_bar();
            }
            "delhist" => {
                history::history().remove(&s("id"));
                self.refresh_bar();
            }
            "result" => {
                if let Some(card) = history::history().get(&s("id")).and_then(|h| h.result) {
                    agent.show_card(card);
                }
            }
            // A correction to the run that just failed: carry on from it with what to do differently.
            "fix" => {
                if let Some(h) = history::history().get(&s("id")) {
                    agent.context.lock().continuation = Some(h);
                    self.submit(&format!("That didn't work. {}", s("text")), false);
                }
            }
            "unchip" => {
                let mut c = agent.context.lock();
                match s("kind").as_str() {
                    "continuation" => c.continuation = None,
                    "selection" => c.selected_text = None,
                    "files" => c.selected_files.clear(),
                    "copied" => c.copied = None,
                    "circled" => c.circled = None,
                    _ => {}
                }
                drop(c);
                self.refresh_bar();
            }
            "circle" => self.start_circling(),
            "watch" => {
                self.bar.hide();
                crate::recorder::toggle(self.shared.clone());
            }
            _ => {}
        }
    }

    fn on_result(&mut self, raw: &str) {
        let Ok(m) = serde_json::from_str::<Value>(raw) else { return };
        match m["type"].as_str().unwrap_or("") {
            "resize" => self.result.resize(m["height"].as_f64().unwrap_or(200.0)),
            "copy" => {
                if let Some(r) = self.agent().snapshot().result {
                    self.shared.platform.set_clipboard_text(&r.plain());
                }
            }
            "dismiss" => {
                self.agent().dismiss_result();
                self.result.hide();
            }
            "link" => {
                if let Some(u) = m["url"].as_str().filter(|u| u.starts_with("http")) {
                    self.shared.platform.open_url_direct(u);
                }
            }
            _ => {}
        }
    }

    fn on_menu(&mut self, id: &str) {
        let agent = self.agent().clone();
        let open = |p: &std::path::Path| {
            clinqy_windows::system::shell_open(&p.display().to_string());
        };
        match id {
            "open" => self.capture_context_then_show(),
            "talk" => self.start_listening(),
            "stop" => agent.cancel(),
            "watch" => crate::recorder::toggle(self.shared.clone()),
            "circle" => self.start_circling(),
            "history" => {
                self.bar.update(&json!({"tab": "history"}));
                self.show_bar();
            }
            "applications" => {
                agent.show_applications();
            }
            "stats" => agent.show_card(clinqy_core::history::ResultCard { title: "How runs are going (7 days)".into(), text: clinqy_core::stats::report(7.0, false), items: vec![] }),
            "memory" => {
                let p = clinqy_core::memory::path();
                if !p.exists() {
                    let _ = std::fs::write(&p, "# What Clinqy remembers about you — one fact per line. Edit freely.\n");
                }
                open(&p);
            }
            "profile" => {
                let _ = clinqy_core::profile::current();
                open(&clinqy_core::profile::path());
            }
            "settings" => {
                crate::setup::ensure_env_file();
                let p = clinqy_core::paths::env_file();
                let w = clinqy_core::session::CREATE_NO_WINDOW;
                use std::os::windows::process::CommandExt;
                if std::process::Command::new("notepad.exe").arg(&p).creation_flags(w).spawn().is_err() {
                    open(&p);
                }
            }
            "extension" => crate::setup::show_extension_help(),
            "check" => agent.show_card(crate::setup::check_card(None)),
            lang if lang.starts_with("lang:") => {
                let code = &lang[5..];
                let _ = clinqy_core::config::set("VOICE_LANGUAGE", code);
                for (item, (c, _)) in self.languages.iter().zip(crate::voice::LANGUAGES) {
                    item.set_checked(c == code);
                }
            }
            "dry" => {
                let on = !agent.dry_run.load(std::sync::atomic::Ordering::Relaxed);
                agent.dry_run.store(on, std::sync::atomic::Ordering::Relaxed);
                self.dry.set_checked(on);
            }
            "login" => {
                let on = !crate::setup::starts_at_login();
                crate::setup::set_start_at_login(on);
                self.login.set_checked(crate::setup::starts_at_login());
            }
            "quit" => {
                agent.cancel();
                self.shared.send(UserEvent::Quit);
            }
            _ => {}
        }
    }
}
