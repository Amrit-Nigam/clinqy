#![allow(non_upper_case_globals)]
//! UI Automation: the front window's controls, read in as few cross-process calls as possible (a cached subtree
//! per window; for browsers, the browser's own controls only — the page comes from the extension, and reaching
//! into web content would switch the browser's slower accessibility mode on). Elements are handed out as numeric
//! handles that resolve back to live controls for clicking, focusing and setting values.

use crate::com;
use clinqy_core::platform::{Dialog, Element, Focus, Rect, Scan};
use parking_lot::Mutex;
use std::collections::{HashMap, HashSet, VecDeque};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;
use windows::core::{Interface, BSTR, VARIANT};
use windows::Win32::Foundation::{HWND, POINT, RECT};
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_INPROC_SERVER};
use windows::Win32::UI::Accessibility::*;

pub struct Uia {
    pub automation: IUIAutomation,
    handles: Mutex<HashMap<u64, IUIAutomationElement>>,
    next: AtomicU64,
}

// UI Automation's client objects are free-threaded (they live in the multithreaded apartment).
unsafe impl Send for Uia {}
unsafe impl Sync for Uia {}

pub fn uia() -> &'static Uia {
    static U: OnceLock<Uia> = OnceLock::new();
    U.get_or_init(|| {
        com::ensure();
        let automation: IUIAutomation = unsafe {
            CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER)
                .or_else(|_| CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER))
                .expect("UI Automation is unavailable")
        };
        // A hung app mustn't hang Clinqy: cap how long any call may wait.
        if let Ok(a2) = automation.cast::<IUIAutomation2>() {
            unsafe {
                let _ = a2.SetConnectionTimeout(1500);
                let _ = a2.SetTransactionTimeout(3000);
            }
        }
        Uia { automation, handles: Mutex::new(HashMap::new()), next: AtomicU64::new(1) }
    })
}

/// A friendly role name for a control type.
pub fn role_name(ct: UIA_CONTROLTYPE_ID) -> &'static str {
    match ct {
        UIA_ButtonControlTypeId => "Button",
        UIA_HyperlinkControlTypeId => "Link",
        UIA_EditControlTypeId => "Edit",
        UIA_CheckBoxControlTypeId => "CheckBox",
        UIA_RadioButtonControlTypeId => "RadioButton",
        UIA_ComboBoxControlTypeId => "ComboBox",
        UIA_MenuItemControlTypeId => "MenuItem",
        UIA_MenuBarControlTypeId => "MenuBar",
        UIA_MenuControlTypeId => "Menu",
        UIA_TabItemControlTypeId => "TabItem",
        UIA_TabControlTypeId => "Tab",
        UIA_ListItemControlTypeId => "ListItem",
        UIA_ListControlTypeId => "List",
        UIA_TreeItemControlTypeId => "TreeItem",
        UIA_TreeControlTypeId => "Tree",
        UIA_DataItemControlTypeId => "DataItem",
        UIA_DataGridControlTypeId => "DataGrid",
        UIA_TextControlTypeId => "Text",
        UIA_ImageControlTypeId => "Image",
        UIA_DocumentControlTypeId => "Document",
        UIA_SplitButtonControlTypeId => "SplitButton",
        UIA_SliderControlTypeId => "Slider",
        UIA_SpinnerControlTypeId => "Spinner",
        UIA_HeaderControlTypeId => "Header",
        UIA_HeaderItemControlTypeId => "HeaderItem",
        UIA_GroupControlTypeId => "Group",
        UIA_PaneControlTypeId => "Pane",
        UIA_WindowControlTypeId => "Window",
        UIA_ToolBarControlTypeId => "ToolBar",
        UIA_StatusBarControlTypeId => "StatusBar",
        UIA_TitleBarControlTypeId => "TitleBar",
        UIA_ScrollBarControlTypeId => "ScrollBar",
        UIA_ProgressBarControlTypeId => "ProgressBar",
        UIA_ToolTipControlTypeId => "ToolTip",
        UIA_CustomControlTypeId => "Custom",
        UIA_ThumbControlTypeId => "Thumb",
        UIA_CalendarControlTypeId => "Calendar",
        UIA_TableControlTypeId => "Table",
        UIA_AppBarControlTypeId => "AppBar",
        UIA_SemanticZoomControlTypeId => "SemanticZoom",
        UIA_SeparatorControlTypeId => "Separator",
        _ => "Control",
    }
}

