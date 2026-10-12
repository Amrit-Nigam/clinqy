//! Skills learned by watching the user (Watch & learn), in skills.json, the same shape as the Mac app.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Skill {
    #[serde(default = "new_id")]
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub parameters: Vec<String>,
    pub steps: Vec<String>,
    #[serde(default)]
    pub created: String,
}

fn new_id() -> String {
    uuid::Uuid::new_v4().to_string()
}

fn path() -> std::path::PathBuf {
    crate::paths::data_dir().join("skills.json")
}

pub fn all() -> Vec<Skill> {
    std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

pub fn save(all: &[Skill]) {
    if let Ok(t) = serde_json::to_string_pretty(all) {
        let _ = std::fs::write(path(), t);
    }
}

pub fn remove(id: &str) {
    save(&all().into_iter().filter(|s| s.id != id).collect::<Vec<_>>());
}

pub fn add(skill: Skill) {
    let mut a = all();
    a.insert(0, skill);
    save(&a);
}

/// How skills are described to the agent.
pub fn prompt_text() -> String {
    all().iter()
        .take(15)
        .map(|s| {
            format!(
                "- {}: {}{}\n  Steps: {}",
                s.name,
                s.summary,
                if s.parameters.is_empty() { String::new() } else { format!(" (needs: {})", s.parameters.join(", ")) },
                s.steps.iter().enumerate().map(|(i, x)| format!("{}. {x}", i + 1)).collect::<Vec<_>>().join(" ")
            )
        })
        .collect::<Vec<_>>()
        .join("\n")
}

/// The prompt that turns a recording into a skill.
pub const LEARN_SYSTEM: &str = "You turn a recording of what a Windows user did into a reusable skill that an assistant operating the PC can follow later. Reply with JSON only (no tool calls, no prose):\n{\"name\":\"<3-6 word name, imperative>\",\"summary\":\"<one sentence>\",\"parameters\":[\"<things that would change next time, e.g. repo name, recipient, message>\"],\"steps\":[\"<clear step using app/button/field names, with parameters written as {parameter}>\"]}\nDrop accidental or redundant actions (stray clicks, corrections). Keep app names and exact button/field labels.";

/// Turns a recording into a skill with a one-off model session.
pub async fn learn(recording: &[String]) -> Result<Skill, String> {
    if recording.len() < 2 {
        return Err("That was too short to learn from".into());
    }
    let provider = crate::provider::Provider::current();
    let session = crate::session::Session::start(LEARN_SYSTEM, &provider.default_model(), provider).map_err(|e| e.to_string())?;
    let text = format!("Recording:\n{}", recording.iter().enumerate().map(|(i, r)| format!("{}. {r}", i + 1)).collect::<Vec<_>>().join("\n"));
    let reply = session.send(&text, None, None).await.map_err(|e| e.to_string())?;
    let json = crate::reply::parse(&reply).ok_or("Couldn't make sense of that recording")?;
    let name = json.get("name").and_then(|v| v.as_str()).ok_or("Couldn't make sense of that recording")?.to_string();
    let steps: Vec<String> = json.get("steps").and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect()).unwrap_or_default();
    if steps.is_empty() {
        return Err("Couldn't make sense of that recording".into());
    }
    let skill = Skill {
        id: new_id(),
        name,
        summary: json.get("summary").and_then(|v| v.as_str()).unwrap_or("").into(),
        parameters: json.get("parameters").and_then(|v| v.as_array()).map(|a| a.iter().filter_map(|s| s.as_str().map(String::from)).collect()).unwrap_or_default(),
        steps,
        created: chrono::Utc::now().to_rfc3339(),
    };
    add(skill.clone());
    Ok(skill)
}
