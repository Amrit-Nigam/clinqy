//! The user's job-application profile (profile.json, the same fields as the Mac app) and planning a form fill
//! from it: every visible empty field, dropdown and radio group the profile answers becomes one type / choose /
//! click step, run with the agent's usual checked actions.

use crate::page::{Page, PageElement};
use regex::Regex;
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};

#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq)]
pub struct Qa {
    pub question: String,
    pub answer: String,
}

#[derive(Clone, Debug, Serialize, Deserialize, Default, PartialEq)]
#[serde(default)]
pub struct Profile {
    pub name: String,
    pub email: String,
    pub phone: String,
    pub location: String,
    #[serde(rename = "currentCTC")]
    pub current_ctc: String,
    #[serde(rename = "expectedCTC")]
    pub expected_ctc: String,
    #[serde(rename = "noticePeriod")]
    pub notice_period: String,
    #[serde(rename = "experienceYears", skip_serializing_if = "Option::is_none")]
    pub experience_years: Option<i64>,
    #[serde(rename = "experienceMonths", skip_serializing_if = "Option::is_none")]
    pub experience_months: Option<i64>,
    pub linkedin: String,
    pub github: String,
    pub portfolio: String,
    #[serde(rename = "resumePaths")]
    pub resume_paths: Vec<String>,
    #[serde(rename = "workAuthorization")]
    pub work_authorization: String,
    #[serde(rename = "willingToRelocate")]
    pub willing_to_relocate: String,
    pub qa: Vec<Qa>,
}

pub fn path() -> std::path::PathBuf {
    crate::paths::data_dir().join("profile.json")
}

pub fn current() -> Profile {
    if let Some(p) = std::fs::read_to_string(path()).ok().and_then(|t| serde_json::from_str(&t).ok()) {
        return p;
    }
    let p = seed();
    save(&p);
    p
}