fn actionable(ct: UIA_CONTROLTYPE_ID) -> bool {
    matches!(
        ct,
        UIA_ButtonControlTypeId
            | UIA_HyperlinkControlTypeId
            | UIA_EditControlTypeId
            | UIA_CheckBoxControlTypeId
            | UIA_RadioButtonControlTypeId
            | UIA_ComboBoxControlTypeId
            | UIA_MenuItemControlTypeId
            | UIA_TabItemControlTypeId
            | UIA_ListItemControlTypeId
            | UIA_TreeItemControlTypeId
            | UIA_DataItemControlTypeId
            | UIA_TextControlTypeId
            | UIA_ImageControlTypeId
            | UIA_DocumentControlTypeId
            | UIA_SplitButtonControlTypeId
            | UIA_SliderControlTypeId
            | UIA_SpinnerControlTypeId
            | UIA_HeaderItemControlTypeId
            | UIA_GroupControlTypeId
            | UIA_CustomControlTypeId
    )
}

pub fn is_text_input(ct: UIA_CONTROLTYPE_ID) -> bool {
    matches!(ct, UIA_EditControlTypeId | UIA_DocumentControlTypeId | UIA_ComboBoxControlTypeId)
}

fn variant_string(v: &VARIANT) -> Option<String> {
    BSTR::try_from(v).ok().map(|b| b.to_string()).filter(|s| !s.is_empty())
}

fn variant_i32(v: &VARIANT) -> Option<i32> {
    i32::try_from(v).ok()
}

fn rect(r: RECT) -> Rect {
    Rect::new(r.left as f64, r.top as f64, (r.right - r.left) as f64, (r.bottom - r.top) as f64)
}

/// What the scan reads of each element, fetched in one go per window.
const PROPS: &[UIA_PROPERTY_ID] = &[
    UIA_ControlTypePropertyId,
    UIA_NamePropertyId,
    UIA_BoundingRectanglePropertyId,
    UIA_IsOffscreenPropertyId,
    UIA_AutomationIdPropertyId,
    UIA_ClassNamePropertyId,
    UIA_IsPasswordPropertyId,
    UIA_HelpTextPropertyId,
    UIA_ValueValuePropertyId,
    UIA_ToggleToggleStatePropertyId,
    UIA_IsEnabledPropertyId,
    UIA_SelectionItemIsSelectedPropertyId,
    UIA_ExpandCollapseExpandCollapseStatePropertyId,
    UIA_LocalizedControlTypePropertyId,
];

struct Node {
    el: IUIAutomationElement,
    ct: UIA_CONTROLTYPE_ID,
    name: String,
    rect: Rect,
    offscreen: bool,
    automation_id: String,
    class: String,
    password: bool,
    help: String,
    value: Option<String>,
    toggle: Option<i32>,
    selected: Option<bool>,
}

fn read(el: &IUIAutomationElement) -> Option<Node> {
    unsafe {
        let ct = el.CachedControlType().ok()?;
        let s = |id| el.GetCachedPropertyValue(id).ok().and_then(|v| variant_string(&v)).unwrap_or_default();
        let b = |id| el.GetCachedPropertyValue(id).ok().and_then(|v| bool::try_from(&v).ok());
        Some(Node {
            el: el.clone(),
            ct,
            name: el.CachedName().map(|b| b.to_string()).unwrap_or_default(),
            rect: el.CachedBoundingRectangle().map(rect).unwrap_or_default(),
            offscreen: el.CachedIsOffscreen().map(|b| b.as_bool()).unwrap_or(false),
            automation_id: s(UIA_AutomationIdPropertyId),
            class: s(UIA_ClassNamePropertyId),
            password: el.CachedIsPassword().map(|b| b.as_bool()).unwrap_or(false),
            help: s(UIA_HelpTextPropertyId),
            value: el.GetCachedPropertyValue(UIA_ValueValuePropertyId).ok().and_then(|v| variant_string(&v)),
            toggle: el.GetCachedPropertyValue(UIA_ToggleToggleStatePropertyId).ok().and_then(|v| variant_i32(&v)),
            selected: b(UIA_SelectionItemIsSelectedPropertyId),
        })
    }
}

