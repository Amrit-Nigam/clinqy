//! Background jobs the model can hand off instead of clicking through windows: the application tracker, PDFs,
//! video/audio, email and the calendar (Outlook, when it's installed), reminders, files, tables, schedules.

use super::run::{ActionResult, Ctx, RunState};
use super::*;
use crate::files;
use crate::platform::FileQuery;
use crate::reply::{Action, ActionExt};

/// A PowerShell single-quoted string.
pub(crate) fn ps(s: &str) -> String {
    format!("'{}'", s.replace('\'', "''"))
}

const OUTLOOK: &str = "$ErrorActionPreference='Stop'; try { $o = New-Object -ComObject Outlook.Application } catch { 'NO_OUTLOOK'; exit 3 }";

impl Agent {
    pub(crate) async fn task_action(self: &Arc<Self>, kind: &str, action: &Action, ctx: &mut Ctx, rs: &mut RunState) -> ActionResult {
        match kind {
            "application" => self.application(action),
            "pdf" => {
                let Some(op) = action.str("op").map(|o| o.to_lowercase()) else { return ActionResult::fail("pdf needs op") };
                let files = paths(action);
                let line = self.begin(&format!("PDF: {} {}", op.replace('_', " "), describe_files(&files)));
                let opts = action.clone();
                let r = tokio::task::spawn_blocking(move || crate::pdf::run(&op, &files, &opts)).await.unwrap_or_else(|e| Err(e.to_string()));
                self.end(line, r.map(ActionResult::ok).unwrap_or_else(ActionResult::fail))
            }
            "media" => {
                let Some(op) = action.str("op").map(|o| o.to_lowercase()) else { return ActionResult::fail("media needs op") };
                let files = paths(action);
                let title = format!("Video: {} {}", op.replace('_', " "), describe_files(&files));
                let line = self.begin(&title);
                let me = self.clone();
                let t2 = title.clone();
                let r = crate::media::run(&op, &files, action, move |p| {
                    me.progress();
                    me.set_step(line, StepState::Running, Some(&format!("{t2} · {}%", (p * 100.0) as u32)));
                })
                .await;
                self.set_step(line, StepState::Running, Some(&title));
                self.end(line, r.map(ActionResult::ok).unwrap_or_else(ActionResult::fail))
            }
            "email" => self.email(action, rs).await,
            "extract" => self.extract(action, ctx).await,
            "table" => self.table(action, ctx).await,
            "event" | "calendar" => self.event(action, rs).await,
            "reminder" => self.reminder(action),
            "files" => self.files(action, rs).await,
            "schedule" => {
                let (Some(req), Some(when)) = (action.str("request").filter(|r| !r.is_empty()), action.str("when")) else {
                    return ActionResult::fail("schedule needs request and when");
                };
                let line = self.begin(&format!("Schedule: {}", req.chars().take(40).collect::<String>()));
                match crate::scheduler::add(req, when) {
                    Some(s) => self.end(line, ActionResult::ok(format!("{s} (Clinqy runs it then, if the PC is on and Clinqy is running)"))),
                    None => self.end(
                        line,
                        ActionResult::fail(format!("couldn't read {when:?} as a time; say it like \"at 9am\", \"tomorrow 8:30\", \"in 20 minutes\", \"every weekday at 9\" or \"every hour\"")),
                    ),
                }
            }
            _ => ActionResult::fail(format!("unknown action {kind:?}")),
        }
    }

    fn application(&self, action: &Action) -> ActionResult {
        let op = action.str("op").unwrap_or("find").to_lowercase();
        let (company, role) = (action.str("company").unwrap_or(""), action.str("role").unwrap_or(""));
        let link = action.str("url");
        match op.as_str() {
            "find" | "check" => {
                let query = action.string("query").unwrap_or_else(|| format!("{company} {role} {}", link.unwrap_or("")));
                let hits = crate::applications::find(&query);
                ActionResult::ok(if hits.is_empty() {
                    format!("no earlier application matches {query:?}")
                } else {
                    format!("already in the tracker:\n{}", hits.iter().map(|h| format!("- {}", crate::applications::describe(h))).collect::<Vec<_>>().join("\n"))
                })
            }
            "list" | "show" => {
                let card = crate::applications::card();
                let plain = card.plain();
                self.push_step(&format!("Showed {}", card.title), StepState::Info);
                self.current.lock().run_result = Some(card.clone());
                self.show_card(card);
                ActionResult::ok(format!("tracker shown to the user:\n{}", plain.chars().take(3000).collect::<String>()))
            }
            _ => {
                if company.is_empty() {
                    return ActionResult::fail("application record needs company (and role)");
                }
                let s = crate::applications::record(company, role, link, action.str("status").unwrap_or(""), action.str("resume"), action.str("notes"));
                self.push_step(&format!("Tracked: {company} — {role}"), StepState::Info);
                ActionResult::ok(s)
            }
        }
    }

