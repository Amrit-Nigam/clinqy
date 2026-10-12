//! The `clinqy` command: drive the Clinqy app from a terminal or any coding agent (Claude Code, Codex, Cursor,
//! Antigravity…). The same commands as on the Mac.

use crate::ipc;
use serde_json::{json, Value};
use std::path::{Path, PathBuf};

pub const HELP: &str = "clinqy — drive Clinqy from a terminal or any coding agent (Claude Code, Codex, Cursor, Antigravity…).

  clinqy run [--dry|--test] [--agy|--claude] \"<task>\"
        Do a task like one asked in the app (saved to History; carries on by itself if it runs out of steps).
        --dry: point at each click/keystroke, don't do it. --test: a throwaway run (not saved, no carrying on).
  clinqy qa <test.md | folder | \"inline test\"> ... [--relearn] [--model sonnet|opus|haiku] [--agy] [--json]
        Run plain-English UI tests. The first run uses the model and compiles a script (saved in .clinqy\\ next to
        the test); later runs replay it with no model, healing only broken steps. Exit code 0 = all passed.
  clinqy workflow <name> [key=value ...]   Replay a saved workflow with parameters, no model.
  clinqy workflows                         List saved workflows.
  clinqy page [read|url]                   What's in the browser tab in front (via the extension), read-only.
  clinqy look [read|url]                   What's in front (the app's controls, or the browser tab), read-only.
  clinqy answer \"<text>\"                    Answer the question Clinqy is waiting on.
  clinqy stop                              Stop the current task now.
  clinqy pause | resume                    Hold the current task at its next step, then carry on.
  clinqy open                              Open the command bar.
  clinqy stats [days] [--last]             Success rate, time per turn, click outcomes, common failures (default 7 days).
  clinqy memory [\"request\"]                What memory holds (or exactly which facts a request would be sent).
  clinqy extension reload                  Reload the browser extension from disk.
  clinqy doctor                            What's set up and what isn't (model, extension, voice, Outlook).
  clinqy mcp                               Serve Clinqy as an MCP server on stdio (claude mcp add clinqy -- clinqy mcp).
";

fn rt() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_multi_thread().worker_threads(2).enable_all().build().expect("runtime")
}

fn fail(msg: &str) -> i32 {
    eprintln!("{msg}");
    2
}

fn print_step(v: &Value) {
    match v["event"].as_str() {
        Some("step") => {
            let mark = match v["state"].as_str() {
                Some("failed") => "✗",
                Some("info") => "·",
                _ => "→",
            };
            println!("{mark} {}", v["text"].as_str().unwrap_or(""));
        }
        Some("log") => println!("  {}", v["text"].as_str().unwrap_or("")),
        _ => {}
    }
}

