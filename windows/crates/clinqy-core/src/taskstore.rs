//! Durable task state for the Tasks window and recovery after a restart. Recovery never executes a stored request: a
//! run that was cut off stays stopped until the user checks what really happened.

use parking_lot::Mutex;
use regex::Regex;
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::sync::OnceLock;

/// Credentials that turn up in typed text (an API key, a token): masked before a request is stored.
pub fn mask(text: &str) -> String {
    static PATTERNS: OnceLock<Vec<Regex>> = OnceLock::new();
    let patterns = PATTERNS.get_or_init(|| {
        [
            r"\b(gh[pousr]_)[A-Za-z0-9]{20,}",
            r"\b(github_pat_)[A-Za-z0-9_]{20,}",
            r"\b(sk-(?:ant-|proj-)?)[A-Za-z0-9_\-]{20,}",
            r"\b(AIza)[A-Za-z0-9_\-]{30,}",
            r"\b(xox[abprs]-)[A-Za-z0-9\-]{10,}",
            r"\b(AKIA)[0-9A-Z]{16}\b",
            r"\b(\d{8,10}:)[A-Za-z0-9_\-]{35}\b",
            r#"(?i)\b((?:aws_secret_access_key|secret|password|passwd|api[_-]?key|token)\s*[=:]\s*)[^\s"',;]{8,}"#,
            r"(?i)\b(bearer\s+)[A-Za-z0-9._\-]{20,}",
        ]
        .iter()
        .filter_map(|p| Regex::new(p).ok())
        .collect()
    });
    let mut out = text.to_string();
    for p in patterns {
        out = p.replace_all(&out, "${1}[redacted]").into_owned();
    }
    out
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Queued,
    Running,
    Waiting,
    NeedsAttention,
    Interrupted,
    Succeeded,
    Failed,
    Cancelled,
}

impl State {
    pub fn terminal(self) -> bool {
        matches!(self, State::Interrupted | State::Succeeded | State::Failed | State::Cancelled)
    }

    pub fn label(self) -> &'static str {
        match self {
            State::Queued => "Queued",
            State::Running => "Running",
            State::Waiting => "Waiting",
            State::NeedsAttention => "Needs attention",
            State::Interrupted => "Interrupted",
            State::Succeeded => "Succeeded",
            State::Failed => "Failed",
            State::Cancelled => "Cancelled",
        }
    }
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Record {
    pub id: String,
    pub request: String,
    #[serde(default)]
    pub files: Vec<String>,
    pub source: String,
    pub background: bool,
    pub state: State,
    pub stage: String,
    #[serde(default)]
    pub completed_steps: usize,
    #[serde(default)]
    pub last_confirmed_step: Option<String>,
    /// Written before an action starts, cleared only after it returns. Holds the kind of action, never its arguments.
    #[serde(default)]
    pub pending_action: Option<String>,
    #[serde(default)]
    pub result: Option<String>,
    pub created_at: String,
    pub updated_at: String,
    #[serde(default)]
    pub requires_review: bool,
    #[serde(default)]
    pub review_reason: Option<String>,
}

impl Record {
    pub fn short_id(&self) -> String {
        self.id.chars().take(8).collect::<String>().to_lowercase()
    }
}

struct Inner {
    records: Vec<Record>,
    /// The file couldn't be read: it's kept as it is, and nothing is saved or started.
    corrupt: bool,
    error: Option<String>,
}

pub struct TaskStore {
    file: PathBuf,
    inner: Mutex<Inner>,
}

const PRIVATE: &str = "Private values were removed from this request. Rewrite it without secrets before running it.";

fn now() -> String {
    chrono::Utc::now().to_rfc3339()
}

pub fn tasks() -> &'static TaskStore {
    static STORE: OnceLock<TaskStore> = OnceLock::new();
    STORE.get_or_init(|| TaskStore::open(crate::paths::data_dir().join("tasks.json")))
}