    async fn email(&self, action: &Action, rs: &mut RunState) -> ActionResult {
        let (to, cc) = (action.list("to"), action.list("cc"));
        let files: Vec<PathBuf> = action.list("files").iter().map(|f| crate::paths::expand(f)).collect();
        if to.is_empty() || !to.iter().all(|a| a.contains('@')) {
            return ActionResult::fail("email needs to: real email addresses (recall or ask for them)");
        }
        if let Some(missing) = files.iter().find(|f| !f.exists()) {
            return ActionResult::fail(format!("no such file: {}", missing.display()));
        }
        let draft = action.flag("draft");
        let subject = action.string("subject").unwrap_or_else(|| files.first().and_then(|f| f.file_stem()).map(|s| s.to_string_lossy().into_owned()).unwrap_or_default());
        let body = action.str("body").unwrap_or("");
        // An address the user never gave may come from a page trying to steer Clinqy: confirm those.
        let known = [rs.request.clone(), self.context.lock().selected_text.clone().unwrap_or_default()]
            .into_iter()
            .chain(rs.user_answers.iter().cloned())
            .chain(crate::memory::facts())
            .collect::<Vec<_>>()
            .join("\n")
            .to_lowercase();
        let strangers: Vec<String> = to.iter().chain(cc.iter()).filter(|a| !known.contains(&a.to_lowercase())).cloned().collect();
        if !draft && !strangers.is_empty() {
            let reply = self.ask_user(&format!("Send this to {}? That address came from what I read, not from you.", strangers.join(", ")), vec!["Yes, send it".into(), "No".into()], false).await;
            if !reply.map(|r| crate::safety::is_yes(&r)).unwrap_or(false) {
                return ActionResult::fail(format!("the user didn't confirm sending to {}; don't send it", strangers.join(", ")));
            }
            rs.user_answers.push(strangers.join(" "));
        }
        if !draft && !self.confirm_risky("Send email", rs).await {
            return ActionResult::fail("the user said not to send it");
        }
        let line = self.begin(&format!(
            "{} {}{}",
            if draft { "Draft" } else { "Email" },
            to.join(", "),
            if files.is_empty() { String::new() } else { format!(" · {} attachment{}", files.len(), if files.len() == 1 { "" } else { "s" }) }
        ));
        let script = format!(
            "{OUTLOOK}; $m = $o.CreateItem(0); $m.To = {}; $m.CC = {}; $m.Subject = {}; $m.Body = {}; {} {}",
            ps(&to.join("; ")),
            ps(&cc.join("; ")),
            ps(&subject),
            ps(body),
            files.iter().map(|f| format!("[void]$m.Attachments.Add({});", ps(&f.display().to_string()))).collect::<String>(),
            if draft { "$m.Display(); 'DRAFT'" } else { "$m.Send(); 'SENT'" }
        );
        let (status, out) = self.platform.shell(&script, 60).await;
        if status == 0 && (out.contains("SENT") || out.contains("DRAFT")) {
            return self.end(line, ActionResult::ok(if draft { "draft open in Outlook for the user to review".to_string() } else { format!("sent from Outlook to {}", to.join(", ")) }));
        }
        if out.contains("NO_OUTLOOK") || status == 3 {
            // No desktop Outlook: a draft in the default mail app (attachments can't ride along a mailto: link).
            let url = format!(
                "mailto:{}?subject={}&body={}{}",
                to.join(","),
                enc(&subject),
                enc(body),
                if cc.is_empty() { String::new() } else { format!("&cc={}", cc.join(",")) }
            );
            if draft && files.is_empty() && self.platform.open_url_direct(&url) {
                return self.end(line, ActionResult::ok("draft opened in the default mail app for the user to review"));
            }
            return self.end(
                line,
                ActionResult::fail("desktop Outlook isn't installed, so I can't send mail in the background. Send it through their webmail in the browser instead (Gmail: open_url https://mail.google.com, Outlook: https://outlook.live.com), attaching files with upload"),
            );
        }
        self.end(line, ActionResult::fail(format!("Outlook couldn't send: {}", out.chars().take(300).collect::<String>())))
    }