pub fn main(args: Vec<String>) -> i32 {
    let cmd = args.first().map(|s| s.trim_start_matches('-').to_string()).unwrap_or_else(|| "help".into());
    let rest: Vec<String> = args.iter().skip(1).cloned().collect();
    match cmd.as_str() {
        "run" => run(&rest),
        "qa" => qa(&rest),
        "workflow" => {
            let Some(name) = rest.first() else { return fail("usage: clinqy workflow <name> [key=value ...]") };
            let params: serde_json::Map<String, Value> = rest[1..].iter().filter_map(|kv| kv.split_once('=')).map(|(k, v)| (k.to_string(), json!(v))).collect();
            stream("workflow", json!({"name": name, "params": params}), true)
        }
        "workflows" => {
            for w in clinqy_core::workflow::workflows().all() {
                println!(
                    "{}{} — {} steps, run {}×{}",
                    w.name,
                    if w.params.is_empty() { String::new() } else { format!(" ({})", w.params.join(", ")) },
                    w.steps.len(),
                    w.runs,
                    w.schedule.map(|s| format!(" · daily {s}")).unwrap_or_default()
                );
            }
            0
        }
        "page" => {
            let sub = rest.first().cloned().unwrap_or_else(|| "page".into());
            simple("page", json!({"cmd": sub}), true)
        }
        "answer" => simple("answer", json!({"text": rest.join(" ")}), false),
        "stop" | "cancel" => simple("cancel", json!({}), false),
        "pause" => simple("pause", json!({}), false),
        "resume" => simple("resume", json!({}), false),
        "open" | "show" => simple("show", json!({}), true),
        "extension" => {
            if rest.first().map(|s| s == "reload").unwrap_or(false) {
                simple("reload-extension", json!({}), true)
            } else {
                if let Some(d) = crate::setup::extension_dir() {
                    println!("{}", d.display());
                }
                0
            }
        }
        "stats" => {
            let days = rest.iter().find_map(|r| r.parse::<f64>().ok()).unwrap_or(7.0);
            println!("{}", clinqy_core::stats::report(days, rest.iter().any(|r| r == "--last")));
            0
        }
        "memory" => {
            let q = rest.iter().filter(|r| !r.starts_with("--")).cloned().collect::<Vec<_>>().join(" ");
            let facts = clinqy_core::memory::entries();
            println!("{} facts in {}", facts.len(), clinqy_core::memory::path().display());
            if q.is_empty() {
                for f in facts {
                    println!("{}{}", if clinqy_core::memory::is_profile(&f.text) { "P " } else { "  " }, f.line());
                }
            } else {
                let (sent, omitted) = clinqy_core::memory::relevant(&q, None, None, 40);
                println!("A request “{q}” is sent {} facts ({omitted} left out):", sent.len());
                for f in sent {
                    println!("{}{f}", if clinqy_core::memory::is_profile(&f) { "P " } else { "  " });
                }
            }
            0
        }
        "doctor" | "check" | "setup" => {
            // The extension connects to the app, not to this process: ask the app (when it's running).
            let ext = rt().block_on(async { ipc::call("status", json!({}), |_| {}).await.ok().and_then(|v| v["extension"].as_bool()) });
            let card = crate::setup::check_card(Some(ext.unwrap_or(false)));
            if ext.is_none() {
                println!("(Clinqy isn't running — start it to connect the browser extension.)");
            }
            println!("{}", card.plain());
            0
        }
        "mcp" => crate::mcp::serve(),
        "look" => {
            let v = rt().block_on(crate::mcp::look(rest.first().map(String::as_str).unwrap_or("page")));
            println!("{}", v["content"][0]["text"].as_str().unwrap_or(""));
            0
        }
        "url" => {
            // clinqy:// links (registered by the installer) land here.
            let Some(u) = rest.first() else { return 2 };
            simple("url", json!({"url": u}), true)
        }
        "transcribe" => {
            let Some(f) = rest.first() else { return fail("usage: clinqy transcribe <audio.wav>") };
            let rt = rt();
            let _g = rt.enter();
            let voice = crate::voice::Voice::new(Box::new(|_| {}), Box::new(|t, _| eprintln!("{t}")));
            let t0 = std::time::Instant::now();
            match rt.block_on(voice.transcribe_file(Path::new(f))) {
                Ok(t) => {
                    println!("{} ms: {t}", t0.elapsed().as_millis());
                    0
                }
                Err(e) => fail(&e.to_string()),
            }
        }
        "version" => {
            println!("clinqy {}", env!("CARGO_PKG_VERSION"));
            0
        }
        _ => {
            print!("{HELP}");
            if cmd == "help" || cmd == "h" {
                0
            } else {
                2
            }
        }
    }
}

/// One request, printing its text answer.
fn simple(cmd: &str, args: Value, start_app: bool) -> i32 {
    rt().block_on(async {
        if start_app {
            if let Err(e) = ipc::ensure_app().await {
                return fail(&e.to_string());
            }
        }
        match ipc::call(cmd, args, |_| {}).await {
            Ok(v) if v["event"] == "error" => fail(&format!("ERROR: {}", v["error"].as_str().unwrap_or("?"))),
            Ok(v) => {
                if let Some(t) = v["text"].as_str() {
                    println!("{t}");
                }
                0
            }
            Err(e) => fail(&e.to_string()),
        }
    })
}

/// A request that streams steps; exits 0 when it ended well.
fn stream(cmd: &str, args: Value, start_app: bool) -> i32 {
    rt().block_on(async {
        if start_app {
            if let Err(e) = ipc::ensure_app().await {
                return fail(&e.to_string());
            }
        }
        let mut last_q = String::new();
        let r = ipc::call(cmd, args, |v| {
            if v["event"] == "question" {
                let q = v["text"].as_str().unwrap_or("").to_string();
                if q != last_q {
                    println!("? {q}  (answer in the app, or: clinqy answer \"…\")");
                    last_q = q;
                }
            } else {
                print_step(v);
            }
        })
        .await;
        match r {
            Ok(v) if v["event"] == "error" => fail(&format!("ERROR: {}", v["error"].as_str().unwrap_or("?"))),
            Ok(v) => {
                let ok = v["ok"] == true;
                println!("{} {}", if ok { "✓" } else { "✗" }, v["answer"].as_str().unwrap_or(""));
                if ok {
                    0
                } else {
                    1
                }
            }
            Err(e) => fail(&e.to_string()),
        }
    })
}

