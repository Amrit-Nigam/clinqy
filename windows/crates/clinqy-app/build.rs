// Embeds the icon, version details and manifest into both executables.
fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows") {
        let mut res = winresource::WindowsResource::new();
        res.set_icon("../../assets/clinqy.ico");
        res.set("ProductName", "Clinqy");
        res.set("FileDescription", "Clinqy, a desktop assistant that uses your computer for you");
        res.set("CompanyName", "Clinqy contributors");
        res.set("LegalCopyright", "MIT License");
        res.set("OriginalFilename", "ClinqyApp.exe");
        res.set_manifest(
            r#"<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v3">
    <security><requestedPrivileges><requestedExecutionLevel level="asInvoker" uiAccess="false"/></requestedPrivileges></security>
  </trustInfo>
  <compatibility xmlns="urn:schemas-microsoft-com:compatibility.v1">
    <application><supportedOS Id="{8e0f7a12-bfb3-4fe8-b9a5-48fd50a15a9a}"/></application>
  </compatibility>
</assembly>"#,
        );
        res.compile().expect("couldn't embed the icon and version details");
    }
    println!("cargo:rerun-if-changed=../../assets/clinqy.ico");
}