    async fn extract(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let line = self.begin("Extract data");
        if let Some(path) = action.str("path").or_else(|| action.str("file")) {
            let p = crate::paths::expand(path);
            let ext = p.extension().map(|e| e.to_string_lossy().to_lowercase()).unwrap_or_default();
            if ext == "csv" || ext == "tsv" {
                if let Some(rows) = files::read_delimited(&p) {
                    let shown: Vec<String> = rows.iter().take(500).map(|r| r.join(" | ")).collect();
                    return self.end(line, ActionResult::ok(format!("{}: {} rows\n{}", crate::paths::display(&p), rows.len(), shown.join("\n"))));
                }
            }
            return match files::read_text(&p).await {
                Some(t) => self.end(line, ActionResult::ok(format!("text of {} (pick out the rows/fields yourself):\n{t}", crate::paths::display(&p)))),
                None => self.end(line, ActionResult::fail(format!("couldn't read {path}"))),
            };
        }
        if let Some(page) = ctx.page.clone() {
            let b = crate::bridge::bridge();
            let tables = b.perform("tables", &page, serde_json::json!({}), 8.0).await.ok().and_then(|r| r["tables"].as_array().cloned()).unwrap_or_default();
            if !tables.is_empty() {
                return self.end(
                    line,
                    ActionResult::ok(format!(
                        "{} table{} on {:?}:\n{}",
                        tables.len(),
                        if tables.len() == 1 { "" } else { "s" },
                        page.title.chars().take(60).collect::<String>(),
                        files::describe_tables(&tables).chars().take(15000).collect::<String>()
                    )),
                );
            }
            let text = b.perform("read", &page, serde_json::json!({}), 8.0).await.ok().and_then(|r| r["text"].as_str().map(String::from)).unwrap_or(page.text.clone());
            return self.end(line, ActionResult::ok(format!("no tables on the page; its text (pick out the rows yourself):\n{}", text.chars().take(12000).collect::<String>())));
        }
        if let Some(app) = ctx.app.clone() {
            if let Some(doc) = self.platform.document_path(&app) {
                if let Some(t) = files::read_text(&doc).await {
                    return self.end(line, ActionResult::ok(format!("text of {} (pick out the rows/fields yourself):\n{t}", crate::paths::display(&doc))));
                }
            }
            if let Some(boxes) = self.platform.ocr(&app).await {
                let t = boxes.iter().map(|b| b.text.as_str()).collect::<Vec<_>>().join("\n");
                return self.end(line, ActionResult::ok(format!("text on screen (pick out the rows yourself):\n{}", t.chars().take(12000).collect::<String>())));
            }
        }
        self.end(line, ActionResult::fail("nothing to extract from here; give path, or open the page/file first"))
    }