pub fn save(p: &Profile) {
    if let Ok(t) = serde_json::to_string_pretty(p) {
        let _ = std::fs::write(path(), t);
    }
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Field {
    ExpectedCtc,
    CurrentCtc,
    Notice,
    Experience,
    Linkedin,
    Github,
    Portfolio,
    Email,
    Phone,
    Relocate,
    Authorization,
    Location,
    Resume,
    FirstName,
    LastName,
    Name,
}

fn has(q: &str, pattern: &str) -> bool {
    Regex::new(pattern).map(|r| r.is_match(q)).unwrap_or(false)
}

/// "with React" (a skill) as opposed to "in total" / "in the industry".
fn about_one_skill(q: &str) -> bool {
    let r = Regex::new(r"\b(?:with|in|using|of working (?:with|on))\s+([a-z0-9.#+]+(?:\s+[a-z]+)?)").unwrap();
    const GENERAL: &[&str] = &["total", "overall", "the industry", "industry", "software", "tech", "work", "years", "year", "months", "month", "yrs"];
    let found = r.captures_iter(q).any(|c| {
        let w = c[1].to_string();
        !GENERAL.iter().any(|g| w.starts_with(g))
    });
    found
}

fn field(question: &str) -> Option<Field> {
    let q = question.to_lowercase();
    let q = q.as_str();
    if has(q, r"\b(expected|desired|expectation)\b.*\b(ctc|salary|stipend|compensation|pay|package)\b|\b(ctc|salary|stipend|compensation)\b.*\bexpect") {
        return Some(Field::ExpectedCtc);
    }
    if has(q, r"\b(current|present|last drawn|existing)\b.*\b(ctc|salary|stipend|compensation|package)\b|^\s*ctc\b") {
        return Some(Field::CurrentCtc);
    }
    if has(q, r"\bnotice\b|\b(join|start)(ing)?\b.*\b(date|when|soon|available|availability)\b|\bhow soon\b") {
        return Some(Field::Notice);
    }
    if has(q, r"\bexperience\b")
        && has(q, r"\b(years?|months?|how (much|long)|total|overall|work|professional|industry)\b")
        && (!about_one_skill(q) || has(q, r"\b(total|overall|work|professional)\s+experience"))
    {
        return Some(Field::Experience);
    }
    if has(q, r"linked\s?in") {
        return Some(Field::Linkedin);
    }
    if has(q, r"git\s?hub") {
        return Some(Field::Github);
    }
    if has(q, r"\b(portfolio|personal (website|site)|website|blog)\b") {
        return Some(Field::Portfolio);
    }
    if has(q, r"e-?mail") {
        return Some(Field::Email);
    }
    if has(q, r"\b(phone|mobile|contact number|whatsapp number|cell)\b") {
        return Some(Field::Phone);
    }
    if has(q, r"relocat") {
        return Some(Field::Relocate);
    }
    if has(q, r"\b(authori[sz]ed|authori[sz]ation|legally (eligible|allowed))\b") && !has(q, r"sponsor|visa") {
        return Some(Field::Authorization);
    }
    if has(q, r"\b(current (city|location)|location|city|where (are you|do you) (based|live)|based in|residing)\b") {
        return Some(Field::Location);
    }
    if has(q, r"\b(resume|cv|curriculum vitae)\b") {
        return Some(Field::Resume);
    }
    if has(q, r"\bfirst name\b|\bgiven name\b") {
        return Some(Field::FirstName);
    }
    if has(q, r"\b(last name|surname|family name)\b") {
        return Some(Field::LastName);
    }
    if has(q, r"\b(full name|your name)|^name|name\s*\*?$") {
        return Some(Field::Name);
    }
    None
}

fn value(f: Field, p: &Profile, question: &str) -> Option<String> {
    let ne = |s: &str| (!s.trim().is_empty()).then(|| s.to_string());
    let q = question.to_lowercase();
    match f {
        Field::ExpectedCtc => ne(&p.expected_ctc),
        Field::CurrentCtc => ne(&p.current_ctc),
        Field::Notice => ne(&p.notice_period),
        Field::Experience => {
            if p.experience_years.is_none() && p.experience_months.is_none() {
                return None;
            }
            let total = p.experience_years.unwrap_or(0) * 12 + p.experience_months.unwrap_or(0);
            if has(&q, r"\bin months\b|\(months\)|number of months|how many months") {
                return Some(total.to_string());
            }
            if has(&q, r"\bin years\b|\(years\)|number of years|how many years|years of") {
                let y = total as f64 / 12.0;
                return Some(if y.fract() == 0.0 { format!("{}", y as i64) } else { format!("{y:.1}") });
            }
            let (y, m) = (total / 12, total % 12);
            let mut parts = vec![];
            if y > 0 {
                parts.push(format!("{y} year{}", if y == 1 { "" } else { "s" }));
            }
            if m > 0 || y == 0 {
                parts.push(format!("{m} month{}", if m == 1 { "" } else { "s" }));
            }
            Some(parts.join(" "))
        }
        Field::Linkedin => ne(&p.linkedin),
        Field::Github => ne(&p.github),
        Field::Portfolio => ne(&p.portfolio),
        Field::Email => ne(&p.email),
        Field::Phone => ne(&p.phone),
        Field::Relocate => ne(&p.willing_to_relocate),
        Field::Authorization => ne(&p.work_authorization),
        Field::Location => ne(&p.location),
        Field::Resume => p.resume_paths.first().cloned(),
        Field::Name => ne(&p.name),
        Field::FirstName => ne(&p.name).and_then(|n| n.split_whitespace().next().map(String::from)),
        Field::LastName => {
            let parts: Vec<&str> = p.name.split_whitespace().collect();
            (parts.len() > 1).then(|| parts[1..].join(" "))
        }
    }
}

const STOP: &[&str] = &["the", "and", "for", "with", "that", "this", "you", "your", "are", "have", "has", "what", "which", "please", "any",
    "our", "from", "into", "will", "would", "can", "did", "does", "do", "how", "why", "about", "enter", "provide", "mention", "a", "an",
    "of", "to", "in", "is", "if", "on", "or", "be", "we", "us", "it"];

fn words(t: &str) -> HashSet<String> {
    t.to_lowercase().split(|c: char| !c.is_alphanumeric()).filter(|w| w.len() >= 2 && !STOP.contains(w)).map(String::from).collect()
}

fn similarity(a: &str, b: &str) -> f64 {
    let (wa, wb) = (words(a), words(b));
    if wa.is_empty() || wb.is_empty() {
        return 0.0;
    }
    let shared = wa.iter().filter(|x| wb.iter().any(|y| x == &y || (x.len().min(y.len()) >= 4 && (x.starts_with(y.as_str()) || y.starts_with(x.as_str()))))).count();
    shared as f64 / wa.union(&wb).count() as f64
}

/// The saved answer to a form question: a close earlier question first, then the matching profile field.
pub fn answer(question: &str, p: &Profile) -> Option<String> {
    let q = question.trim();
    if q.is_empty() {
        return None;
    }
    let best = p.qa.iter().map(|x| (x, similarity(q, &x.question))).max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal));
    if let Some((x, s)) = best {
        if s >= 0.6 && !x.answer.is_empty() {
            return Some(x.answer.clone());
        }
    }
    if let Some(v) = field(q).and_then(|f| value(f, p, q)) {
        return Some(v);
    }
    if let Some((x, s)) = best {
        if s >= 0.45 && !x.answer.is_empty() {
            return Some(x.answer.clone());
        }
    }
    None
}

