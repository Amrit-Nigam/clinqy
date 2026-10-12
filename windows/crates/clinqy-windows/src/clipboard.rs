//! The clipboard: text, images (PNG plus a DIB for apps that only read bitmaps) and copied files. Text Clinqy
//! puts there only to paste is kept out of Windows' clipboard history.

use crate::com::wide;
use std::path::PathBuf;
use std::time::Duration;
use windows::core::PCWSTR;
use windows::Win32::Foundation::{HANDLE, HGLOBAL};
use windows::Win32::System::DataExchange::*;
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::{CF_DIB, CF_HDROP, CF_UNICODETEXT};
use windows::Win32::UI::Shell::{DragQueryFileW, HDROP};

struct Open;

impl Open {
    fn new() -> Option<Open> {
        for _ in 0..20 {
            if unsafe { OpenClipboard(None) }.is_ok() {
                return Some(Open);
            }
            std::thread::sleep(Duration::from_millis(15));
        }
        None
    }
}

impl Drop for Open {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseClipboard();
        }
    }
}

fn global(bytes: &[u8]) -> Option<HGLOBAL> {
    unsafe {
        let h = GlobalAlloc(GMEM_MOVEABLE, bytes.len().max(1)).ok()?;
        let p = GlobalLock(h);
        if p.is_null() {
            return None;
        }
        std::ptr::copy_nonoverlapping(bytes.as_ptr(), p as *mut u8, bytes.len());
        let _ = GlobalUnlock(h);
        Some(h)
    }
}

fn format(name: &str) -> u32 {
    let w = wide(name);
    unsafe { RegisterClipboardFormatW(PCWSTR(w.as_ptr())) }
}

fn exclude_from_history() {
    // Marker formats Windows' clipboard history and cloud sync honour.
    for name in ["ExcludeClipboardContentFromMonitorProcessing", "CanIncludeInClipboardHistory", "CanUploadToCloudClipboard"] {
        let data: [u8; 4] = [0, 0, 0, 0];
        if let Some(h) = global(&data) {
            unsafe {
                let _ = SetClipboardData(format(name), HANDLE(h.0));
            }
        }
    }
}

pub fn text() -> Option<String> {
    let _open = Open::new()?;
    unsafe {
        let h = GetClipboardData(CF_UNICODETEXT.0 as u32).ok()?;
        let g = HGLOBAL(h.0);
        let p = GlobalLock(g) as *const u16;
        if p.is_null() {
            return None;
        }
        let max = GlobalSize(g) / 2;
        let mut len = 0;
        while len < max && *p.add(len) != 0 {
            len += 1;
        }
        let s = String::from_utf16_lossy(std::slice::from_raw_parts(p, len));
        let _ = GlobalUnlock(g);
        Some(s)
    }
}

/// Sets text; `transient` keeps it out of clipboard history (Clinqy pasting, not the user copying).
pub fn set_text(text: &str, transient: bool) -> bool {
    let Some(_open) = Open::new() else { return false };
    let mut bytes: Vec<u8> = text.encode_utf16().flat_map(|u| u.to_le_bytes()).collect();
    bytes.extend([0, 0]);
    unsafe {
        let _ = EmptyClipboard();
        let Some(h) = global(&bytes) else { return false };
        let ok = SetClipboardData(CF_UNICODETEXT.0 as u32, HANDLE(h.0)).is_ok();
        if transient {
            exclude_from_history();
        }
        ok
    }
}

/// Puts an image on the clipboard as PNG and as a DIB.
pub fn set_png(png: &[u8]) -> bool {
    let Ok(img) = image::load_from_memory(png) else { return false };
    let rgba = img.to_rgba8();
    let (w, h) = (rgba.width(), rgba.height());
    // A bottom-up 32-bit DIB.
    let mut dib = Vec::with_capacity(40 + (w * h * 4) as usize);
    dib.extend(40u32.to_le_bytes());
    dib.extend((w as i32).to_le_bytes());
    dib.extend((h as i32).to_le_bytes());
    dib.extend(1u16.to_le_bytes());
    dib.extend(32u16.to_le_bytes());
    dib.extend(0u32.to_le_bytes()); // BI_RGB
    dib.extend((w * h * 4).to_le_bytes());
    dib.extend([0u8; 16]);
    for y in (0..h).rev() {
        for x in 0..w {
            let p = rgba.get_pixel(x, y);
            dib.extend([p[2], p[1], p[0], p[3]]);
        }
    }
    let Some(_open) = Open::new() else { return false };
    unsafe {
        let _ = EmptyClipboard();
        let mut ok = false;
        if let Some(g) = global(png) {
            ok |= SetClipboardData(format("PNG"), HANDLE(g.0)).is_ok();
        }
        if let Some(g) = global(&dib) {
            ok |= SetClipboardData(CF_DIB.0 as u32, HANDLE(g.0)).is_ok();
        }
        ok
    }
}

pub fn files() -> Vec<PathBuf> {
    let Some(_open) = Open::new() else { return vec![] };
    unsafe {
        let Ok(h) = GetClipboardData(CF_HDROP.0 as u32) else { return vec![] };
        let drop = HDROP(h.0);
        let n = DragQueryFileW(drop, 0xFFFF_FFFF, None);
        (0..n)
            .filter_map(|i| {
                let mut buf = [0u16; 1024];
                let len = DragQueryFileW(drop, i, Some(&mut buf));
                (len > 0).then(|| PathBuf::from(String::from_utf16_lossy(&buf[..len as usize])))
            })
            .collect()
    }
}

pub fn sequence() -> u32 {
    unsafe { GetClipboardSequenceNumber() }
}
