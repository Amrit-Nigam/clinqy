//! clinqy.exe: the command for terminals and coding agents (see `clinqy help`).

fn main() {
    // UTF-8 output (✓, →, names in any script) in any console.
    unsafe {
        let _ = windows::Win32::System::Console::SetConsoleOutputCP(65001);
    }
    let args: Vec<String> = std::env::args().skip(1).collect();
    std::process::exit(clinqy_app::cli::main(args));
}