    async fn table(&self, action: &Action, ctx: &mut Ctx) -> ActionResult {
        let Some(raw) = action.get("rows").and_then(|r| r.as_array()).filter(|r| !r.is_empty()) else {
            return ActionResult::fail("table needs rows: [[\"header\", …], [\"value\", …]]");
        };
        let rows: Vec<Vec<String>> = raw
            .iter()
            .map(|r| {
                r.as_array()
                    .map(|c| c.iter().map(|v| v.as_str().map(String::from).unwrap_or_else(|| if v.is_null() { String::new() } else { v.to_string() })).collect())
                    .unwrap_or_default()
            })
            .collect();
        let to = action.str("to").unwrap_or("csv").to_lowercase();
        let line = self.begin(&format!("Table → {to} ({} rows)", rows.len()));
        match to.as_str() {
            "clipboard" => {
                self.platform.set_clipboard_text(&files::to_tsv(&rows));
                self.end(line, ActionResult::ok(format!("copied {} rows as tab-separated text: click the first cell of a spreadsheet and press ctrl+v", rows.len())))
            }
            "excel" | "numbers" | "spreadsheet" | "sheet" => {
                let title = action.string("title").unwrap_or_else(|| "Clinqy table".into());
                let path = action.str("path").map(crate::paths::expand).unwrap_or_else(|| crate::paths::home().join("Documents").join(format!("{title}.csv")));
                match files::write_csv(&rows, &path, false) {
                    Ok((s, written)) => {
                        self.platform.open_path(&written);
                        tokio::time::sleep(Duration::from_millis(1500)).await;
                        ctx.app = self.platform.front_app();
                        self.refresh(ctx).await;
                        self.end(line, ActionResult::ok(format!("{s}, and opened it in the spreadsheet app")))
                    }
                    Err(e) => self.end(line, ActionResult::fail(e)),
                }
            }
            _ => {
                let path = action.str("path").map(crate::paths::expand).unwrap_or_else(|| crate::paths::home().join("Documents").join("Clinqy table.csv"));
                match files::write_csv(&rows, &path, action.flag("append")) {
                    Ok((s, _)) => self.end(line, ActionResult::ok(s)),
                    Err(e) => self.end(line, ActionResult::fail(e)),
                }
            }
        }
    }

