//! Clinqy for Windows, the app side: the tray app (`app`, `ui`, `voice`, `recorder`), the pipe both binaries talk
//! over (`ipc`, `server`), and the `clinqy` command with its MCP server (`cli`, `mcp`).

pub mod app;
pub mod cli;
pub mod ipc;
pub mod mcp;
pub mod recorder;
pub mod server;
pub mod setup;
pub mod ui;
pub mod voice;
