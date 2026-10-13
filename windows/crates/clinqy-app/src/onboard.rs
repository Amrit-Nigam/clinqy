//! Getting going: picking the model Clinqy uses (and checking it really answers), and connecting coding agents to
//! Clinqy over MCP. Used by `clinqy model`, `clinqy connect` and the tray's Model menu, so a person, a coding agent
//! following the setup prompt, and the tray all do it the same way.

use clinqy_core::provider::Provider;
use std::path::PathBuf;
use std::time::{Duration, Instant};

/// The choices, by the short names people type: (name, provider, what it is), in the order Clinqy picks them
/// when nothing is set.
pub const MODELS: [(&str, Provider, &str); 9] = [
    ("claude", Provider::ClaudeCli, "Claude Code CLI, your Claude login"),
    ("codex", Provider::CodexCli, "Codex CLI, your ChatGPT login"),
    ("agy", Provider::AgyCli, "Antigravity CLI, your Google login"),
    ("ollama", Provider::Ollama, "a local model with Ollama"),
    ("anthropic", Provider::Anthropic, "Anthropic API key"),
    ("openai", Provider::OpenAi, "OpenAI API key"),
    ("gemini", Provider::Gemini, "Gemini API key"),
    ("openrouter", Provider::OpenRouter, "OpenRouter API key"),
    ("compatible", Provider::Compatible, "any OpenAI-compatible server"),
];

pub fn short_name(p: Provider) -> &'static str {
    MODELS.iter().find(|m| m.1 == p).map(|m| m.0).unwrap_or("claude")
}

/// The model the provider really runs (the tier name "sonnet" becomes, for agy, its Gemini model).
pub fn model_label(p: Provider) -> String {
    let m = p.model(&p.default_model());
    if m.is_empty() { "its default".into() } else { m }
}

/// Whether a provider can be used as it is, and if not, exactly what to do.
pub fn readiness(p: Provider) -> Result<String, String> {
    let env = clinqy_core::paths::env_file().display().to_string();
    match p {
        Provider::ClaudeCli => match p.cli() {
            Some(c) => Ok(c.program.display().to_string()),
            None => Err("Claude Code isn't installed. Install it with `winget install Anthropic.ClaudeCode`, then run `claude` once in a new terminal to log in.".into()),
        },
        Provider::AgyCli => match p.cli() {
            Some(c) => Ok(c.program.display().to_string()),
            None => Err("The Antigravity CLI (agy) isn't installed. Install it from https://antigravity.google/docs/cli/overview, then run `agy` once in a new terminal to log in.".into()),
        },
        Provider::CodexCli => match p.cli() {
            Some(c) => Ok(c.program.display().to_string()),
            None => Err("The Codex CLI isn't installed. Install it with `npm i -g @openai/codex`, then run `codex login`.".into()),
        },
        Provider::Ollama => {
            if clinqy_core::provider::reachable(&p.base_url()) {
                Ok(format!("{} · model {}", p.base_url(), p.model("sonnet")))
            } else {
                Err(format!("Ollama isn't running at {}. Install it (winget install Ollama.Ollama), start it, and run `ollama pull {}`.", p.base_url(), p.model("sonnet")))
            }
        }
        Provider::Compatible => match p.key() {
            _ if clinqy_core::config::value("OPENAI_BASE_URL").is_none() => {
                Err(format!("Set OPENAI_BASE_URL (and OPENAI_COMPATIBLE_API_KEY, LOCAL_MODEL) in {env}: run `clinqy settings` to open it."))
            }
            _ => Ok(p.base_url()),
        },
        _ => match p.key() {
            Some(_) => Ok("key set".into()),
            None => {
                let var = match p {
                    Provider::Anthropic => "ANTHROPIC_API_KEY",
                    Provider::OpenAi => "OPENAI_API_KEY",
                    Provider::Gemini => "GEMINI_API_KEY",
                    _ => "OPENROUTER_API_KEY",
                };
                Err(format!("No {var} yet. Run `clinqy settings`, paste your key after `{var}=` (uncomment the line) and save. Don't paste it into a chat."))
            }
        },
    }
}