fn fnv(parts: &[&str]) -> String {
    let mut h: u64 = 0xcbf29ce484222325;
    for b in parts.join("\u{1f}").bytes() {
        h = (h ^ b as u64).wrapping_mul(0x100000001b3);
    }
    format!("{:08x}", (h ^ (h >> 32)) as u32)
}

impl Uia {
    fn cache_request(&self, props: &[UIA_PROPERTY_ID], scope: TreeScope) -> Option<IUIAutomationCacheRequest> {
        unsafe {
            let cr = self.automation.CreateCacheRequest().ok()?;
            for p in props {
                let _ = cr.AddProperty(*p);
            }
            let _ = cr.SetTreeScope(scope);
            let _ = cr.SetTreeFilter(&self.automation.ControlViewCondition().ok()?);
            Some(cr)
        }
    }

    pub fn handle(&self, el: &IUIAutomationElement) -> u64 {
        let id = self.next.fetch_add(1, Ordering::Relaxed);
        let mut h = self.handles.lock();
        // Keep the most recent few thousand; older handles belong to screens long gone.
        if h.len() > 6000 {
            let cutoff = id.saturating_sub(3000);
            h.retain(|k, _| *k > cutoff);
        }
        h.insert(id, el.clone());
        id
    }

    pub fn element(&self, handle: u64) -> Option<IUIAutomationElement> {
        self.handles.lock().get(&handle).cloned()
    }

    pub fn from_hwnd(&self, hwnd: isize) -> Option<IUIAutomationElement> {
        com::ensure();
        unsafe { self.automation.ElementFromHandle(HWND(hwnd as _)).ok() }
    }

    /// Every element of the window's subtree with the scan's properties, breadth-first. For a browser the page
    /// (Document) isn't entered.
    fn walk(&self, root: &IUIAutomationElement, props: &[UIA_PROPERTY_ID], prune_documents: bool, cap: usize) -> Vec<(Node, usize)> {
        com::ensure();
        let mut out = vec![];
        if !prune_documents {
            // One cross-process call for the whole window.
            let Some(cr) = self.cache_request(props, TreeScope_Subtree) else { return out };
            let Ok(cached) = (unsafe { root.BuildUpdatedCache(&cr) }) else { return out };
            let mut queue: VecDeque<(IUIAutomationElement, usize)> = VecDeque::from([(cached, 0)]);
            while let Some((el, depth)) = queue.pop_front() {
                if out.len() >= cap {
                    break;
                }
                if let Some(n) = read(&el) {
                    out.push((n, depth));
                }
                if depth < 40 {
                    if let Ok(kids) = unsafe { el.GetCachedChildren() } {
                        let len = unsafe { kids.Length() }.unwrap_or(0).min(400);
                        for i in 0..len {
                            if let Ok(k) = unsafe { kids.GetElement(i) } {
                                queue.push_back((k, depth + 1));
                            }
                        }
                    }
                }
            }
            return out;
        }
        // Browsers: level by level, children of each container in one call, stopping at the page.
        let Some(cr) = self.cache_request(props, TreeScope_Element) else { return out };
        let Ok(cond) = (unsafe { self.automation.ControlViewCondition() }) else { return out };
        let Ok(start) = (unsafe { root.BuildUpdatedCache(&cr) }) else { return out };
        let mut queue: VecDeque<(IUIAutomationElement, usize)> = VecDeque::from([(start, 0)]);
        let mut visited = 0;
        while let Some((el, depth)) = queue.pop_front() {
            if out.len() >= cap || visited > 1500 {
                break;
            }
            visited += 1;
            let Some(n) = read(&el) else { continue };
            let enter = n.ct != UIA_DocumentControlTypeId && depth < 30;
            out.push((n, depth));
            if !enter {
                continue;
            }
            if let Ok(kids) = unsafe { el.FindAllBuildCache(TreeScope_Children, &cond, &cr) } {
                let len = unsafe { kids.Length() }.unwrap_or(0).min(300);
                for i in 0..len {
                    if let Ok(k) = unsafe { kids.GetElement(i) } {
                        queue.push_back((k, depth + 1));
                    }
                }
            }
        }
        out
    }