    async fn event(&self, action: &Action, rs: &mut RunState) -> ActionResult {
        let op = action.str("op").unwrap_or("create").to_lowercase();
        let line = self.begin(&if op == "create" || op == "add" {
            format!("Calendar: {}", action.str("title").unwrap_or("event").chars().take(40).collect::<String>())
        } else {
            format!("Calendar: {op}")
        });
        if (op == "delete" || op == "remove") && !self.confirm_risky("Delete event", rs).await {
            return self.end(line, ActionResult::fail("the user said not to delete it"));
        }
        let day_range = |from: Option<&str>, to: Option<&str>| -> Option<(String, String)> {
            let f = crate::when::parse_local(from?)?;
            let t = to.and_then(crate::when::parse_local).unwrap_or(f + chrono::Duration::days(1));
            Some((f.format("%Y-%m-%d %H:%M").to_string(), t.format("%Y-%m-%d %H:%M").to_string()))
        };
        let list_script = |from: &str, to: &str, query: Option<&str>| {
            format!(
                "{OUTLOOK}; $ns = $o.GetNamespace('MAPI'); $it = $ns.GetDefaultFolder(9).Items; $it.IncludeRecurrences = $true; $it.Sort('[Start]'); $f = [datetime]{}; $t = [datetime]{}; $r = $it.Restrict(\"[Start] < '\" + $t.ToString('g') + \"' AND [End] > '\" + $f.ToString('g') + \"'\"); foreach ($i in $r) {{ {} \"$($i.Start.ToString('yyyy-MM-dd HH:mm'))|$($i.End.ToString('yyyy-MM-dd HH:mm'))|$($i.Subject)|$($i.Location)|$($i.EntryID)\" }}",
                ps(from),
                ps(to),
                query.map(|q| format!("if ($i.Subject -notlike {}) {{ continue }};", ps(&format!("*{q}*")))).unwrap_or_default()
            )
        };
        let parse_rows = |out: &str| -> Vec<(String, String, String, String, String)> {
            out.lines()
                .filter_map(|l| {
                    let p: Vec<&str> = l.splitn(5, '|').collect();
                    (p.len() == 5).then(|| (p[0].into(), p[1].into(), p[2].into(), p[3].into(), p[4].into()))
                })
                .collect()
        };
        let no_outlook = "there's no desktop Outlook calendar on this PC; use the calendar in the browser instead (Google Calendar: open_url https://calendar.google.com, Outlook: https://outlook.live.com/calendar)";
        match op.as_str() {
            "create" | "add" => {
                let Some(title) = action.str("title") else { return self.end(line, ActionResult::fail("event needs title and start")) };
                let Some(start_s) = action.str("start") else { return self.end(line, ActionResult::fail("event needs start (\"yyyy-MM-dd HH:mm\")")) };
                let Some(start) = crate::when::parse_local(start_s) else { return self.end(line, ActionResult::fail(format!("can't read start {start_s:?}; use \"yyyy-MM-dd HH:mm\""))) };
                let all_day = crate::when::is_date_only(start_s);
                let minutes = action
                    .str("end")
                    .and_then(crate::when::parse_local)
                    .map(|e| (e - start).num_minutes())
                    .or(action.num("minutes").map(|m| m as i64))
                    .unwrap_or(if all_day { 1440 } else { 30 })
                    .max(5);
                let script = format!(
                    "{OUTLOOK}; $a = $o.CreateItem(1); $a.Subject = {}; $a.Start = [datetime]{}; $a.Duration = {minutes}; $a.Location = {}; $a.Body = {}; {} $a.ReminderSet = $true; $a.Save(); 'CREATED ' + $a.EntryID",
                    ps(title),
                    ps(&start.format("%Y-%m-%d %H:%M").to_string()),
                    ps(action.str("location").unwrap_or("")),
                    ps(action.str("notes").unwrap_or("")),
                    if all_day { "$a.AllDayEvent = $true;" } else { "" }
                );
                let (status, out) = self.platform.shell(&script, 45).await;
                let when = if all_day { start.format("%a %-d %b (all day)").to_string() } else { start.format("%a %-d %b, %H:%M").to_string() };
                if status == 0 && out.contains("CREATED") {
                    return self.end(line, ActionResult::ok(format!("added “{title}” to the Outlook calendar on {when} ({minutes} min)")));
                }
                // No Outlook: an .ics file opened in the default calendar app, which offers to save it.
                let ics = ics_event(title, start, minutes, action.str("location").unwrap_or(""), action.str("notes").unwrap_or(""), all_day);
                let path = std::env::temp_dir().join(format!("{}.ics", title.chars().filter(|c| c.is_alphanumeric() || *c == ' ').collect::<String>()));
                if std::fs::write(&path, ics).is_ok() && self.platform.open_path(&path) {
                    return self.end(line, ActionResult::ok(format!("opened “{title}” ({when}) in the default calendar app, which asks to save it: click its Save button (look first)")));
                }
                self.end(line, ActionResult::fail(no_outlook))
            }
            "list" | "find" | "search" => {
                let now = chrono::Local::now();
                let (from, to) = day_range(action.str("from"), action.str("to")).unwrap_or((now.format("%Y-%m-%d 00:00").to_string(), (now + chrono::Duration::days(7)).format("%Y-%m-%d 00:00").to_string()));
                let (status, out) = self.platform.shell(&list_script(&from, &to, action.str("query")), 45).await;
                if status != 0 || out.contains("NO_OUTLOOK") {
                    return self.end(line, ActionResult::fail(no_outlook));
                }
                let rows = parse_rows(&out);
                self.end(
                    line,
                    ActionResult::ok(if rows.is_empty() {
                        format!("no events between {from} and {to}")
                    } else {
                        format!("events {from} → {to}:\n{}", rows.iter().map(|r| format!("- {} → {} {}{} (id {})", r.0, &r.1[11..], r.2, if r.3.is_empty() { String::new() } else { format!(" @ {}", r.3) }, r.4)).collect::<Vec<_>>().join("\n"))
                    }),
                )
            }
            "free" | "busy" => {
                let day = action.str("day").or(action.str("from")).and_then(crate::when::parse_local).unwrap_or_else(chrono::Local::now);
                let (h0, h1) = (action.num("from_hour").unwrap_or(9.0) as u32, action.num("to_hour").unwrap_or(18.0) as u32);
                let date = day.format("%Y-%m-%d").to_string();
                let (from, to) = (format!("{date} {h0:02}:00"), format!("{date} {h1:02}:00"));
                let (status, out) = self.platform.shell(&list_script(&from, &to, None), 45).await;
                if status != 0 || out.contains("NO_OUTLOOK") {
                    return self.end(line, ActionResult::fail(no_outlook));
                }
                let rows = parse_rows(&out);
                let mut gaps = vec![];
                let mut cursor = from.clone();
                for r in &rows {
                    if r.0 > cursor {
                        gaps.push(format!("{}–{}", &cursor[11..], std::cmp::min(&r.0[11..], &to[11..])));
                    }
                    if r.1 > cursor {
                        cursor = r.1.clone();
                    }
                }
                if cursor < to {
                    gaps.push(format!("{}–{}", &cursor[11..], &to[11..]));
                }
                self.end(
                    line,
                    ActionResult::ok(format!(
                        "{date} {h0:02}:00–{h1:02}:00 · busy: {} · free: {}",
                        if rows.is_empty() { "nothing".to_string() } else { rows.iter().map(|r| format!("{}–{} {}", &r.0[11..], &r.1[11..], r.2)).collect::<Vec<_>>().join(", ") },
                        if gaps.is_empty() { "nothing".to_string() } else { gaps.join(", ") }
                    )),
                )
            }
            "delete" | "remove" => {
                let Some(id) = action.str("id") else { return self.end(line, ActionResult::fail("event delete needs id (from event list)")) };
                let (status, out) = self.platform.shell(&format!("{OUTLOOK}; $o.GetNamespace('MAPI').GetItemFromID({}).Delete(); 'DELETED'", ps(id)), 30).await;
                if status == 0 && out.contains("DELETED") {
                    self.end(line, ActionResult::ok("deleted the event"))
                } else {
                    self.end(line, ActionResult::fail(if out.contains("NO_OUTLOOK") { no_outlook.to_string() } else { format!("couldn't delete it: {}", out.chars().take(200).collect::<String>()) }))
                }
            }
            _ => self.end(line, ActionResult::fail("event op: create, list, find, free or delete")),
        }
    }