fn run(rest: &[String]) -> i32 {
    let mut a = json!({});
    let mut words = vec![];
    for r in rest {
        match r.as_str() {
            "--dry" => a["dry"] = json!(true),
            "--test" => a["test"] = json!(true),
            "--agy" | "--agy-cli" => a["agy"] = json!(true),
            "--claude" | "--claude-cli" => a["claude"] = json!(true),
            "--help" | "-h" => {
                println!("usage: clinqy run [--dry] [--test] [--claude|--agy] <request…>");
                return 0;
            }
            other => words.push(other.to_string()),
        }
    }
    if words.is_empty() {
        return fail("usage: clinqy run [--dry|--test] \"<task>\"");
    }
    a["task"] = json!(words.join(" "));
    stream("run", a, true)
}

fn tests_in(target: &str) -> Vec<String> {
    let p = Path::new(target);
    if p.is_dir() {
        let mut out = vec![];
        let mut stack = vec![p.to_path_buf()];
        while let Some(d) = stack.pop() {
            let Ok(rd) = std::fs::read_dir(&d) else { continue };
            for e in rd.flatten() {
                let path = e.path();
                if path.is_dir() {
                    if e.file_name() != ".clinqy" {
                        stack.push(path);
                    }
                } else if path.extension().map(|x| x == "md" || x == "txt").unwrap_or(false) {
                    out.push(std::fs::canonicalize(&path).unwrap_or(path).display().to_string().trim_start_matches(r"\\?\").to_string());
                }
            }
        }
        out.sort();
        out
    } else if p.is_file() {
        vec![std::fs::canonicalize(p).map(|c| c.display().to_string().trim_start_matches(r"\\?\").to_string()).unwrap_or_else(|_| target.to_string())]
    } else {
        vec![format!("inline:{target}")]
    }
}

fn qa(rest: &[String]) -> i32 {
    let (mut relearn, mut json_out, mut agy) = (false, false, false);
    let mut model: Option<String> = None;
    let mut targets = vec![];
    let mut it = rest.iter();
    while let Some(r) = it.next() {
        match r.as_str() {
            "--relearn" => relearn = true,
            "--json" => json_out = true,
            "--agy" | "--agy-cli" => agy = true,
            "--claude" | "--claude-cli" => agy = false,
            "--model" => model = it.next().cloned(),
            other => targets.push(other.to_string()),
        }
    }
    if targets.is_empty() {
        return fail("usage: clinqy qa <test.md|folder|\"inline test\"> [--relearn] [--model m] [--agy] [--json]");
    }
    let files: Vec<String> = targets.iter().flat_map(|t| tests_in(t)).collect();
    let rt = rt();
    if let Err(e) = rt.block_on(ipc::ensure_app()) {
        return fail(&e.to_string());
    }
    let mut failed = false;
    for f in files {
        let out = std::env::temp_dir().join(format!("clinqy-qa-{}.json", uuid::Uuid::new_v4()));
        let mut a = json!({"relearn": relearn, "agy": agy, "out": out.display().to_string()});
        if let Some(t) = f.strip_prefix("inline:") {
            a["text"] = json!(t);
        } else {
            a["path"] = json!(f);
        }
        if let Some(m) = &model {
            a["model"] = json!(m);
        }
        let r = rt.block_on(ipc::call("qa", a, |_| {}));
        if let Err(e) = r {
            println!("ERROR  {}: {e}", f.trim_start_matches("inline:"));
            failed = true;
            continue;
        }
        let report: Option<Value> = std::fs::read_to_string(&out).ok().and_then(|t| serde_json::from_str(&t).ok());
        let _ = std::fs::remove_file(&out);
        let Some(r) = report else {
            println!("TIMEOUT  {}", f.trim_start_matches("inline:"));
            failed = true;
            continue;
        };
        let passed = r["passed"] == true;
        failed |= !passed;
        if json_out {
            println!("{r}");
            continue;
        }
        println!("{}  {}  ({}, {:.1}s)", if passed { "PASS" } else { "FAIL" }, r["name"].as_str().unwrap_or(""), r["mode"].as_str().unwrap_or(""), r["durationMs"].as_f64().unwrap_or(0.0) / 1000.0);
        for c in r["checks"].as_array().cloned().unwrap_or_default() {
            let pass = c["pass"] == true;
            let note = c["note"].as_str().unwrap_or("");
            println!("   {} {}{}", if pass { "✓" } else { "✗" }, c["text"].as_str().unwrap_or(""), if !pass && !note.is_empty() { format!("  — {note}") } else { String::new() });
        }
        if !passed {
            let steps = r["steps"].as_array().cloned().unwrap_or_default();
            for s in steps.iter().rev().take(6).rev() {
                println!("   · {}", s.as_str().unwrap_or(""));
            }
            if let Some(m) = r["message"].as_str().filter(|m| !m.is_empty()) {
                println!("   {m}");
            }
        }
    }
    if failed {
        1
    } else {
        0
    }
}

pub fn _unused(_: PathBuf) {}