impl TaskStore {
    pub fn open(file: PathBuf) -> TaskStore {
        let store = TaskStore { file, inner: Mutex::new(Inner { records: vec![], corrupt: false, error: None }) };
        let Ok(text) = std::fs::read_to_string(&store.file) else { return store };
        match serde_json::from_str::<Vec<Record>>(&text) {
            Ok(mut records) => {
                // A waiting question and any approval belong to the old process: never reconstruct one.
                for r in &mut records {
                    match r.state {
                        State::Running | State::Waiting | State::NeedsAttention => {
                            r.state = State::Interrupted;
                            r.stage = "Clinqy stopped before this task finished. Check the real outcome before sending new instructions.".into();
                            r.updated_at = now();
                        }
                        State::Queued => {
                            r.requires_review = true;
                            r.review_reason = Some("Restored after restart. Review the request and files, then start it explicitly.".into());
                        }
                        _ => {}
                    }
                }
                let mut inner = store.inner.lock();
                inner.records = records;
                let saved = save(&store.file, &inner.records);
                if saved.is_err() {
                    inner.error = Some("Couldn't save task state. Work is stopped to preserve safe recovery.".into());
                }
                drop(inner);
                store
            }
            Err(_) => {
                let mut inner = store.inner.lock();
                inner.corrupt = true;
                inner.error = Some("Task history couldn't be read safely. The existing file was preserved; automatic task starts are disabled.".into());
                drop(inner);
                store
            }
        }
    }

    pub fn records(&self) -> Vec<Record> {
        self.inner.lock().records.clone()
    }

    pub fn record(&self, id: &str) -> Option<Record> {
        self.inner.lock().records.iter().find(|r| r.id == id).cloned()
    }

    pub fn error(&self) -> Option<String> {
        self.inner.lock().error.clone()
    }

    pub fn active(&self) -> Option<Record> {
        self.inner.lock().records.iter().rev().find(|r| matches!(r.state, State::Running | State::Waiting | State::NeedsAttention)).cloned()
    }

    pub fn enqueue(&self, request: &str, files: Vec<String>, source: &str, background: bool) -> Option<String> {
        let clean = mask(request);
        let changed = clean != request;
        let id = uuid::Uuid::new_v4().to_string();
        let record = Record {
            id: id.clone(),
            request: clean,
            files,
            source: source.into(),
            background,
            state: State::Queued,
            stage: "Queued".into(),
            completed_steps: 0,
            last_confirmed_step: None,
            pending_action: None,
            result: None,
            created_at: now(),
            updated_at: now(),
            requires_review: changed,
            review_reason: changed.then(|| PRIVATE.to_string()),
        };
        self.mutate(|items| items.push(record)).then_some(id)
    }

    /// Moves a queued task to running; refused while another is active, or when it needs a review it hasn't had.
    pub fn start(&self, id: &str, explicitly_reviewed: bool) -> bool {
        let Some(item) = self.record(id) else { return false };
        if item.state != State::Queued || (item.requires_review && !explicitly_reviewed) || item.review_reason.as_deref().map(|r| r.contains("Private values")).unwrap_or(false) || self.active().is_some() {
            return false;
        }
        if !item.files.iter().all(|f| Path::new(f).exists()) {
            self.update(Some(id), Some(State::Failed), Some("An attached file is missing. Reattach it and send a new task."), None, None);
            return false;
        }
        self.change(id, |r| {
            r.state = State::Running;
            r.stage = "Getting started".into();
            r.requires_review = false;
            r.review_reason = None;
        })
    }

    pub fn update(&self, id: Option<&str>, state: Option<State>, stage: Option<&str>, completed: Option<usize>, background: Option<bool>) -> bool {
        let Some(id) = id else { return true };
        let Some(item) = self.record(id) else { return false };
        if item.state.terminal() {
            return false;
        }
        self.change(id, |r| {
            if let Some(s) = state {
                r.state = s;
            }
            if let Some(s) = stage {
                r.stage = mask(s);
            }
            if let Some(n) = completed {
                r.completed_steps = n;
            }
            if let Some(b) = background {
                r.background = b;
            }
        })
    }

    /// Must succeed before an action runs, otherwise the run stops rather than lose its recovery checkpoint.
    pub fn begin_action(&self, id: Option<&str>, kind: &str) -> bool {
        let Some(id) = id else { return true };
        let Some(item) = self.record(id) else { return false };
        if item.state.terminal() {
            return false;
        }
        self.change(id, |r| {
            r.state = State::Running;
            r.pending_action = Some(kind.to_string());
            r.stage = format!("Working: {kind}");
        })
    }

    pub fn end_action(&self, id: Option<&str>, kind: &str, ok: bool, completed: usize) {
        let Some(id) = id else { return };
        if self.record(id).map(|r| r.state.terminal()).unwrap_or(true) {
            return;
        }
        self.change(id, |r| {
            r.pending_action = None;
            r.completed_steps = completed;
            if ok {
                r.last_confirmed_step = Some(kind.to_string());
            }
        });
    }

