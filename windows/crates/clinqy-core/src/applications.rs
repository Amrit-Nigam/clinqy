//! Job/internship applications Clinqy filled or sent (applications.json), apart from memory.

use crate::history::{CardItem, ResultCard};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Application {
    pub company: String,
    pub role: String,
    #[serde(default)]
    pub url: Option<String>,
    pub date: String,
    /// filled / submitted / emailed / interview / rejected / offer / skipped
    pub status: String,
    #[serde(default)]
    pub resume: Option<String>,
    #[serde(default)]
    pub notes: Option<String>,
}

fn path() -> std::path::PathBuf {
    crate::paths::data_dir().join("applications.json")
}

pub fn all() -> Vec<Application> {
    std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str(&t).ok()).unwrap_or_default()
}

fn save(a: &[Application]) {
    if let Ok(t) = serde_json::to_string_pretty(a) {
        let _ = std::fs::write(path(), t);
    }
}

fn key(s: &str) -> String {
    s.to_lowercase().chars().filter(|c| c.is_alphanumeric()).collect()
}

fn same(e: &Application, company: &str, role: &str, url: Option<&str>) -> bool {
    if let (Some(u), Some(o)) = (url.filter(|u| !u.is_empty()), e.url.as_deref()) {
        if key(u) == key(o) {
            return true;
        }
    }
    key(&e.company) == key(company) && (key(&e.role) == key(role) || role.is_empty())
}

fn day(date: &str) -> String {
    chrono::DateTime::parse_from_rfc3339(date).map(|d| d.with_timezone(&chrono::Local).format("%-d %b %Y").to_string()).unwrap_or_default()
}

pub fn describe(e: &Application) -> String {
    let mut s = format!("{} — {} · {} · {}", e.company, e.role, e.status, day(&e.date));
    for x in [&e.resume, &e.url, &e.notes].into_iter().flatten() {
        s += &format!(" · {x}");
    }
    s
}

/// Adds an application, or updates the one for the same posting.
pub fn record(company: &str, role: &str, url: Option<&str>, status: &str, resume: Option<&str>, notes: Option<&str>) -> String {
    let mut entries = all();
    if let Some(e) = entries.iter_mut().find(|e| same(e, company, role, url)) {
        if !status.is_empty() {
            e.status = status.into();
        }
        if let Some(u) = url.filter(|u| !u.is_empty()) {
            e.url = Some(u.into());
        }
        if let Some(r) = resume {
            e.resume = Some(r.into());
        }
        if let Some(n) = notes {
            e.notes = Some(n.into());
        }
        if !role.is_empty() {
            e.role = role.into();
        }
        let line = format!("updated: {}", describe(e));
        save(&entries);
        return line;
    }
    let e = Application {
        company: company.into(),
        role: role.into(),
        url: url.map(String::from),
        date: chrono::Utc::now().to_rfc3339(),
        status: if status.is_empty() { "filled".into() } else { status.into() },
        resume: resume.map(String::from),
        notes: notes.map(String::from),
    };
    let line = format!("recorded: {}", describe(&e));
    entries.push(e);
    save(&entries);
    line
}

pub fn find(query: &str) -> Vec<Application> {
    let words: Vec<String> = query.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| w.len() >= 3).map(String::from).collect();
    let q = key(query);
    all().into_iter()
        .filter(|e| {
            if let Some(u) = &e.url {
                if !q.is_empty() && (key(u).contains(&q) || q.contains(&key(u))) {
                    return true;
                }
            }
            let hay = format!("{} {} {}", e.company, e.role, e.url.clone().unwrap_or_default()).to_lowercase();
            !words.is_empty() && (words.iter().all(|w| hay.contains(w.as_str())) || words.iter().any(|w| w.len() >= 4 && key(&e.company).contains(w.as_str())))
        })
        .collect()
}

pub fn card() -> ResultCard {
    let mut entries = all();
    entries.sort_by(|a, b| b.date.cmp(&a.date));
    let sent = entries.iter().filter(|e| e.status != "filled" && e.status != "skipped").count();
    ResultCard {
        title: format!("Applications ({})", entries.len()),
        text: if entries.is_empty() {
            "Nothing yet — applications Clinqy fills or sends show up here.".into()
        } else {
            format!("{sent} sent · {} filled but not submitted, or skipped", entries.len() - sent)
        },
        items: entries
            .iter()
            .map(|e| CardItem {
                title: format!("{} — {}", e.company, e.role),
                subtitle: Some(format!("{} · {}{}", e.status, day(&e.date), e.resume.as_ref().map(|r| format!(" · {r}")).unwrap_or_default())),
                detail: e.notes.clone(),
                link: e.url.clone(),
            })
            .collect(),
    }
}
