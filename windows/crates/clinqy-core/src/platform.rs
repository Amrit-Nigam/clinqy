//! What the agent needs from the operating system, as traits. `clinqy-windows` implements them with UI Automation,
//! SendInput, screen capture and WinRT OCR; another OS (or a test double) can implement them the same way.
//! Coordinates are physical screen pixels, top-left origin, across all monitors.

use async_trait::async_trait;
use std::path::{Path, PathBuf};

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

impl Point {
    pub fn new(x: f64, y: f64) -> Point {
        Point { x, y }
    }
    pub fn distance(self, o: Point) -> f64 {
        ((self.x - o.x).powi(2) + (self.y - o.y).powi(2)).sqrt()
    }
}

#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub w: f64,
    pub h: f64,
}

impl Rect {
    pub fn new(x: f64, y: f64, w: f64, h: f64) -> Rect {
        Rect { x, y, w, h }
    }
    pub fn max_x(&self) -> f64 {
        self.x + self.w
    }
    pub fn max_y(&self) -> f64 {
        self.y + self.h
    }
    pub fn mid_x(&self) -> f64 {
        self.x + self.w / 2.0
    }
    pub fn mid_y(&self) -> f64 {
        self.y + self.h / 2.0
    }
    pub fn center(&self) -> Point {
        Point::new(self.mid_x(), self.mid_y())
    }
    pub fn is_empty(&self) -> bool {
        self.w <= 0.0 || self.h <= 0.0
    }
    pub fn contains(&self, p: Point) -> bool {
        p.x >= self.x && p.x <= self.max_x() && p.y >= self.y && p.y <= self.max_y()
    }
    pub fn intersects(&self, o: &Rect) -> bool {
        !self.intersection(o).is_empty()
    }
    pub fn intersection(&self, o: &Rect) -> Rect {
        let x = self.x.max(o.x);
        let y = self.y.max(o.y);
        let w = self.max_x().min(o.max_x()) - x;
        let h = self.max_y().min(o.max_y()) - y;
        if w <= 0.0 || h <= 0.0 {
            Rect::default()
        } else {
            Rect::new(x, y, w, h)
        }
    }
    pub fn inset(&self, d: f64) -> Rect {
        Rect::new(self.x + d, self.y + d, (self.w - 2.0 * d).max(0.0), (self.h - 2.0 * d).max(0.0))
    }
}

/// A running app's main window as Clinqy sees it. `started` (process start time) tells a relaunch apart from the
/// process the model saw, since pids get reused.
#[derive(Clone, Debug, PartialEq, Eq, Hash, Default)]
pub struct AppRef {
    pub pid: u32,
    pub hwnd: isize,
    /// What a person calls it ("Google Chrome", "WhatsApp", "File Explorer").
    pub name: String,
    /// The executable file name, lowercase ("chrome.exe").
    pub exe: String,
    pub started: u64,
}

/// One control in the front window, from UI Automation.
#[derive(Clone, Debug, Default)]
pub struct Element {
    /// Positional id in this scan ("e12").
    pub id: String,
    /// "Button", "Edit", "CheckBox", "ListItem"…
    pub role: String,
    pub label: String,
    pub rect: Rect,
    /// Current value of inputs and toggles (never a password field's).
    pub value: Option<String>,
    /// Content-derived ref (survives a sibling appearing): lets a re-scan find the same control.
    pub stable: String,
    /// Lives in a dialog over the window (listed first).
    pub in_dialog: bool,
    /// Opaque handle the platform resolves back to the live control.
    pub handle: u64,
}

impl Element {
    pub fn short_label(&self) -> String {
        self.label.chars().take(32).collect()
    }
    pub fn describe(&self) -> String {
        format!("{} {:?}", self.role, self.label.chars().take(60).collect::<String>())
    }
    pub fn is_input(&self) -> bool {
        is_input_role(&self.role)
    }
}

pub fn is_input_role(role: &str) -> bool {
    matches!(role, "Edit" | "ComboBox" | "Document" | "SearchBox" | "TextField" | "TextArea")
}

#[derive(Clone, Debug, Default)]
pub struct Dialog {
    pub kind: String,
    pub title: String,
}

/// The front window, read once per turn.
#[derive(Clone, Debug, Default)]
pub struct Scan {
    pub elements: Vec<Element>,
    pub fingerprint: u64,
    pub window: String,
    pub focused: String,
    pub dialog: Option<Dialog>,
}