/// Saves the user's answer: into its profile field while that's empty, else as a Q&A pair.
pub fn remember(question: &str, answer: &str) {
    let (q, a) = (question.trim(), answer.trim());
    if q.is_empty() || a.is_empty() || a.len() >= 2000 {
        return;
    }
    let mut p = current();
    if let Some(f) = field(q) {
        if fill(f, a, &mut p) {
            save(&p);
            return;
        }
    }
    if let Some(i) = p.qa.iter().position(|x| similarity(q, &x.question) >= 0.8) {
        p.qa[i] = Qa { question: q.into(), answer: a.into() };
    } else {
        p.qa.push(Qa { question: q.into(), answer: a.into() });
    }
    save(&p);
}

fn fill(f: Field, a: &str, p: &mut Profile) -> bool {
    fn set(s: &mut String, a: &str) -> bool {
        if s.is_empty() {
            *s = a.to_string();
            true
        } else {
            s == a
        }
    }
    match f {
        Field::ExpectedCtc => set(&mut p.expected_ctc, a),
        Field::CurrentCtc => set(&mut p.current_ctc, a),
        Field::Notice => set(&mut p.notice_period, a),
        Field::Linkedin => set(&mut p.linkedin, a),
        Field::Github => set(&mut p.github, a),
        Field::Portfolio => set(&mut p.portfolio, a),
        Field::Email => set(&mut p.email, a),
        Field::Phone => set(&mut p.phone, a),
        Field::Relocate => set(&mut p.willing_to_relocate, a),
        Field::Authorization => set(&mut p.work_authorization, a),
        Field::Location => set(&mut p.location, a),
        Field::Name => set(&mut p.name, a),
        Field::Resume => {
            if p.resume_paths.iter().any(|r| r == a) {
                return true;
            }
            if !p.resume_paths.is_empty() {
                return false;
            }
            p.resume_paths.push(a.into());
            true
        }
        Field::Experience => {
            if p.experience_years.is_some() || p.experience_months.is_some() {
                return false;
            }
            match parse_experience(a) {
                Some((y, m)) => {
                    p.experience_years = Some(y);
                    p.experience_months = Some(m);
                    true
                }
                None => false,
            }
        }
        Field::FirstName | Field::LastName => false,
    }
}

/// "1 year 6 months", "8 months", "1.5 years", "2" → (years, months).
pub fn parse_experience(text: &str) -> Option<(i64, i64)> {
    let t = text.to_lowercase();
    let num = |unit: &str| {
        Regex::new(&format!(r"(\d+(?:\.\d+)?)\s*{unit}")).ok()?.captures(&t).and_then(|c| c[1].parse::<f64>().ok())
    };
    let (y, m) = (num(r"(?:years?|yrs?)\b"), num(r"(?:months?|mos?)\b"));
    let total = if y.is_none() && m.is_none() {
        (t.trim().parse::<f64>().ok()? * 12.0).round() as i64
    } else {
        (y.unwrap_or(0.0) * 12.0 + m.unwrap_or(0.0)).round() as i64
    };
    Some((total / 12, total % 12))
}

