//! The app's end of the pipe: requests from the `clinqy` command, the MCP server and clinqy:// links. A run
//! streams its steps back as they finish, and ends with the answer (following the run when it carries on by
//! itself after running out of steps, like the Mac's `clinqy run`).

use crate::app::{Shared, UserEvent};
use crate::ipc::{pipe_name, token, Request};
use clinqy_core::agent::{Event, RunOptions, StepState};
use clinqy_core::provider::Provider;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::sync::Arc;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};
use tokio::sync::broadcast;

pub async fn serve(shared: Arc<Shared>) {
    let name = pipe_name();
    let mut server = match ServerOptions::new().first_pipe_instance(true).create(&name) {
        Ok(s) => s,
        Err(e) => {
            clinqy_core::log::write(&format!("pipe: couldn't create {name}: {e}"));
            return;
        }
    };
    loop {
        if server.connect().await.is_err() {
            continue;
        }
        let connected = server;
        server = match ServerOptions::new().create(&name) {
            Ok(s) => s,
            Err(e) => {
                clinqy_core::log::write(&format!("pipe: {e}"));
                return;
            }
        };
        let shared = shared.clone();
        tokio::spawn(async move {
            let _ = handle(connected, shared).await;
        });
    }
}

struct Out {
    w: tokio::io::WriteHalf<NamedPipeServer>,
}

impl Out {
    async fn send(&mut self, v: Value) -> std::io::Result<()> {
        let mut line = v.to_string();
        line.push('\n');
        self.w.write_all(line.as_bytes()).await?;
        self.w.flush().await
    }
    async fn end(&mut self, mut v: Value) -> std::io::Result<()> {
        v["end"] = json!(true);
        self.send(v).await
    }
}

async fn handle(pipe: NamedPipeServer, shared: Arc<Shared>) -> std::io::Result<()> {
    let (r, w) = tokio::io::split(pipe);
    let mut out = Out { w };
    let mut lines = BufReader::new(r).lines();
    let Some(line) = lines.next_line().await? else { return Ok(()) };
    let Ok(req) = serde_json::from_str::<Request>(&line) else {
        return out.end(json!({"event": "error", "error": "bad request"})).await;
    };
    if req.token != token() {
        clinqy_core::log::write(&format!("ignored a request without the right token ({})", req.cmd));
        return out.end(json!({"event": "error", "error": "wrong token (~/.config/clinqy/cli-token)"})).await;
    }
    dispatch(&req.cmd, req.args.clone(), shared, &mut out).await
}

fn provider_of(args: &Value) -> Option<Provider> {
    if args["agy"] == true || args["agy"] == "1" {
        Some(Provider::AgyCli)
    } else if args["claude"] == true || args["claude"] == "1" {
        Some(Provider::ClaudeCli)
    } else {
        args["provider"].as_str().and_then(Provider::parse)
    }
}

fn flag(args: &Value, k: &str) -> bool {
    args[k] == true || args[k] == "1" || args[k] == "true"
}