    /// The window's visible, useful controls (dialog first), up to `limit`.
    pub fn scan(&self, hwnd: isize, dialog_hwnd: Option<isize>, browser: bool, screen: Rect, limit: usize) -> Scan {
        com::ensure();
        let mut roots: Vec<(IUIAutomationElement, bool)> = vec![];
        if let Some(d) = dialog_hwnd.filter(|d| *d != hwnd) {
            if let Some(e) = self.from_hwnd(d) {
                roots.push((e, true));
            }
        }
        if let Some(e) = self.from_hwnd(hwnd) {
            roots.push((e, dialog_hwnd == Some(hwnd)));
        }
        let window_title = crate::apps::window_title(hwnd);
        let gather = limit + limit / 2;
        let mut found: Vec<(Element, i32)> = vec![];
        let mut seen = HashSet::new();
        let mut ref_counts: HashMap<String, usize> = HashMap::new();
        let mut hasher_parts: Vec<String> = vec![];
        for (root, in_dialog) in roots {
            for (n, _depth) in self.walk(&root, PROPS, browser, 4000) {
                hasher_parts.push(format!("{}|{}|{}|{:?}", n.ct.0, n.name, n.value.clone().unwrap_or_default(), n.toggle));
                if found.len() >= gather || !actionable(n.ct) || n.offscreen || n.rect.w <= 2.0 || n.rect.h <= 2.0 || !screen.intersects(&n.rect) {
                    continue;
                }
                let role = role_name(n.ct);
                let value = if n.password { n.value.as_ref().map(|_| clinqy_core::safety::REDACTED.to_string()) } else { n.value.clone() };
                let mut label = [n.name.as_str(), n.help.as_str()].iter().filter(|s| !s.is_empty()).map(|s| s.to_string()).collect::<Vec<_>>();
                label.dedup();
                let mut label = label.join(" — ");
                if label.is_empty() {
                    if let Some(v) = value.as_ref().filter(|_| !is_text_input(n.ct)) {
                        label = v.chars().take(80).collect();
                    }
                }
                let label: String = label.replace(['\n', '\r'], " ").replace(['\u{200e}', '\u{200f}'], "").chars().take(140).collect();
                let input = is_text_input(n.ct);
                // Unlabeled images, text and groups are noise; unlabeled inputs are still useful.
                if label.is_empty() && !input {
                    continue;
                }
                if (n.ct == UIA_GroupControlTypeId || n.ct == UIA_CustomControlTypeId) && label.is_empty() {
                    continue;
                }
                let key = format!("{role}|{label}|{},{},{},{}", n.rect.x as i64, n.rect.y as i64, n.rect.w as i64, n.rect.h as i64);
                if !seen.insert(key) {
                    continue;
                }
                let base = fnv(&[role, &n.automation_id, &n.class, &n.name, &window_title, if n.name.is_empty() && n.automation_id.is_empty() { &label } else { "" }]);
                let count = ref_counts.entry(base.clone()).or_insert(0);
                *count += 1;
                let stable = if *count == 1 { base } else { format!("{base}~{count}") };
                let state = match (n.ct, n.toggle, n.selected) {
                    (UIA_CheckBoxControlTypeId, Some(t), _) => Some(match t {
                        1 => "checked".to_string(),
                        2 => "mixed".to_string(),
                        _ => "unchecked".to_string(),
                    }),
                    (UIA_RadioButtonControlTypeId | UIA_TabItemControlTypeId | UIA_ListItemControlTypeId, _, Some(s)) if s => Some("selected".to_string()),
                    _ => None,
                };
                let value = match state {
                    Some(s) => Some(s),
                    None => value.map(|v| v.chars().take(200).collect()),
                };
                let priority = match n.ct {
                    UIA_GroupControlTypeId | UIA_CustomControlTypeId => 1,
                    UIA_TextControlTypeId | UIA_ImageControlTypeId => 1,
                    UIA_ListItemControlTypeId | UIA_DataItemControlTypeId | UIA_TreeItemControlTypeId | UIA_HeaderItemControlTypeId => 2,
                    _ => 3,
                } + if in_dialog { 10 } else { 0 };
                let handle = self.handle(&n.el);
                found.push((
                    Element {
                        id: String::new(),
                        role: role.to_string(),
                        label: if label.is_empty() { format!("(unlabeled {role})") } else { label },
                        rect: n.rect,
                        value,
                        stable,
                        in_dialog,
                        handle,
                    },
                    priority,
                ));
            }
        }
        if found.len() > limit {
            let mut idx: Vec<usize> = (0..found.len()).collect();
            idx.sort_by_key(|&i| (std::cmp::Reverse(found[i].1), i));
            let keep: HashSet<usize> = idx.into_iter().take(limit).collect();
            found = found.into_iter().enumerate().filter(|(i, _)| keep.contains(i)).map(|(_, e)| e).collect();
        }
        let elements: Vec<Element> = found.into_iter().enumerate().map(|(i, (mut e, _))| {
            e.id = format!("e{i}");
            e
        }).collect();
        let focused = self.focus_summary();
        let mut fp: u64 = 0xcbf29ce484222325;
        for p in hasher_parts.iter().chain(std::iter::once(&focused)) {
            for b in p.bytes() {
                fp = (fp ^ b as u64).wrapping_mul(0x100000001b3);
            }
        }
        Scan { elements, fingerprint: fp, window: window_title, focused, dialog: None }
    }