/// The profile in a few compact lines for the model ("" when nothing is saved).
pub fn prompt_block() -> String {
    let p = current();
    let mut parts = vec![];
    let mut add = |l: &str, v: &str| {
        if !v.trim().is_empty() {
            parts.push(format!("{l}: {v}"));
        }
    };
    add("Name", &p.name);
    add("Email", &p.email);
    add("Phone", &p.phone);
    add("Location", &p.location);
    add("Current CTC", &p.current_ctc);
    add("Expected CTC", &p.expected_ctc);
    add("Notice period", &p.notice_period);
    if p.experience_years.is_some() || p.experience_months.is_some() {
        parts.push(format!("Experience: {}y {}m", p.experience_years.unwrap_or(0), p.experience_months.unwrap_or(0)));
    }
    let mut add = |l: &str, v: &str| {
        if !v.trim().is_empty() {
            parts.push(format!("{l}: {v}"));
        }
    };
    add("LinkedIn", &p.linkedin);
    add("GitHub", &p.github);
    add("Portfolio", &p.portfolio);
    if !p.resume_paths.is_empty() {
        parts.push(format!("Resume: {}", p.resume_paths.join(" | ")));
    }
    let mut add = |l: &str, v: &str| {
        if !v.trim().is_empty() {
            parts.push(format!("{l}: {v}"));
        }
    };
    add("Work authorization", &p.work_authorization);
    add("Relocate", &p.willing_to_relocate);
    if parts.is_empty() && p.qa.is_empty() {
        return String::new();
    }
    let mut text = format!("Job-application profile (use these in forms, don't ask for them):\n{}", parts.join(" · "));
    if !p.qa.is_empty() {
        text += "\nSaved answers to earlier form questions:\n";
        let start = p.qa.len().saturating_sub(40);
        text += &p.qa[start..].iter().map(|x| format!("- {} → {}", x.question, x.answer.chars().take(300).collect::<String>())).collect::<Vec<_>>().join("\n");
    }
    text
}

/// First-run profile, mined from memory facts. Anything not found stays empty.
fn seed() -> Profile {
    let facts = crate::memory::facts();
    let first = |pattern: &str, pool: &[String], group: usize| -> Option<String> {
        let r = Regex::new(&format!("(?i){pattern}")).ok()?;
        pool.iter().find_map(|f| r.captures(f).and_then(|c| c.get(group)).map(|m| m.as_str().trim_matches(|c| " .;,'\"".contains(c)).to_string()))
    };
    let filter = |p: &str| -> Vec<String> {
        let r = Regex::new(p).unwrap();
        facts.iter().filter(|f| r.is_match(f)).cloned().collect()
    };
    let email = r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}";
    let mut p = Profile { name: whoami_full_name(), ..Default::default() };
    p.email = first(email, &filter(r"(?i)personal"), 0).or_else(|| first(email, &filter(r"(?i)\be-?mail\b"), 0)).unwrap_or_default();
    p.phone = first(r"\+?\d[\d \-]{8,}\d", &filter(r"(?i)\b(phone|mobile)\b"), 0).unwrap_or_default();
    p.linkedin = first(r"(https?://)?(www\.)?linkedin\.com/in/[A-Za-z0-9_-]+/?", &facts, 0).unwrap_or_default();
    p.github = first(r"github\.com/[A-Za-z0-9_-]+", &filter(r"(?i)^(his |my )?github (is|username is)"), 0).map(|g| format!("https://{g}")).unwrap_or_default();
    p.portfolio = first(r"portfolio is ([^\s,;]+)", &facts, 1).unwrap_or_default();
    p.location = first(r"(current location[^:]*:|based in|lives in)\s*([^;.]+)", &facts, 2).unwrap_or_default();
    p.notice_period = first(r"notice period[^:]*(is|:)\s*([^;.]+)", &facts, 2).unwrap_or_default();
    p.current_ctc = first(r"current (ctc|salary|stipend)[^:]*(is|:)\s*([^;.]+)", &facts, 3).unwrap_or_default();
    p.expected_ctc = first(r"(expect\w*|desired) (stipend|salary|ctc)[^₹\d]*([₹$]?\s?[\d,]+[^;.]*?)(;|\.|$)", &facts, 3).unwrap_or_default();
    if let Some((y, m)) = first(r"total experience[^\d]*([^;(]+)", &facts, 1).and_then(|e| parse_experience(&e)) {
        p.experience_years = Some(y);
        p.experience_months = Some(m);
    }
    p
}

