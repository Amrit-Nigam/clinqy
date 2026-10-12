//! Times a UI Automation scan of a window (SHOW=1 lists what it found):
//! cargo run -p clinqy-windows --example scan_time -- <hwnd>
fn main() {
    clinqy_windows::init_process();
    clinqy_windows::com::ensure();
    let hwnd: isize = std::env::args().nth(1).and_then(|a| a.parse().ok()).expect("hwnd");
    let u = clinqy_windows::uia::uia();
    for _ in 0..2 {
        let t = std::time::Instant::now();
        let s = u.scan(hwnd, None, false, clinqy_windows::screen::virtual_screen(), 150);
        println!("scan: {} elements in {} ms", s.elements.len(), t.elapsed().as_millis());
        if std::env::var("SHOW").is_ok() { for e in s.elements.iter() { println!("  {} {}: {}", e.id, e.role, e.label); } }
        let t = std::time::Instant::now();
        let f = u.focus_summary();
        println!("focus: {f} in {} ms", t.elapsed().as_millis());
        let t = std::time::Instant::now();
        let _ = u.fingerprint(hwnd, false);
        println!("fingerprint in {} ms", t.elapsed().as_millis());
    }
}