    /// A cheap signature of what's on screen: if it doesn't change after an action, the action missed.
    pub fn fingerprint(&self, hwnd: isize, browser: bool) -> u64 {
        let mut fp: u64 = 0xcbf29ce484222325;
        let mut mix = |s: &str| {
            for b in s.bytes() {
                fp = (fp ^ b as u64).wrapping_mul(0x100000001b3);
            }
        };
        mix(&crate::apps::window_title(hwnd));
        if let Some(root) = self.from_hwnd(hwnd) {
            let props = [UIA_ControlTypePropertyId, UIA_NamePropertyId, UIA_ValueValuePropertyId, UIA_ToggleToggleStatePropertyId, UIA_SelectionItemIsSelectedPropertyId];
            for (n, _) in self.walk(&root, &props, browser, 600) {
                mix(&format!("{}|{}|{}|{:?}|{:?}", n.ct.0, n.name, n.value.unwrap_or_default(), n.toggle, n.selected));
            }
        }
        mix(&self.focus_summary());
        fp
    }

    /// "Edit: Search" — what has keyboard focus.
    pub fn focus_summary(&self) -> String {
        match self.focus() {
            Some(f) => format!("{}{}", f.role, if f.value.as_deref().map(|v| !v.is_empty()).unwrap_or(false) && !f.secure { format!(" = {:?}", f.value.unwrap().chars().take(60).collect::<String>()) } else { String::new() }),
            None => "nothing".into(),
        }
    }

    pub fn focus(&self) -> Option<Focus> {
        com::ensure();
        unsafe {
            let el = self.automation.GetFocusedElement().ok()?;
            let ct = el.CurrentControlType().ok()?;
            let secure = el.CurrentIsPassword().map(|b| b.as_bool()).unwrap_or(false);
            let value = el.GetCurrentPropertyValue(UIA_ValueValuePropertyId).ok().and_then(|v| variant_string(&v));
            let name = el.CurrentName().map(|b| b.to_string()).unwrap_or_default();
            let pid = el.CurrentProcessId().unwrap_or(0) as u32;
            let r = el.CurrentBoundingRectangle().ok().map(rect);
            let editable = is_text_input(ct) && el.GetCurrentPropertyValue(UIA_ValueIsReadOnlyPropertyId).ok().and_then(|v| bool::try_from(&v).ok()) != Some(true);
            Some(Focus {
                role: format!("{}{}", role_name(ct), if name.is_empty() { String::new() } else { format!(": {}", name.chars().take(60).collect::<String>()) }),
                value: if secure { None } else { value },
                secure,
                rect: r,
                pid,
                handle: self.handle(&el),
                text_input: editable,
            })
        }
    }

    pub fn rect_of(&self, handle: u64) -> Option<Rect> {
        com::ensure();
        let el = self.element(handle)?;
        let r = unsafe { el.CurrentBoundingRectangle() }.ok().map(rect)?;
        (r.w > 0.0 && r.h > 0.0).then_some(r)
    }