/// The user's display name (Windows account full name, else the user name).
pub fn whoami_full_name() -> String {
    static NAME: std::sync::OnceLock<String> = std::sync::OnceLock::new();
    NAME.get_or_init(|| {
        if let Some(n) = crate::config::value("USER_FULL_NAME") {
            return n;
        }
        std::env::var("USERNAME").unwrap_or_default()
    })
    .clone()
}

/// Lets the platform supply the real display name once (it needs an OS call).
pub fn set_full_name(name: &str) {
    if !name.trim().is_empty() {
        std::env::set_var("USER_FULL_NAME", name.trim());
    }
}

// MARK: - Form fill plan

pub struct Step {
    pub action: Map<String, Value>,
    pub question: String,
    pub answer: String,
}

#[derive(Default)]
pub struct Plan {
    pub steps: Vec<Step>,
    pub open: Vec<String>,
    pub uploads: usize,
}

const TEXT_ROLES: &[&str] = &["text", "email", "tel", "url", "number", "textarea", "textbox", "combobox", "input"];

pub fn label(el: &PageElement) -> String {
    let star = Regex::new(r"\s*\*\s*$").unwrap();
    for s in [&el.question, &Some(el.text.clone()), &el.placeholder] {
        let t = star.replace(s.as_deref().unwrap_or(""), "").trim().to_string();
        if !t.is_empty() {
            return t;
        }
    }
    String::new()
}

fn is_placeholder(o: &str) -> bool {
    o.trim().is_empty() || has(o, r"(?i)^\s*(-+|select\b.*|choose\b.*|please select.*|pick\b.*|none selected|--.*)\s*$")
}

fn is_unset(v: &Option<String>) -> bool {
    match v.as_deref().map(str::trim) {
        None | Some("") => true,
        Some(v) => v == "(nothing chosen)" || is_placeholder(v),
    }
}

/// The option a saved answer means, or None when none fits.
pub fn best_option(answer: &str, options: &[String]) -> Option<String> {
    let a = answer.to_lowercase();
    let a = a.trim();
    let opts: Vec<&String> = options.iter().filter(|o| !o.trim().is_empty()).collect();
    let low = |o: &str| o.to_lowercase().trim().to_string();
    if let Some(h) = opts.iter().find(|o| low(o) == a) {
        return Some((*h).clone());
    }
    if a.len() >= 4 {
        if let Some(h) = opts.iter().find(|o| low(o).starts_with(a) || (low(o).len() >= 4 && a.starts_with(&low(o)))) {
            return Some((*h).clone());
        }
    }
    if a.len() >= 3 {
        if let Some(h) = opts.iter().find(|o| crate::memory::has_word(a, &low(o)) || (low(o).len() >= 3 && crate::memory::has_word(&low(o), a))) {
            return Some((*h).clone());
        }
    }
    for word in ["yes", "no"] {
        if a == word || [" ", ",", "."].iter().any(|s| a.starts_with(&format!("{word}{s}"))) {
            if let Some(h) = opts.iter().find(|o| words(o).contains(word) && words(o).len() <= 4) {
                return Some((*h).clone());
            }
        }
    }
    let numbers = |t: &str| t.split(|c: char| !c.is_ascii_digit()).filter(|s| !s.is_empty()).map(String::from).collect::<HashSet<_>>();
    let na = numbers(a);
    let wa = words(a);
    opts.iter()
        .filter(|o| na.is_empty() || numbers(o) == na)
        .map(|o| {
            let wo = words(o);
            let s = if wa.is_empty() || wo.is_empty() { 0.0 } else { wa.intersection(&wo).count() as f64 / wa.len().min(wo.len()) as f64 };
            ((*o).clone(), s)
        })
        .filter(|x| x.1 >= 0.6)
        .max_by(|a, b| a.1.partial_cmp(&b.1).unwrap_or(std::cmp::Ordering::Equal))
        .map(|x| x.0)
}