/// The element with keyboard focus.
#[derive(Clone, Debug, Default)]
pub struct Focus {
    pub role: String,
    pub value: Option<String>,
    pub secure: bool,
    pub rect: Option<Rect>,
    pub pid: u32,
    pub handle: u64,
    pub text_input: bool,
}

/// A screenshot of a window: the image, the screen area it shows, and its size in pixels.
#[derive(Clone, Debug)]
pub struct Shot {
    pub png: Vec<u8>,
    pub area: Rect,
    pub width: u32,
    pub height: u32,
}

/// A line or word of recognised text and where it is on screen.
#[derive(Clone, Debug)]
pub struct TextBox {
    pub text: String,
    pub rect: Rect,
}

#[derive(Clone, Debug, Default)]
pub struct FileQuery {
    pub words: Option<String>,
    /// pdf, image, video, audio, document, spreadsheet, presentation, archive, folder, or an extension.
    pub kind: Option<String>,
    /// Who sent it or the site it came from.
    pub from: Option<String>,
    pub days: Option<u32>,
    pub folder: Option<PathBuf>,
    pub limit: usize,
}

#[derive(Clone, Debug)]
pub struct FileHit {
    pub path: PathBuf,
    pub size: u64,
    /// Local time, "yyyy-mm-dd HH:MM".
    pub modified: String,
    pub from: Option<String>,
}

#[derive(Clone, Copy, Debug)]
pub enum WindowOp {
    Move(Point),
    Resize(f64, f64),
    Minimize,
    Restore,
    Maximize(bool),
    Close,
    Raise,
}

/// The companion cursor's state, shown by its colour and motion.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Mood {
    Idle,
    Listening,
    Thinking,
    Acting,
    Success,
    Failure,
}

/// The companion cursor: a glowing arrow that rides beside the pointer, flies to targets, frames and marks them.
#[async_trait]
pub trait Buddy: Send + Sync {
    /// Flies to `to` (framing `framing` when given); returns when it has arrived.
    async fn travel(&self, to: Point, framing: Option<Rect>);
    /// A click ripple where it is.
    fn click(&self);
    /// Circles `rect` with an arrow and a short label, for the user to see.
    async fn mark(&self, rect: Rect, label: Option<&str>);
    fn clear_mark(&self);
    fn clear_highlight(&self);
    /// A small speech bubble (None hides it).
    fn bubble(&self, text: Option<&str>, seconds: f64);
    fn set_mood(&self, mood: Mood);
    fn set_typing(&self, on: bool);
    fn set_level(&self, level: f32);
    /// Back beside the pointer.
    fn go_home(&self);
    /// A QA check's result: a green pop or a red shake.
    fn signal(&self, pass: bool);
    fn set_qa(&self, on: bool);
}

/// The operating system, as the agent uses it. Methods that move the visible cursor or pace themselves like a
/// person are async; quick reads are plain calls.
#[async_trait]
pub trait Platform: Send + Sync {
    // Apps and windows.
    fn front_app(&self) -> Option<AppRef>;
    fn running_apps(&self) -> Vec<String>;
    fn is_same_process(&self, app: &AppRef) -> bool;
    fn is_browser(&self, app: &AppRef) -> bool;
    fn default_browser(&self) -> Option<String>;
    fn user_name(&self) -> String;
    /// The app that took the foreground after acting on `from` (a link opening the browser), if any.
    fn handoff(&self, from: &AppRef) -> Option<AppRef>;
    async fn bring_to_front(&self, app: &AppRef) -> bool;
    /// Opens an app the way a person does (taskbar, else Start search), returning it once its window is up.
    async fn open_app(&self, name: &str) -> Option<AppRef>;
    /// Goes to a website like a person: the browser in front, a new tab (or the address bar), type, Enter.
    async fn open_url(&self, url: &str, current: Option<&AppRef>, new_tab: bool) -> Option<AppRef>;
    async fn window(&self, app: &AppRef, op: WindowOp, title: Option<&str>) -> (bool, String);
    async fn menu(&self, app: &AppRef, path: &str) -> (bool, String);
    /// The file the window has open, when it can tell.
    fn document_path(&self, app: &AppRef) -> Option<PathBuf>;