/// Makes `p` (and optionally a model id) the one Clinqy uses, in the settings file. The app picks it up on its next
/// request.
pub fn choose(p: Provider, model: Option<&str>) -> std::io::Result<()> {
    crate::setup::ensure_env_file();
    clinqy_core::config::set("PROVIDER", p.id())?;
    // An old "use agy" switch would override the choice.
    if clinqy_core::config::value("USE_AGY").is_some() {
        clinqy_core::config::set("USE_AGY", "")?;
    }
    if let Some(m) = model.filter(|m| !m.trim().is_empty()) {
        let key = match p {
            Provider::AgyCli => "AGY_MODEL",
            Provider::Ollama | Provider::Compatible => "LOCAL_MODEL",
            _ => "CLAUDE_MODEL",
        };
        clinqy_core::config::set(key, m.trim())?;
    }
    Ok(())
}

/// Back to automatic: no PROVIDER set, so Clinqy uses what's on the PC (Claude, Codex, agy, Ollama, a key).
pub fn choose_auto() -> std::io::Result<Provider> {
    crate::setup::ensure_env_file();
    clinqy_core::config::set("PROVIDER", "")?;
    if clinqy_core::config::value("USE_AGY").is_some() {
        clinqy_core::config::set("USE_AGY", "")?;
    }
    Ok(Provider::detected())
}

/// Whether the model was picked automatically (nothing set).
pub fn is_auto() -> bool {
    clinqy_core::config::value("PROVIDER").is_none() && clinqy_core::config::value("USE_AGY").is_none()
}

/// Asks the model for one word, to prove the login or key works. Returns how long it took.
pub async fn test(p: Provider) -> Result<Duration, String> {
    let model = p.default_model();
    let t0 = Instant::now();
    let session = clinqy_core::session::Session::start("You are checking that a connection works. Reply with exactly: OK", &model, p).map_err(|e| e.to_string())?;
    let reply = tokio::time::timeout(Duration::from_secs(120), session.send("ping", None, None)).await;
    session.close();
    match reply {
        Err(_) => Err("no answer in 2 minutes".into()),
        Ok(Err(e)) => Err(first_line(&e.to_string())),
        Ok(Ok(text)) if text.trim().is_empty() => Err("it answered with nothing (is it logged in? run it once in a terminal)".into()),
        Ok(Ok(_)) => Ok(t0.elapsed()),
    }
}

fn first_line(s: &str) -> String {
    s.lines().find(|l| !l.trim().is_empty()).unwrap_or(s).chars().take(300).collect()
}

/// The `clinqy` command an agent should start for MCP: the installed copy if there is one, else this one.
pub fn clinqy_exe() -> PathBuf {
    let installed = std::env::var_os("LOCALAPPDATA").map(|d| PathBuf::from(d).join("Programs").join("Clinqy").join("clinqy.exe"));
    if let Some(p) = installed.filter(|p| p.is_file()) {
        return p;
    }
    std::env::current_exe().ok().and_then(|e| e.parent().map(|d| d.join("clinqy.exe"))).filter(|p| p.is_file()).unwrap_or_else(|| PathBuf::from("clinqy.exe"))
}

/// The coding agents `clinqy connect` knows.
pub const AGENTS: [&str; 6] = ["claude", "agy", "cursor", "codex", "gemini", "windsurf"];