    fn reminder(&self, action: &Action) -> ActionResult {
        use crate::scheduler::{reminders, save_reminders, Reminder};
        let op = action.str("op").unwrap_or("create").to_lowercase();
        match op.as_str() {
            "create" | "add" => {
                let Some(title) = action.str("title") else { return ActionResult::fail("reminder needs title") };
                let due = action.str("due").and_then(crate::when::parse_local);
                if action.str("due").is_some() && due.is_none() {
                    return ActionResult::fail("can't read due; use \"yyyy-MM-dd HH:mm\"");
                }
                let line = self.begin(&format!("Reminder: {}", title.chars().take(40).collect::<String>()));
                let mut all = reminders();
                all.push(Reminder {
                    id: uuid::Uuid::new_v4().to_string(),
                    title: title.into(),
                    due: due.map(|d| d.to_rfc3339()),
                    notes: action.string("notes"),
                    done: false,
                    shown: false,
                });
                save_reminders(&all);
                self.end(
                    line,
                    ActionResult::ok(match due {
                        Some(d) => format!("reminder “{title}” set for {} (Clinqy pops it up then, while it's running)", d.format("%a %-d %b, %H:%M")),
                        None => format!("reminder “{title}” added (no time)"),
                    }),
                )
            }
            "list" => {
                let open: Vec<Reminder> = reminders().into_iter().filter(|r| !r.done).collect();
                ActionResult::ok(if open.is_empty() {
                    "no open reminders".to_string()
                } else {
                    open.iter()
                        .map(|r| format!("- {}{} (id {})", r.title, r.due.as_deref().and_then(crate::when::parse_local).map(|d| format!(" · {}", d.format("%a %-d %b %H:%M"))).unwrap_or_default(), &r.id[..8]))
                        .collect::<Vec<_>>()
                        .join("\n")
                })
            }
            "complete" | "done" => {
                let key = action.str("id").or(action.str("title")).unwrap_or("").to_lowercase();
                let mut all = reminders();
                let Some(r) = all.iter_mut().find(|r| !r.done && (r.id.starts_with(&key) || r.title.to_lowercase().contains(&key))) else {
                    return ActionResult::fail("no open reminder like that");
                };
                r.done = true;
                let t = r.title.clone();
                save_reminders(&all);
                ActionResult::ok(format!("checked off “{t}”"))
            }
            _ => ActionResult::fail("reminder op: create, list or complete"),
        }
    }