pub fn plan(page: &Page, answer_for: impl Fn(&str) -> Option<String>) -> Plan {
    let mut plan = Plan::default();
    let mut groups: HashMap<String, Vec<&PageElement>> = HashMap::new();
    let mut order: Vec<String> = vec![];
    let mut asked = HashSet::new();
    let req = |el: &PageElement| if el.has_flag("required") { " (required)" } else { "" };
    for el in page.elements.iter().filter(|e| !e.has_flag("disabled")) {
        let role = el.role.to_lowercase();
        if role == "file" {
            plan.uploads += 1;
            continue;
        }
        if role == "radio" {
            let q = el.question.clone().unwrap_or_default();
            if q.is_empty() {
                continue;
            }
            if !groups.contains_key(&q) {
                order.push(q.clone());
            }
            groups.entry(q).or_default().push(el);
            continue;
        }
        let question = label(el);
        if question.is_empty() {
            continue;
        }
        if role == "select" || el.dropdown {
            if !is_unset(&el.value) {
                continue;
            }
            let choices: Vec<String> = el.options.iter().filter(|o| !is_placeholder(o)).cloned().collect();
            let Some(a) = answer_for(&question) else {
                plan.open.push(format!("{question}{}", req(el)));
                continue;
            };
            let Some(option) = best_option(&a, &choices) else {
                plan.open.push(format!("{question}{} — saved answer “{a}” isn't one of the options", req(el)));
                continue;
            };
            plan.steps.push(Step { action: obj(json!({"do": "choose", "id": format!("w{}", el.index), "option": option})), question, answer: option });
        } else if el.editable && TEXT_ROLES.contains(&role.as_str()) {
            if !el.value.as_deref().unwrap_or("").trim().is_empty() || !asked.insert(question.to_lowercase()) {
                continue;
            }
            let Some(a) = answer_for(&question) else {
                plan.open.push(format!("{question}{}", req(el)));
                continue;
            };
            let action = if role == "combobox" {
                json!({"do": "choose", "id": format!("w{}", el.index), "option": a})
            } else {
                json!({"do": "type", "id": format!("w{}", el.index), "text": a})
            };
            plan.steps.push(Step { action: obj(action), question, answer: a });
        }
    }
    for q in order {
        let group = &groups[&q];
        if group.iter().any(|e| e.has_flag("checked")) {
            continue;
        }
        let required = group.iter().any(|e| e.has_flag("required"));
        let Some(a) = answer_for(&q) else {
            plan.open.push(format!("{q}{}", if required { " (required)" } else { "" }));
            continue;
        };
        let texts: Vec<String> = group.iter().map(|e| e.text.clone()).collect();
        match best_option(&a, &texts).and_then(|o| group.iter().find(|e| e.text == o).map(|e| (o, e.index))) {
            Some((option, index)) => plan.steps.push(Step { action: obj(json!({"do": "click", "id": format!("w{index}")})), question: q, answer: option }),
            None => plan.open.push(format!("{q} — saved answer “{a}” isn't one of: {}", texts.join(" | "))),
        }
    }
    plan
}

fn obj(v: Value) -> Map<String, Value> {
    v.as_object().cloned().unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fields() {
        assert_eq!(field("Expected CTC (LPA)"), Some(Field::ExpectedCtc));
        assert_eq!(field("Total years of experience"), Some(Field::Experience));
        assert_eq!(field("Years of experience with React"), None);
        assert_eq!(field("LinkedIn URL"), Some(Field::Linkedin));
        assert_eq!(field("First name"), Some(Field::FirstName));
    }

    #[test]
    fn options() {
        let o = vec!["Select".to_string(), "0-6 months".into(), "8 months".into(), "18 months".into()];
        assert_eq!(best_option("8 months", &o).as_deref(), Some("8 months"));
        let yn = vec!["Yes, I am".to_string(), "No".into()];
        assert_eq!(best_option("yes", &yn).as_deref(), Some("Yes, I am"));
        assert_eq!(parse_experience("1 year 6 months"), Some((1, 6)));
        assert_eq!(parse_experience("1.5"), Some((1, 6)));
    }
}