async fn dispatch(cmd: &str, args: Value, shared: Arc<Shared>, out: &mut Out) -> std::io::Result<()> {
    let agent = shared.agent.clone();
    let s = |k: &str| args[k].as_str().unwrap_or("").to_string();
    match cmd {
        "ping" => out.end(json!({"event": "ok"})).await,
        "show" => {
            shared.send(UserEvent::ShowBar);
            out.end(json!({"event": "ok"})).await
        }
        "pause" | "resume" => {
            if !agent.is_running() {
                return out.end(json!({"event": "error", "error": "nothing is running"})).await;
            }
            agent.set_paused(cmd == "pause");
            out.end(json!({"event": "ok", "text": if cmd == "pause" { "Paused (clinqy resume carries on, clinqy stop ends it)" } else { "Resumed" }})).await
        }
        "status" => out.end(json!({"event": "ok", "snapshot": agent.snapshot(), "extension": clinqy_core::bridge::bridge().is_connected()})).await,
        "answer" => {
            agent.answer(Some(s("text")));
            out.end(json!({"event": "ok"})).await
        }
        "add" => {
            agent.add_context(&s("text"));
            out.end(json!({"event": "ok"})).await
        }
        "cancel" => {
            agent.cancel();
            out.end(json!({"event": "ok"})).await
        }
        "reload-extension" => {
            let n = clinqy_core::bridge::bridge().reload_all().await;
            out.end(json!({"event": "ok", "reloaded": n})).await
        }
        "page" => {
            let b = clinqy_core::bridge::bridge();
            if !b.is_connected() {
                return out.end(json!({"event": "error", "error": "the Clinqy browser extension isn't connected (open the browser; load the extension folder from Clinqy's install folder)"})).await;
            }
            let Some(page) = b.snapshot(None).await else {
                return out.end(json!({"event": "error", "error": "no browser tab in front"})).await;
            };
            let text = match s("cmd").as_str() {
                "url" => format!("{}\n{}", page.title, page.url),
                "read" => {
                    let r = b.perform("read", &page, json!({}), 8.0).await.ok();
                    format!("{}\n{}\n\n{}", page.title, page.url, r.and_then(|r| r["text"].as_str().map(String::from)).unwrap_or(page.text.clone()))
                }
                _ => {
                    let mut lines = vec![page.title.clone(), page.url.clone()];
                    if let Some(p) = &page.problem {
                        lines.push(format!("(can't read this page: {p})"));
                    }
                    lines.extend(page.elements.iter().map(|e| e.line()));
                    if !page.messages.is_empty() {
                        lines.push(format!("Messages: {}", page.messages.join(" · ")));
                    }
                    if !page.text.is_empty() {
                        lines.push(format!("Text on screen: {}", page.text));
                    }
                    lines.join("\n")
                }
            };
            out.end(json!({"event": "ok", "text": text})).await
        }
        "run" => {
            let task = s("task");
            if task.trim().is_empty() {
                return out.end(json!({"event": "error", "error": "no task"})).await;
            }
            if agent.is_running() {
                return out.end(json!({"event": "error", "error": "Clinqy is busy with another task; try again when it's done (or `clinqy stop`)"})).await;
            }
            let rx = shared.events.subscribe();
            let test = flag(&args, "test");
            let opts = RunOptions { test, dry: flag(&args, "dry"), provider: provider_of(&args), review_in_tests: flag(&args, "review"), save_in_tests: flag(&args, "save"), background: flag(&args, "background").then_some(true), ..Default::default() };
            agent.submit(&task, opts);
            follow(rx, out, !test).await
        }
        "workflow" => {
            let name = s("name");
            let params: HashMap<String, String> = args["params"].as_object().map(|o| o.iter().map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string())).collect()).unwrap_or_default();
            let rx = shared.events.subscribe();
            if !agent.run_workflow(&name, params) {
                return out.end(json!({"event": "error", "error": format!("no saved workflow called {name:?} (or Clinqy is busy)")})).await;
            }
            follow(rx, out, false).await
        }
        "qa" => {
            let (name, test, compiled) = if let Some(path) = args["path"].as_str() {
                let p = std::path::PathBuf::from(path);
                let Ok(text) = std::fs::read_to_string(&p) else {
                    return out.end(json!({"event": "error", "error": format!("can't read {path}")})).await;
                };
                let name = text.lines().find_map(|l| l.strip_prefix("# ")).map(String::from).unwrap_or_else(|| p.file_stem().unwrap_or_default().to_string_lossy().into_owned());
                let body: String = text.lines().filter(|l| !l.starts_with("# ")).collect::<Vec<_>>().join("\n");
                let compiled = p.parent().unwrap_or(std::path::Path::new(".")).join(".clinqy").join(format!("{}.json", p.file_stem().unwrap_or_default().to_string_lossy()));
                (name, body, compiled)
            } else {
                let text = s("text");
                let name = text.lines().find_map(|l| l.strip_prefix("# ")).map(String::from).unwrap_or_else(|| text.lines().next().unwrap_or("inline test").chars().take(50).collect());
                let compiled = std::env::temp_dir().join("clinqy-qa").join(format!("{:x}.json", text.len() * 31 + text.bytes().map(|b| b as usize).sum::<usize>()));
                (name, text, compiled)
            };
            let report = args["out"].as_str().map(std::path::PathBuf::from).unwrap_or_else(|| std::env::temp_dir().join(format!("clinqy-qa-{}.json", uuid::Uuid::new_v4())));
            let _ = std::fs::remove_file(&report);
            let rx = shared.events.subscribe();
            let model = args["model"].as_str().map(String::from);
            agent.run_qa(&name, &test, compiled, flag(&args, "relearn"), model, provider_of(&args), report.clone());
            let _ = follow(rx, out, false).await;
            // The report is written once the run has wrapped up.
            for _ in 0..40 {
                if report.exists() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(100)).await;
            }
            Ok(())
        }
        "url" => {
            // clinqy://run?task=…&token=… from a link (the token was checked on the link, not just the pipe).
            let Ok(u) = url::Url::parse(&s("url")) else { return out.end(json!({"event": "error", "error": "bad link"})).await };
            let q: HashMap<String, String> = u.query_pairs().map(|(k, v)| (k.into_owned(), v.into_owned())).collect();
            if q.get("token").map(|t| t != &token()).unwrap_or(true) {
                clinqy_core::log::write("ignored a clinqy:// link without the right token");
                return out.end(json!({"event": "error", "error": "wrong token"})).await;
            }
            let host = u.host_str().unwrap_or("").to_string();
            let mut a = json!({});
            for (k, v) in &q {
                a[k] = json!(v);
            }
            if host == "workflow" {
                let params: serde_json::Map<String, Value> = q.iter().filter(|(k, _)| *k != "name" && *k != "token").map(|(k, v)| (k.clone(), json!(v))).collect();
                a["params"] = Value::Object(params);
            }
            if host == "browser" {
                a["cmd"] = json!(q.get("cmd").cloned().unwrap_or_else(|| "page".into()));
                return Box::pin(dispatch("page", a, shared, out)).await;
            }
            Box::pin(dispatch(&host, a, shared, out)).await
        }
        other => out.end(json!({"event": "error", "error": format!("unknown command {other}")})).await,
    }
}

