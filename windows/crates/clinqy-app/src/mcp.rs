//! `clinqy mcp`: Clinqy as an MCP server on stdio (newline-delimited JSON-RPC 2.0), so coding agents can hand it
//! on-screen tasks. Tasks go to the running app over the pipe; looking at the screen is done right here (UI
//! Automation needs no permission on Windows), or through the app for a browser tab.

use crate::ipc;
use serde_json::{json, Value};
use std::io::{BufRead, Write};

const VERSIONS: &[&str] = &["2025-06-18", "2025-03-26", "2024-11-05"];

const INSTRUCTIONS: &str = "Clinqy operates the user's own Windows PC and browser (their logins, their tabs) with a visible companion cursor. clinqy_look first to see what's in front (read-only). clinqy_run for anything that needs clicking or typing: describe the goal in plain words (\"fill the signup form with my details\", \"open github and star this repo\"); Clinqy plans and verifies each step itself and asks the user before paying, sending or submitting. One task at a time. clinqy_stats: how recent runs went.";

fn tool(name: &str, title: &str, desc: &str, props: Value, required: &[&str], read_only: bool) -> Value {
    json!({
        "name": name, "title": title, "description": desc,
        "inputSchema": {"type": "object", "properties": props, "required": required, "additionalProperties": false},
        "annotations": {"title": title, "readOnlyHint": read_only, "destructiveHint": !read_only, "idempotentHint": read_only, "openWorldHint": !read_only}
    })
}

fn tools() -> Value {
    json!([
        tool("clinqy_run", "Do a task on the PC",
            "Carry out a natural-language task on the user's Windows PC with Clinqy: it clicks, types and reads in the frontmost app or browser tab, and returns its steps and final answer. Not saved to the user's history or memory. dry=true only points at what it would click or type.",
            json!({"task": {"type": "string", "description": "What to do, in plain words."},
                   "dry": {"type": "boolean", "description": "Rehearse: point at each click and keystroke without doing it."},
                   "background": {"type": "boolean", "description": "Work in a hidden browser with its own sign-ins, leaving the user's mouse, keyboard and windows alone. Web pages, files and PDFs only."},
                   "timeout": {"type": "integer", "description": "Seconds to wait for the task to finish (default 300)."}}),
            &["task"], false),
        tool("clinqy_add", "Add to a task",
            "Give Clinqy more for its task: the running one takes it at its next step, or the latest task carries on with it if it has finished.",
            json!({"text": {"type": "string", "description": "What to add, in plain words."}}),
            &["text"], false),
        tool("clinqy_look", "Look at the screen",
            "What's in front right now, read-only. In a browser (with the Clinqy extension): the tab's title, URL, every field, button and link with its w-id, values and errors, and the visible text; mode=read gives the page's full text. In other apps: the window, focused element and visible controls from UI Automation.",
            json!({"mode": {"type": "string", "enum": ["page", "read", "url"], "description": "page (default), read (full text) or url."}}),
            &[], true),
        tool("clinqy_stats", "Run statistics",
            "Success rate, time per run, model vs action time per turn, and the most common failure reasons (read-only). last=true breaks down the most recent run turn by turn.",
            json!({"days": {"type": "number", "description": "How many days back (default 7)."}, "last": {"type": "boolean", "description": "Only the most recent run, turn by turn."}}),
            &[], true),
    ])
}

fn text(s: &str, is_error: bool) -> Value {
    json!({"content": [{"type": "text", "text": s}], "isError": is_error})
}

async fn run(task: &str, dry: bool, background: bool, timeout: u64) -> Value {
    if let Err(e) = ipc::ensure_app().await {
        return text(&format!("Clinqy isn't installed or wouldn't start: {e}"), true);
    }
    let mut steps: Vec<String> = vec![];
    let call = ipc::call("run", json!({"task": task, "test": true, "dry": dry, "background": background}), |v| {
        if v["event"] == "step" {
            let t = v["text"].as_str().unwrap_or("");
            steps.push(if v["state"] == "failed" { format!("  (failed: {t})") } else { format!("- {t}") });
        }
    });
    match tokio::time::timeout(std::time::Duration::from_secs(timeout.max(10)), call).await {
        Ok(Ok(v)) if v["event"] == "error" => text(v["error"].as_str().unwrap_or("error"), true),
        Ok(Ok(v)) => {
            let ok = v["ok"] == true;
            let s = if steps.is_empty() { String::new() } else { format!("Steps:\n{}\n\n", steps.join("\n")) };
            text(&format!("{s}{}{}", if ok { "Done: " } else { "Failed: " }, v["answer"].as_str().unwrap_or("")), !ok)
        }
        Ok(Err(e)) => text(&e.to_string(), true),
        Err(_) => text(&format!("Still running after {timeout} s; it keeps going in the app (stop it from the tray).{}", if steps.is_empty() { String::new() } else { format!("\nSo far:\n{}", steps.join("\n")) }), true),
    }
}