    async fn files(&self, action: &Action, rs: &mut RunState) -> ActionResult {
        let op = action.str("op").unwrap_or("find").to_lowercase();
        let folder = action.str("folder").map(crate::paths::expand);
        match op.as_str() {
            "find" | "search" => {
                let query = action.string("query");
                let line = self.begin(&format!("Find files{}", query.as_ref().map(|q| format!(": {}", q.chars().take(30).collect::<String>())).unwrap_or_default()));
                let hits = self
                    .platform
                    .search_files(&FileQuery {
                        words: query,
                        kind: action.string("kind"),
                        from: action.string("from"),
                        days: action.num("days").map(|d| d as u32),
                        folder,
                        limit: action.num("limit").unwrap_or(20.0).min(50.0) as usize,
                    })
                    .await;
                self.end(
                    line,
                    ActionResult::ok(if hits.is_empty() {
                        "no files match (try fewer words, another kind, or more days)".to_string()
                    } else {
                        format!(
                            "{} files, newest first:\n{}",
                            hits.len(),
                            hits.iter()
                                .map(|h| format!("- {} · {} · {}{}", h.path.display(), files::bytes(h.size), h.modified, h.from.as_ref().map(|f| format!(" · from {}", f.chars().take(80).collect::<String>())).unwrap_or_default()))
                                .collect::<Vec<_>>()
                                .join("\n")
                        )
                    }),
                )
            }
            "list" => {
                let Some(folder) = folder else { return ActionResult::fail("files list needs folder") };
                let line = self.begin(&format!("List {}", folder.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()));
                let r = files::list(&folder, &action.str("sort").unwrap_or("date").to_lowercase(), 60);
                self.end(line, r.map(ActionResult::ok).unwrap_or_else(ActionResult::fail))
            }
            "rename" | "move" => {
                let mut pairs = vec![];
                if op == "rename" {
                    for r in action.get("renames").and_then(|v| v.as_array()).cloned().unwrap_or_default() {
                        let (Some(from), Some(to)) = (r["from"].as_str(), r["to"].as_str().filter(|t| !t.is_empty())) else { continue };
                        let from = crate::paths::expand(from);
                        let to = if to.contains(['/', '\\']) { crate::paths::expand(to) } else { from.with_file_name(to) };
                        pairs.push((from, to));
                    }
                } else {
                    let Some(dest) = action.str("to").map(crate::paths::expand) else { return ActionResult::fail("files move needs to (a folder)") };
                    pairs = paths_key(action, "files").into_iter().map(|f| {
                        let name = f.file_name().map(|n| n.to_os_string()).unwrap_or_default();
                        (f, dest.join(name))
                    }).collect();
                }
                if pairs.is_empty() {
                    return ActionResult::fail(if op == "rename" { "files rename needs renames: [{\"from\": path, \"to\": \"new name\"}]" } else { "files move needs files" });
                }
                let line = self.begin(&format!("{} {} file{}", if op == "rename" { "Rename" } else { "Move" }, pairs.len(), if pairs.len() == 1 { "" } else { "s" }));
                let (done, skipped) = files::apply(&pairs);
                self.end(
                    line,
                    ActionResult {
                        ok: !done.is_empty(),
                        summary: format!(
                            "{} {}: {}{}. (files undo puts them back)",
                            if op == "rename" { "renamed" } else { "moved" },
                            done.len(),
                            done.iter().take(30).map(|(f, t)| format!("{} → {}", f.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default(), t.display())).collect::<Vec<_>>().join("; "),
                            if skipped.is_empty() { String::new() } else { format!(". Skipped: {}", skipped.join("; ")) }
                        ),
                        look: false,
                    },
                )
            }
            "organize" | "sort" | "tidy" => {
                let target = folder.unwrap_or_else(|| crate::paths::home().join("Downloads"));
                let apply = action.flag("apply");
                let line = self.begin(&format!("{} {}", if apply { "Sort" } else { "Plan sorting" }, target.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()));
                let plan = match files::organize_plan(&target) {
                    Ok(p) => p,
                    Err(e) => return self.end(line, ActionResult::fail(e)),
                };
                if plan.is_empty() {
                    return self.end(line, ActionResult::ok(format!("nothing to sort in {}", target.display())));
                }
                let mut counts: std::collections::BTreeMap<String, usize> = Default::default();
                for (_, to) in &plan {
                    *counts.entry(to.parent().and_then(|p| p.file_name()).map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()).or_default() += 1;
                }
                let groups = counts.iter().map(|(k, v)| format!("{k}: {v}")).collect::<Vec<_>>().join(", ");
                if !apply {
                    return self.end(line, ActionResult::ok(format!("plan for {} ({} files into subfolders): {groups}. Nothing moved yet — confirm with the user, then files organize with apply:true.", target.display(), plan.len())));
                }
                let (done, skipped) = files::apply(&plan);
                self.end(
                    line,
                    ActionResult::ok(format!(
                        "sorted {} files in {} into {groups}{}. (files undo puts them back)",
                        done.len(),
                        target.display(),
                        if skipped.is_empty() { String::new() } else { format!(". Skipped: {}", skipped.iter().take(10).cloned().collect::<Vec<_>>().join("; ")) }
                    )),
                )
            }
            "undo" => {
                let line = self.begin("Undo the last file changes");
                self.end(line, files::undo().map(ActionResult::ok).unwrap_or_else(ActionResult::fail))
            }
            "trash" | "delete" => {
                let urls = paths_key(action, "files");
                if urls.is_empty() {
                    return ActionResult::fail("files trash needs files");
                }
                let line = self.begin(&format!("Move {} to the Recycle Bin", urls.len()));
                if !self.confirm_risky("Move to Trash", rs).await {
                    return self.end(line, ActionResult::fail("the user said not to delete them"));
                }
                let existing: Vec<PathBuf> = urls.into_iter().filter(|p| p.exists()).collect();
                if existing.is_empty() {
                    return self.end(line, ActionResult::fail("none of those files exist"));
                }
                match self.platform.trash(&existing) {
                    Ok(n) => self.end(line, ActionResult::ok(format!("moved {n} of {} to the Recycle Bin (recoverable from there)", existing.len()))),
                    Err(e) => self.end(line, ActionResult::fail(e)),
                }
            }
            "reveal" | "show" => {
                let urls: Vec<PathBuf> = paths_key(action, "files").into_iter().filter(|p| p.exists()).collect();
                if urls.is_empty() {
                    return ActionResult::fail("files reveal needs files that exist");
                }
                let line = self.begin("Show in File Explorer");
                self.platform.reveal(&urls);
                self.end(line, ActionResult::ok(format!("selected {} in a File Explorer window", urls.len())))
            }
            _ => ActionResult::fail("files op: find, list, rename, move, organize, undo, trash or reveal"),
        }
    }
}

