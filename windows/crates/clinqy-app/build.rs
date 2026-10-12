// Embeds the icon and version details into both executables.
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let mut res = winresource::WindowsResource::new();
        res.set_icon("../../assets/clinqy.ico");
        res.set("ProductName", "Clinqy");
        res.set("FileDescription", "Clinqy");
        res.set("CompanyName", "Clinqy");
        res.set("LegalCopyright", "MIT License");
        let _ = res.compile();
    }
    println!("cargo:rerun-if-changed=../../assets/clinqy.ico");
}