/// Adds Clinqy as an MCP server to one coding agent, keeping its other servers. Returns what was done.
pub fn connect(agent: &str) -> Result<String, String> {
    let exe = clinqy_exe();
    let exe_s = exe.display().to_string();
    let home = clinqy_core::paths::home();
    match agent {
        "claude" | "claude-code" => {
            let cli = Provider::ClaudeCli.cli().ok_or("Claude Code isn't installed (winget install Anthropic.ClaudeCode)")?;
            // `add` refuses a name that exists: replace it, so the path is always the current one.
            let _ = run(&cli, &["mcp", "remove", "--scope", "user", "clinqy"]);
            run(&cli, &["mcp", "add", "--scope", "user", "clinqy", "--", &exe_s, "mcp"])?;
            Ok("Claude Code: added the clinqy MCP server for your user (all projects)".into())
        }
        "agy" | "antigravity" => {
            let cli = Provider::AgyCli.cli().ok_or("the Antigravity CLI (agy) isn't installed")?;
            run(&cli, &["mcp", "add", "clinqy", &exe_s, "mcp"])?;
            Ok("agy: added the clinqy MCP server".into())
        }
        "cursor" => json_server(&home.join(".cursor").join("mcp.json"), &exe_s).map(|p| format!("Cursor: added clinqy to {}", p.display())),
        "gemini" | "gemini-cli" => json_server(&home.join(".gemini").join("settings.json"), &exe_s).map(|p| format!("Gemini CLI: added clinqy to {}", p.display())),
        "windsurf" => json_server(&home.join(".codeium").join("windsurf").join("mcp_config.json"), &exe_s).map(|p| format!("Windsurf: added clinqy to {}", p.display())),
        "codex" => {
            let path = home.join(".codex").join("config.toml");
            let text = std::fs::read_to_string(&path).unwrap_or_default();
            let block = format!("[mcp_servers.clinqy]\ncommand = {:?}\nargs = [\"mcp\"]\n", exe_s);
            let out = match text.find("[mcp_servers.clinqy]") {
                // Replace the old block (up to the next table).
                Some(i) => {
                    let rest = &text[i + 1..];
                    let end = rest.find("\n[").map(|j| i + 1 + j + 1).unwrap_or(text.len());
                    format!("{}{}{}", &text[..i], block, &text[end..])
                }
                None => format!("{}{}{}", text, if text.is_empty() || text.ends_with('\n') { "\n" } else { "\n\n" }, block),
            };
            std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
            std::fs::write(&path, out).map_err(|e| e.to_string())?;
            Ok(format!("Codex: added clinqy to {}", path.display()))
        }
        other => Err(format!("I don't know the agent {other:?}; use one of: {}", AGENTS.join(", "))),
    }
}

/// `{"mcpServers": {"clinqy": {...}}}` in a JSON config, keeping everything else.
fn json_server(path: &std::path::Path, exe: &str) -> Result<PathBuf, String> {
    let mut v: serde_json::Value = std::fs::read_to_string(path).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_else(|| serde_json::json!({}));
    if !v.is_object() {
        return Err(format!("{} isn't a JSON object; fix it by hand", path.display()));
    }
    if !v["mcpServers"].is_object() {
        v["mcpServers"] = serde_json::json!({});
    }
    v["mcpServers"]["clinqy"] = serde_json::json!({"command": exe, "args": ["mcp"]});
    std::fs::create_dir_all(path.parent().unwrap()).map_err(|e| e.to_string())?;
    std::fs::write(path, serde_json::to_string_pretty(&v).unwrap()).map_err(|e| e.to_string())?;
    Ok(path.to_path_buf())
}

fn run(cli: &clinqy_core::provider::CliCommand, args: &[&str]) -> Result<(), String> {
    use std::os::windows::process::CommandExt;
    let out = std::process::Command::new(&cli.program)
        .args(&cli.prefix)
        .args(args)
        .creation_flags(clinqy_core::session::CREATE_NO_WINDOW)
        .output()
        .map_err(|e| e.to_string())?;
    if out.status.success() {
        Ok(())
    } else {
        let err = String::from_utf8_lossy(&out.stderr);
        let msg = if err.trim().is_empty() { String::from_utf8_lossy(&out.stdout).into_owned() } else { err.into_owned() };
        Err(first_line(&msg))
    }
}