fn paths(a: &Action) -> Vec<PathBuf> {
    let mut v = paths_key(a, "files");
    if v.is_empty() {
        v = paths_key(a, "file");
    }
    v
}

fn paths_key(a: &Action, key: &str) -> Vec<PathBuf> {
    a.list(key).iter().map(|p| crate::paths::expand(p)).collect()
}

fn describe_files(f: &[PathBuf]) -> String {
    if f.len() == 1 {
        f[0].file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
    } else {
        format!("{} files", f.len())
    }
}

fn enc(s: &str) -> String {
    s.bytes()
        .map(|b| match b {
            b'A'..=b'Z' | b'a'..=b'z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => (b as char).to_string(),
            _ => format!("%{b:02X}"),
        })
        .collect()
}

fn ics_event(title: &str, start: chrono::DateTime<chrono::Local>, minutes: i64, location: &str, notes: &str, all_day: bool) -> String {
    let esc = |s: &str| s.replace('\\', "\\\\").replace(';', "\\;").replace(',', "\\,").replace('\n', "\\n");
    let utc = |d: chrono::DateTime<chrono::Local>| d.with_timezone(&chrono::Utc).format("%Y%m%dT%H%M%SZ").to_string();
    let end = start + chrono::Duration::minutes(minutes);
    let (ds, de) = if all_day {
        (format!("DTSTART;VALUE=DATE:{}", start.format("%Y%m%d")), format!("DTEND;VALUE=DATE:{}", (start + chrono::Duration::days(1)).format("%Y%m%d")))
    } else {
        (format!("DTSTART:{}", utc(start)), format!("DTEND:{}", utc(end)))
    };
    format!(
        "BEGIN:VCALENDAR\r\nVERSION:2.0\r\nPRODID:-//Clinqy//EN\r\nBEGIN:VEVENT\r\nUID:{}@clinqy\r\nDTSTAMP:{}\r\n{ds}\r\n{de}\r\nSUMMARY:{}\r\nLOCATION:{}\r\nDESCRIPTION:{}\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n",
        uuid::Uuid::new_v4(),
        utc(chrono::Local::now()),
        esc(title),
        esc(location),
        esc(notes)
    )
}