pub async fn look(mode: &str) -> Value {
    clinqy_windows::init_process();
    let front = clinqy_windows::apps::foreground().and_then(|f| clinqy_windows::apps::app_ref(f.0));
    if let Some(app) = &front {
        if clinqy_windows::apps::is_browser_exe(&app.exe) && ipc::app_running().await {
            if let Ok(v) = ipc::call("page", json!({"cmd": if ["read", "url"].contains(&mode) { mode } else { "page" }}), |_| {}).await {
                if let Some(t) = v["text"].as_str() {
                    return text(t, false);
                }
            }
        }
    }
    let Some(app) = front else { return text("Nothing is in front.", true) };
    let (main, dialog) = clinqy_windows::apps::foreground().unwrap_or((app.hwnd, None));
    let browser = clinqy_windows::apps::is_browser_exe(&app.exe);
    let scan = tokio::task::spawn_blocking(move || {
        clinqy_windows::com::ensure();
        clinqy_windows::uia::uia().scan(main, dialog, browser, clinqy_windows::screen::virtual_screen(), 150)
    })
    .await
    .unwrap_or_default();
    let mut lines = vec![format!("{} — {}", app.name, scan.window), format!("Focused: {}", scan.focused)];
    lines.extend(scan.elements.iter().map(|e| format!("{} {}: {}{}", e.id, e.role, e.label, e.value.as_ref().map(|v| format!(" = {v:?}")).unwrap_or_default())));
    text(&lines.join("\n"), false)
}

async fn handle(msg: Value) -> Option<Value> {
    let method = msg["method"].as_str().unwrap_or("");
    let params = &msg["params"];
    let id = msg.get("id").cloned()?;
    if id.is_null() {
        return None;
    }
    let result = match method {
        "initialize" => {
            let asked = params["protocolVersion"].as_str().unwrap_or("");
            json!({"protocolVersion": if VERSIONS.contains(&asked) { asked } else { VERSIONS[0] },
                   "capabilities": {"tools": {"listChanged": false}},
                   "serverInfo": {"name": "clinqy", "title": "Clinqy", "version": env!("CARGO_PKG_VERSION")},
                   "instructions": INSTRUCTIONS})
        }
        "ping" => json!({}),
        "tools/list" => json!({"tools": tools()}),
        "resources/list" => json!({"resources": []}),
        "prompts/list" => json!({"prompts": []}),
        "tools/call" => {
            let a = &params["arguments"];
            match params["name"].as_str().unwrap_or("") {
                "clinqy_run" => {
                    let task = a["task"].as_str().unwrap_or("").trim().to_string();
                    if task.is_empty() {
                        text("task is required", true)
                    } else {
                        run(&task, a["dry"] == true, a["background"] == true, a["timeout"].as_u64().unwrap_or(300)).await
                    }
                }
                "clinqy_add" => {
                    let added = a["text"].as_str().unwrap_or("").trim().to_string();
                    if added.is_empty() {
                        text("text is required", true)
                    } else {
                        match ipc::call("add", json!({"text": added}), |_| {}).await {
                            Ok(_) => text("Added to the task.", false),
                            Err(e) => text(&e.to_string(), true),
                        }
                    }
                }
                "clinqy_look" => look(a["mode"].as_str().unwrap_or("page")).await,
                "clinqy_stats" => text(&clinqy_core::stats::report(a["days"].as_f64().unwrap_or(7.0), a["last"] == true), false),
                other => return Some(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32602, "message": format!("unknown tool: {other}")}})),
            }
        }
        _ => return Some(json!({"jsonrpc": "2.0", "id": id, "error": {"code": -32601, "message": format!("method not found: {method}")}})),
    };
    Some(json!({"jsonrpc": "2.0", "id": id, "result": result}))
}

pub fn serve() -> i32 {
    let rt = tokio::runtime::Builder::new_multi_thread().enable_all().build().expect("runtime");
    let (tx, mut rx) = tokio::sync::mpsc::unbounded_channel::<Value>();
    // Replies go out on one writer, in the order they're ready.
    let writer = std::thread::spawn(move || {
        let mut out = std::io::stdout().lock();
        while let Some(v) = rx.blocking_recv() {
            let _ = writeln!(out, "{v}");
            let _ = out.flush();
        }
    });
    let stdin = std::io::stdin();
    let mut pending = vec![];
    for line in stdin.lock().lines() {
        let Ok(line) = line else { break };
        let t = line.trim();
        if t.is_empty() {
            continue;
        }
        let Ok(msg) = serde_json::from_str::<Value>(t) else {
            let _ = tx.send(json!({"jsonrpc": "2.0", "id": null, "error": {"code": -32700, "message": "parse error"}}));
            continue;
        };
        let msgs = if let Value::Array(a) = msg { a } else { vec![msg] };
        for m in msgs {
            if m["method"] == "notifications/cancelled" {
                // The client gave up on a run: stop it in the app.
                rt.spawn(async {
                    let _ = ipc::call("cancel", json!({}), |_| {}).await;
                });
                continue;
            }
            let tx = tx.clone();
            pending.push(rt.spawn(async move {
                if let Some(r) = handle(m).await {
                    let _ = tx.send(r);
                }
            }));
        }
    }
    for p in pending {
        let _ = rt.block_on(p);
    }
    drop(tx);
    let _ = writer.join();
    0
}