/// Streams a run's steps until it finishes (and, when `carry_on`, through the runs it continues with by itself).
async fn follow(mut rx: broadcast::Receiver<Event>, out: &mut Out, carry_on: bool) -> std::io::Result<()> {
    let mut sent: Vec<(String, StepState)> = vec![];
    let mut last_done: Option<(String, bool)> = None;
    loop {
        let next = if last_done.is_some() {
            // After a finish: wait a moment for an auto-continue to start.
            match tokio::time::timeout(Duration::from_secs(if carry_on { 4 } else { 1 }), rx.recv()).await {
                Ok(r) => r,
                Err(_) => break,
            }
        } else {
            rx.recv().await
        };
        let ev = match next {
            Ok(e) => e,
            Err(broadcast::error::RecvError::Lagged(_)) => continue,
            Err(_) => break,
        };
        match ev {
            Event::Started => {
                if last_done.is_some() {
                    sent.clear();
                    last_done = None;
                    out.send(json!({"event": "log", "text": "(carrying on by itself)"})).await?;
                }
            }
            Event::Changed(snap) => {
                for (i, st) in snap.steps.iter().enumerate() {
                    let finished = st.state != StepState::Running;
                    match sent.get(i) {
                        Some((t, s)) if *t == st.text && *s == st.state => {}
                        _ if finished => {
                            if sent.len() <= i {
                                sent.resize(i + 1, (String::new(), StepState::Running));
                            }
                            sent[i] = (st.text.clone(), st.state);
                            out.send(json!({"event": "step", "text": st.text, "state": st.state})).await?;
                        }
                        _ => {}
                    }
                }
                if let Some(q) = &snap.question {
                    out.send(json!({"event": "question", "text": q.text, "options": q.options})).await?;
                }
            }
            Event::Finished { answer, ok, .. } => {
                last_done = Some((answer, ok));
            }
            _ => {}
        }
    }
    let (answer, ok) = last_done.unwrap_or_else(|| ("(no result)".into(), false));
    out.end(json!({"event": "done", "ok": ok, "answer": answer})).await
}