    pub fn value_of(&self, handle: u64) -> Option<String> {
        com::ensure();
        let el = self.element(handle)?;
        if unsafe { el.CurrentIsPassword() }.map(|b| b.as_bool()).unwrap_or(false) {
            return None;
        }
        unsafe { el.GetCurrentPropertyValue(UIA_ValueValuePropertyId) }.ok().and_then(|v| variant_string(&v))
    }

    /// Presses a control through its pattern (exact, no pointer move): invoke, toggle, select or expand.
    pub fn invoke(&self, handle: u64) -> bool {
        com::ensure();
        let Some(el) = self.element(handle) else { return false };
        unsafe {
            if let Ok(p) = el.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId) {
                if p.Invoke().is_ok() {
                    return true;
                }
            }
            if let Ok(p) = el.GetCurrentPatternAs::<IUIAutomationTogglePattern>(UIA_TogglePatternId) {
                if p.Toggle().is_ok() {
                    return true;
                }
            }
            if let Ok(p) = el.GetCurrentPatternAs::<IUIAutomationSelectionItemPattern>(UIA_SelectionItemPatternId) {
                if p.Select().is_ok() {
                    return true;
                }
            }
            if let Ok(p) = el.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId) {
                let state = p.CurrentExpandCollapseState().unwrap_or(ExpandCollapseState_Collapsed);
                let r = if state == ExpandCollapseState_Expanded { p.Collapse() } else { p.Expand() };
                if r.is_ok() {
                    return true;
                }
            }
            if let Ok(p) = el.GetCurrentPatternAs::<IUIAutomationLegacyIAccessiblePattern>(UIA_LegacyIAccessiblePatternId) {
                if p.DoDefaultAction().is_ok() {
                    return true;
                }
            }
        }
        false
    }

    pub fn set_focus(&self, handle: u64) -> bool {
        com::ensure();
        self.element(handle).map(|e| unsafe { e.SetFocus() }.is_ok()).unwrap_or(false)
    }

    pub fn set_value(&self, handle: u64, text: &str) -> bool {
        com::ensure();
        let Some(el) = self.element(handle) else { return false };
        unsafe {
            el.GetCurrentPatternAs::<IUIAutomationValuePattern>(UIA_ValuePatternId).map(|p| p.SetValue(&BSTR::from(text)).is_ok()).unwrap_or(false)
        }
    }

    /// The clickable point of a control (better than its centre for links that wrap).
    pub fn clickable_point(&self, handle: u64) -> Option<(f64, f64)> {
        com::ensure();
        let el = self.element(handle)?;
        let mut p = POINT::default();
        let got = unsafe { el.GetClickablePoint(&mut p) }.ok()?;
        got.as_bool().then(|| (p.x as f64, p.y as f64))
    }

    /// The process owning whatever is at a screen point.
    pub fn pid_at(&self, x: f64, y: f64) -> Option<u32> {
        com::ensure();
        unsafe {
            let el = self.automation.ElementFromPoint(POINT { x: x as i32, y: y as i32 }).ok()?;
            el.CurrentProcessId().ok().map(|p| p as u32)
        }
    }

    /// The browser's page area: the largest Document in the window (not entered).
    pub fn web_area(&self, hwnd: isize) -> Option<Rect> {
        let root = self.from_hwnd(hwnd)?;
        let mut best: Option<Rect> = None;
        for (n, _) in self.walk(&root, &[UIA_ControlTypePropertyId, UIA_BoundingRectanglePropertyId, UIA_NamePropertyId], true, 1500) {
            if n.ct == UIA_DocumentControlTypeId && n.rect.w > 100.0 && n.rect.h > 50.0 && best.map(|b| n.rect.w * n.rect.h > b.w * b.h).unwrap_or(true) {
                best = Some(n.rect);
            }
        }
        best
    }

    /// Text of the window's first static text that asks something (a dialog's question), else the longest.
    pub fn dialog_text(&self, hwnd: isize) -> String {
        let Some(root) = self.from_hwnd(hwnd) else { return String::new() };
        let texts: Vec<String> =
            self.walk(&root, &[UIA_ControlTypePropertyId, UIA_NamePropertyId], false, 80).into_iter().filter(|(n, _)| n.ct == UIA_TextControlTypeId && !n.name.is_empty()).map(|(n, _)| n.name).collect();
        texts.iter().find(|t| t.contains('?')).or_else(|| texts.iter().max_by_key(|t| t.len())).cloned().unwrap_or_default()
    }

    /// Chooses a menu item by path ("File > Save As"), tolerant of case, accelerators and "…".
    pub fn press_menu(&self, hwnd: isize, path: &str) -> (bool, String) {
        com::ensure();
        let key = |s: &str| s.replace('&', "").replace('…', "").replace("...", "").split('\t').next().unwrap_or("").trim().to_lowercase();
        let parts: Vec<String> = path.split(['>', '›', '→']).map(|p| key(p)).filter(|p| !p.is_empty()).collect();
        if parts.is_empty() {
            return (false, "empty path".into());
        }
        let Some(root) = self.from_hwnd(hwnd) else { return (false, "no window".into()) };
        let props = [UIA_ControlTypePropertyId, UIA_NamePropertyId, UIA_BoundingRectanglePropertyId];
        let nodes = self.walk(&root, &props, false, 3000);
        let Some(bar) = nodes.iter().find(|(n, _)| n.ct == UIA_MenuBarControlTypeId && !n.name.eq_ignore_ascii_case("System")) else {
            return (false, "this window has no menu bar; use its buttons, or keys (alt shows menu shortcuts)".into());
        };
        let mut items: Vec<(String, IUIAutomationElement)> = self.children_named(&bar.0.el, UIA_MenuItemControlTypeId);
        for (i, part) in parts.iter().enumerate() {
            let hit = items
                .iter()
                .find(|(n, _)| key(n) == *part)
                .or_else(|| items.iter().find(|(n, _)| key(n).starts_with(part.as_str())))
                .or_else(|| items.iter().find(|(n, _)| key(n).contains(part.as_str())))
                .cloned();
            let Some((name, el)) = hit else {
                let offered: Vec<String> = items.iter().take(30).map(|(n, _)| n.replace('&', "")).collect();
                self.close_menus();
                return (false, format!("no “{part}” in {}; it has: {}", if i == 0 { "the menu bar" } else { "that menu" }, offered.join(", ")));
            };
            if i == parts.len() - 1 {
                let ok = unsafe {
                    el.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId).map(|p| p.Invoke().is_ok()).unwrap_or(false)
                        || el.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId).map(|p| p.Expand().is_ok()).unwrap_or(false)
                };
                if !ok {
                    self.close_menus();
                }
                return if ok { (true, format!("chose {}", name.replace('&', ""))) } else { (false, format!("“{}” wouldn't press (greyed out?)", name.replace('&', ""))) };
            }
            unsafe {
                if let Ok(p) = el.GetCurrentPatternAs::<IUIAutomationExpandCollapsePattern>(UIA_ExpandCollapsePatternId) {
                    let _ = p.Expand();
                } else if let Ok(p) = el.GetCurrentPatternAs::<IUIAutomationInvokePattern>(UIA_InvokePatternId) {
                    let _ = p.Invoke();
                }
            }
            std::thread::sleep(std::time::Duration::from_millis(250));
            // The submenu's items: under the item, or in a popup menu window.
            items = self.descendants_named(&el, UIA_MenuItemControlTypeId);
            if items.is_empty() {
                if let Ok(desk) = unsafe { self.automation.GetRootElement() } {
                    if let Ok(cond) = unsafe { self.automation.CreatePropertyCondition(UIA_ControlTypePropertyId, &VARIANT::from(UIA_MenuControlTypeId.0)) } {
                        if let Ok(menus) = unsafe { desk.FindAll(TreeScope_Children, &cond) } {
                            let len = unsafe { menus.Length() }.unwrap_or(0);
                            for k in 0..len {
                                if let Ok(m) = unsafe { menus.GetElement(k) } {
                                    items.extend(self.descendants_named(&m, UIA_MenuItemControlTypeId));
                                }
                            }
                        }
                    }
                }
            }
            if items.is_empty() {
                self.close_menus();
                return (false, format!("“{}” has no submenu", name.replace('&', "")));
            }
        }
        (false, "empty path".into())
    }

    fn close_menus(&self) {
        crate::input::press_combo("esc");
        crate::input::press_combo("esc");
    }

    fn children_named(&self, el: &IUIAutomationElement, ct: UIA_CONTROLTYPE_ID) -> Vec<(String, IUIAutomationElement)> {
        self.find_named(el, ct, TreeScope_Children)
    }

    fn descendants_named(&self, el: &IUIAutomationElement, ct: UIA_CONTROLTYPE_ID) -> Vec<(String, IUIAutomationElement)> {
        self.find_named(el, ct, TreeScope_Children).into_iter().chain(self.find_named(el, ct, TreeScope_Descendants)).fold(vec![], |mut acc, x| {
            if !acc.iter().any(|(n, _): &(String, IUIAutomationElement)| n == &x.0) {
                acc.push(x);
            }
            acc
        })
    }

    fn find_named(&self, el: &IUIAutomationElement, ct: UIA_CONTROLTYPE_ID, scope: TreeScope) -> Vec<(String, IUIAutomationElement)> {
        unsafe {
            let Ok(cond) = self.automation.CreatePropertyCondition(UIA_ControlTypePropertyId, &VARIANT::from(ct.0)) else { return vec![] };
            let Ok(all) = el.FindAll(scope, &cond) else { return vec![] };
            let len = all.Length().unwrap_or(0);
            (0..len)
                .filter_map(|i| all.GetElement(i).ok())
                .filter_map(|e| {
                    let n = e.CurrentName().ok()?.to_string();
                    (!n.is_empty()).then_some((n, e))
                })
                .collect()
        }
    }

    /// The selected text in the focused control, when it publishes it.
    pub fn selected_text(&self) -> Option<String> {
        com::ensure();
        unsafe {
            let el = self.automation.GetFocusedElement().ok()?;
            let tp = el.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId).ok()?;
            let ranges = tp.GetSelection().ok()?;
            let mut out = String::new();
            for i in 0..ranges.Length().unwrap_or(0) {
                if let Ok(r) = ranges.GetElement(i) {
                    if let Ok(t) = r.GetText(20000) {
                        out += &t.to_string();
                    }
                }
            }
            let t = out.trim().to_string();
            (!t.is_empty()).then_some(t)
        }
    }

    /// Text elements of a window that contain `want` (for waiting on text outside a page).
    pub fn window_text_contains(&self, hwnd: isize, want: &str, browser: bool) -> bool {
        let Some(root) = self.from_hwnd(hwnd) else { return false };
        self.walk(&root, &[UIA_ControlTypePropertyId, UIA_NamePropertyId, UIA_ValueValuePropertyId], browser, 2000)
            .iter()
            .any(|(n, _)| n.name.to_lowercase().contains(want) || n.value.as_deref().map(|v| v.to_lowercase().contains(want)).unwrap_or(false))
    }

    /// The taskbar's buttons: (name, element).
    pub fn taskbar_buttons(&self) -> Vec<(String, u64, Rect)> {
        com::ensure();
        let tray = crate::apps::find_window("Shell_TrayWnd");
        let Some(root) = tray.and_then(|h| self.from_hwnd(h)) else { return vec![] };
        self.walk(&root, &[UIA_ControlTypePropertyId, UIA_NamePropertyId, UIA_BoundingRectanglePropertyId, UIA_AutomationIdPropertyId], false, 400)
            .into_iter()
            .filter(|(n, _)| matches!(n.ct, UIA_ButtonControlTypeId | UIA_ListItemControlTypeId | UIA_MenuItemControlTypeId) && !n.name.is_empty() && n.rect.w > 4.0)
            .map(|(n, _)| (n.name.clone(), self.handle(&n.el), n.rect))
            .collect()
    }
}

/// The focused dialog's kind and title, for the observation.
pub fn dialog_of(hwnd: isize, owner: Option<isize>) -> Option<Dialog> {
    let class = crate::apps::class_name(hwnd);
    if class != "#32770" && owner.is_none() {
        return None;
    }
    let mut title = crate::apps::window_title(hwnd);
    if title.is_empty() {
        title = uia().dialog_text(hwnd);
    }
    Some(Dialog { kind: if class == "#32770" { "dialog".into() } else { "window".into() }, title: title.chars().take(120).collect() })
}