    // Reading.
    async fn scan(&self, app: &AppRef, limit: usize) -> Scan;
    async fn fingerprint(&self, app: &AppRef) -> u64;
    /// Where the browser's page is drawn on screen.
    async fn web_area(&self, app: &AppRef) -> Option<Rect>;
    fn element_rect(&self, handle: u64) -> Option<Rect>;
    fn element_value(&self, handle: u64) -> Option<String>;
    /// The focused element of `app` (or anywhere, with None).
    fn focus(&self, app: Option<&AppRef>) -> Option<Focus>;
    fn dialog_in_front(&self, app: &AppRef) -> bool;
    /// Why a click at `point` would land on something other than `pid`'s window, if it would.
    fn hit_mismatch(&self, point: Point, pid: u32) -> Option<String>;
    async fn screenshot(&self, app: &AppRef) -> Option<Shot>;
    /// A screenshot for the model: the window as a base64 JPEG, scaled down, with red boxes tagged by e-id. Its
    /// geometry is kept so `screen_point` can map the model's x/y back to the screen.
    /// `circled`: a loop the user drew on screen before asking, drawn on the screenshot as they drew it.
    async fn look(&self, app: &AppRef, elements: &[Element], circled: Option<&[Point]>) -> Option<String>;
    /// A point on the last screenshot (image pixels) as a screen point, and the image-to-screen scale.
    fn screen_point(&self, x: f64, y: f64) -> Option<Point>;
    fn shot_scale(&self) -> f64;
    async fn ocr(&self, app: &AppRef) -> Option<Vec<TextBox>>;
    async fn ocr_image(&self, png: &[u8]) -> Option<String>;
    async fn selected_text(&self, app: &AppRef) -> Option<String>;
    /// Ctrl+A, Ctrl+C in the front app: all of a document's text (clipboard restored).
    async fn copy_all(&self, app: &AppRef) -> Option<String>;

    // Acting.
    /// Clicks an element: an Automation pattern first (exact, no pointer move), a real click if that did nothing.
    /// Ok(method) or Err(why it didn't click).
    async fn click_element(&self, handle: u64, app: &AppRef, fingerprint: u64) -> Result<String, String>;
    /// A real click at a screen point, the buddy travelling there first; `pid` guards against clicking another app.
    async fn click_at(&self, point: Point, pid: Option<u32>) -> Result<(), String>;
    async fn focus_element(&self, handle: u64, app: &AppRef) -> Result<(), String>;
    fn invoke(&self, handle: u64) -> bool;
    fn set_element_value(&self, handle: u64, text: &str) -> bool;
    /// Replaces the focused field's text, typed at a human rhythm, and confirms it landed.
    async fn type_text(&self, text: &str, app: &AppRef) -> Result<(), String>;
    /// Types into whatever has focus (line breaks as Shift+Enter).
    async fn enter_text(&self, text: &str, code_editor: bool);
    /// A key or chord ("ctrl+shift+t", "enter"). Err for unknown keys.
    fn press(&self, combo: &str) -> Result<(), String>;
    fn paste(&self, text: &str);
    fn select_all(&self);
    async fn scroll(&self, app: &AppRef, up: bool);
    /// Keys go only while this app is in front (None clears).
    fn set_target(&self, app: Option<&AppRef>);
    /// The real pointer and the front app, noted at a run's start and put back at its end.
    fn begin_run(&self);
    fn end_run(&self, keep_front_app: bool);

    // Clipboard.
    fn clipboard_text(&self) -> Option<String>;
    fn set_clipboard_text(&self, text: &str);
    fn set_clipboard_png(&self, png: &[u8]) -> bool;
    fn clipboard_files(&self) -> Vec<PathBuf>;
    fn clipboard_sequence(&self) -> u32;

    // Files.
    /// Searches the file index (name and content words, a kind, where it was downloaded from, how recent).
    async fn search_files(&self, query: &FileQuery) -> Vec<FileHit>;
    /// Moves files to the Recycle Bin; how many went.
    fn trash(&self, paths: &[PathBuf]) -> Result<usize, String>;

    // System.
    fn mic_in_use(&self) -> bool;
    fn screen_locked(&self) -> bool;
    async fn shell(&self, command: &str, timeout_secs: u64) -> (i32, String);
    fn reveal(&self, paths: &[PathBuf]);
    fn open_path(&self, path: &Path) -> bool;
    fn open_url_direct(&self, url: &str) -> bool;
}