    pub fn finish(&self, id: Option<&str>, ok: bool, answer: &str) {
        let Some(id) = id else { return };
        self.change(id, |r| {
            r.state = if answer == "Stopped" {
                State::Cancelled
            } else if ok {
                State::Succeeded
            } else {
                State::Failed
            };
            r.stage = mask(answer);
            r.result = Some(mask(answer));
            // An in-flight checkpoint stays: a stop can race with a side effect.
        });
    }

    pub fn cancel_queued(&self, id: &str) {
        if self.record(id).map(|r| r.state == State::Queued).unwrap_or(false) {
            self.change(id, |r| {
                r.state = State::Cancelled;
                r.stage = "Cancelled before starting".into();
            });
        }
    }

    fn change(&self, id: &str, action: impl FnOnce(&mut Record)) -> bool {
        self.mutate(|items| {
            if let Some(r) = items.iter_mut().find(|r| r.id == id) {
                action(r);
                r.updated_at = now();
            }
        })
    }

    fn mutate(&self, action: impl FnOnce(&mut Vec<Record>)) -> bool {
        let mut inner = self.inner.lock();
        if inner.corrupt {
            return false;
        }
        let previous = inner.records.clone();
        action(&mut inner.records);
        if save(&self.file, &inner.records).is_ok() {
            inner.error = None;
            true
        } else {
            inner.records = previous;
            inner.error = Some("Couldn't save task state. Work is stopped to preserve safe recovery.".into());
            false
        }
    }
}

/// Written whole to a temporary file first: a crash mid-write can't leave half a history.
fn save(file: &Path, records: &[Record]) -> std::io::Result<()> {
    if let Some(dir) = file.parent() {
        std::fs::create_dir_all(dir)?;
    }
    let temp = file.with_extension("json.tmp");
    std::fs::write(&temp, serde_json::to_vec(records)?)?;
    std::fs::rename(&temp, file)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn temp() -> PathBuf {
        let dir = std::env::temp_dir().join(format!("clinqy-task-tests-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        dir.join("tasks.json")
    }

    #[test]
    fn recovery_never_replays() {
        let file = temp();
        let store = TaskStore::open(file.clone());
        let id = store.enqueue("Submit a sample form", vec![], "windows", true).unwrap();
        assert!(store.start(&id, false));
        assert!(store.begin_action(Some(&id), "click"));
        let queued = store.enqueue("Next task", vec![], "windows", true).unwrap();
        let restored = TaskStore::open(file.clone());
        assert_eq!(restored.record(&id).unwrap().state, State::Interrupted);
        assert_eq!(restored.record(&id).unwrap().pending_action.as_deref(), Some("click"));
        assert!(!restored.start(&id, true), "never replays an interrupted submit");
        assert!(!restored.start(&queued, false), "a restored queue needs review");
        assert!(restored.start(&queued, true));
        restored.end_action(Some(&queued), "read", true, 1);
        assert_eq!(restored.record(&queued).unwrap().last_confirmed_step.as_deref(), Some("read"));
        restored.finish(Some(&queued), true, "Complete");
        assert_eq!(TaskStore::open(file).record(&queued).unwrap().state, State::Succeeded);
    }

    #[test]
    fn secrets_and_missing_files() {
        let file = temp();
        let store = TaskStore::open(file.clone());
        let secret = store.enqueue("Use password=hunter2hunter2", vec![], "windows", true).unwrap();
        assert_eq!(store.record(&secret).unwrap().request, "Use password=[redacted]");
        assert!(!store.start(&secret, true), "a redacted request must be rewritten");
        let missing = store.enqueue("Upload", vec![file.with_extension("missing").display().to_string()], "windows", true).unwrap();
        assert!(!store.start(&missing, false));
        assert!(store.active().is_none(), "a missing attachment can't block the queue");
    }

    #[test]
    fn corrupt_storage_fails_closed() {
        let file = temp();
        std::fs::write(&file, "broken").unwrap();
        let store = TaskStore::open(file.clone());
        assert!(store.enqueue("No execution", vec![], "windows", true).is_none());
        assert_eq!(std::fs::read_to_string(&file).unwrap(), "broken", "the original is preserved");
        assert!(store.error().is_some());
    }

    #[test]
    fn one_at_a_time() {
        let store = TaskStore::open(temp());
        let a = store.enqueue("a", vec![], "windows", true).unwrap();
        let b = store.enqueue("b", vec![], "windows", true).unwrap();
        assert!(store.start(&a, false));
        assert!(!store.start(&b, false));
    }
}
