//! Voice: hold the hotkey and talk, release to send — transcribed on this PC by Whisper (whisper.cpp, the same
//! model family the Mac app runs). The first use downloads whisper.cpp and the model into
//! %LOCALAPPDATA%\Clinqy\voice; after that a small local Whisper server keeps the model warm so a request is
//! transcribed in about a second. Nothing leaves the PC.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use parking_lot::Mutex;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// whisper.cpp's Windows build, pinned.
const WHISPER_ZIP: &str = "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-bin-x64.zip";
const PORT: u16 = 47824;

type LevelFn = Box<dyn Fn(f32) + Send + Sync>;
type TextFn = Box<dyn Fn(String, bool) + Send + Sync>;

struct Inner {
    listening: AtomicBool,
    cancel: AtomicBool,
    stop: AtomicBool,
    transcript: Mutex<String>,
    on_level: LevelFn,
    on_text: TextFn,
    server: Mutex<Option<std::process::Child>>,
    last_used: Mutex<Instant>,
    preparing: AtomicBool,
}

#[derive(Clone)]
pub struct Voice(Arc<Inner>);

fn dir() -> PathBuf {
    let d = clinqy_core::paths::local_dir().join("voice");
    let _ = std::fs::create_dir_all(&d);
    d
}

fn model_name() -> String {
    let m = clinqy_core::config::value("WHISPER_MODEL").unwrap_or_else(|| "large-v3-turbo-q5_0".into());
    // The Mac's WhisperKit names ("large-v3-v20240930_turbo_632MB") mean the same model here.
    if m.contains("turbo") {
        "large-v3-turbo-q5_0".into()
    } else {
        m.trim_start_matches("ggml-").trim_end_matches(".bin").to_string()
    }
}

fn model_path() -> PathBuf {
    dir().join(format!("ggml-{}.bin", model_name()))
}

fn server_exe() -> PathBuf {
    dir().join("whisper").join("whisper-server.exe")
}

/// Whisper's language from VOICE_LANGUAGE: auto, en, hi, hinglish (English letters), or any Whisper code.
fn language() -> (String, Option<&'static str>) {
    match clinqy_core::config::value("VOICE_LANGUAGE").unwrap_or_else(|| "auto".into()).to_lowercase().as_str() {
        "hinglish" => ("en".into(), Some("Hinglish: Hindi and English mixed, written in English letters.")),
        "" | "auto" => ("auto".into(), None),
        other => (other.to_string(), None),
    }
}

async fn download(url: &str, to: &std::path::Path, label: &str, on_progress: &(dyn Fn(String) + Sync)) -> anyhow::Result<()> {
    use futures_util::StreamExt;
    let client = reqwest::Client::builder().timeout(Duration::from_secs(3600)).build()?;
    let resp = client.get(url).send().await?.error_for_status()?;
    let total = resp.content_length().unwrap_or(0);
    let tmp = to.with_extension("part");
    let mut file = tokio::fs::File::create(&tmp).await?;
    let mut got: u64 = 0;
    let mut last = Instant::now();
    let mut stream = resp.bytes_stream();
    use tokio::io::AsyncWriteExt;
    while let Some(chunk) = stream.next().await {
        let chunk = chunk?;
        got += chunk.len() as u64;
        file.write_all(&chunk).await?;
        if last.elapsed() > Duration::from_millis(700) && total > 0 {
            last = Instant::now();
            on_progress(format!("Downloading {label}: {}%", got * 100 / total));
        }
    }
    file.flush().await?;
    drop(file);
    tokio::fs::rename(&tmp, to).await?;
    Ok(())
}

impl Voice {
    pub fn new(on_level: LevelFn, on_text: TextFn) -> Voice {
        Voice(Arc::new(Inner {
            listening: AtomicBool::new(false),
            cancel: AtomicBool::new(false),
            stop: AtomicBool::new(false),
            transcript: Mutex::new(String::new()),
            on_level,
            on_text,
            server: Mutex::new(None),
            last_used: Mutex::new(Instant::now()),
            preparing: AtomicBool::new(false),
        }))
    }

    pub fn is_listening(&self) -> bool {
        self.0.listening.load(Ordering::Relaxed)
    }

    pub fn transcript(&self) -> String {
        self.0.transcript.lock().clone()
    }

    fn set_transcript(&self, t: &str, done: bool) {
        *self.0.transcript.lock() = t.to_string();
        (self.0.on_text)(t.to_string(), done);
    }

    pub fn ready(&self) -> bool {
        server_exe().is_file() && model_path().is_file()
    }

    /// Gets whisper.cpp and the model (once), then starts the local server.
    async fn prepare(&self) -> anyhow::Result<()> {
        let progress = |m: String| {
            *self.0.transcript.lock() = m.clone();
            (self.0.on_text)(m, false);
        };
        if !server_exe().is_file() {
            progress("Setting up voice (once): downloading Whisper…".into());
            let zip = dir().join("whisper.zip");
            download(WHISPER_ZIP, &zip, "Whisper", &progress).await?;
            let out = dir().join("whisper");
            let _ = std::fs::create_dir_all(&out);
            let file = std::fs::File::open(&zip)?;
            let mut archive = zip::ZipArchive::new(file)?;
            for i in 0..archive.len() {
                let mut f = archive.by_index(i)?;
                let name = f.name().rsplit('/').next().unwrap_or("").to_string();
                let keep = name == "whisper-server.exe" || name == "whisper-cli.exe" || (name.ends_with(".dll") && (name.starts_with("ggml") || name == "whisper.dll"));
                if keep {
                    let mut w = std::fs::File::create(out.join(&name))?;
                    std::io::copy(&mut f, &mut w)?;
                }
            }
            let _ = std::fs::remove_file(zip);
        }
        if !model_path().is_file() {
            let url = format!("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{}.bin", model_name());
            progress(format!("Setting up voice (once): downloading the {} model…", model_name()));
            download(&url, &model_path(), "the voice model", &progress).await?;
        }
        self.ensure_server().await
    }

    async fn ensure_server(&self) -> anyhow::Result<()> {
        *self.0.last_used.lock() = Instant::now();
        let alive = self.0.server.lock().as_mut().map(|c| c.try_wait().map(|s| s.is_none()).unwrap_or(false)).unwrap_or(false);
        if alive {
            return Ok(());
        }
        let (lang, prompt) = language();
        let threads = std::thread::available_parallelism().map(|n| n.get().min(8)).unwrap_or(4).to_string();
        let mut cmd = std::process::Command::new(server_exe());
        cmd.args(["-m", &model_path().display().to_string(), "--host", "127.0.0.1", "--port", &PORT.to_string(), "-l", &lang, "-t", &threads, "-nt"]);
        if let Some(p) = prompt {
            cmd.args(["--prompt", p]);
        }
        use std::os::windows::process::CommandExt;
        let child = cmd.current_dir(server_exe().parent().unwrap()).stdout(std::process::Stdio::null()).stderr(std::process::Stdio::null()).creation_flags(0x0800_0000).spawn()?;
        *self.0.server.lock() = Some(child);
        // Loading the model takes a few seconds.
        for _ in 0..120 {
            if tokio::net::TcpStream::connect(("127.0.0.1", PORT)).await.is_ok() {
                return Ok(());
            }
            tokio::time::sleep(Duration::from_millis(250)).await;
        }
        anyhow::bail!("the voice model didn't start")
    }

    /// Starts listening until stop() (hold-to-talk).
    pub fn start(&self) {
        self.begin(None);
    }

    /// Listens on its own: stops after a pause in speech, gives up after `give_up` seconds of silence.
    pub fn start_auto(&self, give_up: f64) {
        self.begin(Some(give_up));
    }

    pub fn stop(&self) {
        self.0.stop.store(true, Ordering::Relaxed);
    }

    pub fn cancel(&self) {
        self.0.cancel.store(true, Ordering::Relaxed);
        self.0.stop.store(true, Ordering::Relaxed);
    }

    fn begin(&self, auto: Option<f64>) {
        if self.0.listening.swap(true, Ordering::Relaxed) {
            return;
        }
        self.0.stop.store(false, Ordering::Relaxed);
        self.0.cancel.store(false, Ordering::Relaxed);
        *self.0.transcript.lock() = String::new();
        let me = self.clone();
        let rt = tokio::runtime::Handle::current();
        // The server warms up while the user is still talking.
        if !self.0.preparing.swap(true, Ordering::Relaxed) {
            let m = self.clone();
            tokio::spawn(async move {
                if m.ready() {
                    let _ = m.ensure_server().await;
                }
                m.0.preparing.store(false, Ordering::Relaxed);
            });
        }
        std::thread::spawn(move || {
            let samples = me.record(auto);
            me.0.listening.store(false, Ordering::Relaxed);
            if me.0.cancel.load(Ordering::Relaxed) || samples.is_none() {
                me.set_transcript("", true);
                return;
            }
            let samples = samples.unwrap();
            if samples.len() < 16_000 / 3 {
                me.set_transcript("", true);
                return;
            }
            let m2 = me.clone();
            rt.spawn(async move {
                m2.set_transcript("Transcribing…", false);
                let text = match m2.transcribe(&samples).await {
                    Ok(t) => t,
                    Err(e) => {
                        clinqy_core::log::write(&format!("voice: {e}"));
                        m2.set_transcript(&format!("Voice didn't work: {e}"), false);
                        String::new()
                    }
                };
                m2.set_transcript(&text, true);
            });
        });
    }

    /// Records 16 kHz mono until stopped (or, auto, until a pause after speech).
    fn record(&self, auto: Option<f64>) -> Option<Vec<f32>> {
        let host = cpal::default_host();
        let Some(device) = host.default_input_device() else {
            self.set_transcript("No microphone found", false);
            return None;
        };
        let config = device.default_input_config().ok()?;
        let rate = config.sample_rate().0 as f64;
        let channels = config.channels() as usize;
        let buf: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::new()));
        let level: Arc<Mutex<f32>> = Arc::new(Mutex::new(0.0));
        let (b2, l2) = (buf.clone(), level.clone());
        let push = move |data: &[f32]| {
            let mut sum = 0.0f32;
            let mut mono = Vec::with_capacity(data.len() / channels.max(1));
            for frame in data.chunks(channels.max(1)) {
                let s = frame.iter().sum::<f32>() / frame.len() as f32;
                sum += s * s;
                mono.push(s);
            }
            *l2.lock() = (sum / mono.len().max(1) as f32).sqrt();
            b2.lock().extend(mono);
        };
        let err = |e| clinqy_core::log::write(&format!("voice: microphone error {e}"));
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => device.build_input_stream(&config.clone().into(), move |d: &[f32], _: &_| push(d), err, None),
            cpal::SampleFormat::I16 => {
                let p = push;
                device.build_input_stream(&config.clone().into(), move |d: &[i16], _: &_| p(&d.iter().map(|s| *s as f32 / 32768.0).collect::<Vec<_>>()), err, None)
            }
            cpal::SampleFormat::U16 => {
                let p = push;
                device.build_input_stream(&config.clone().into(), move |d: &[u16], _: &_| p(&d.iter().map(|s| (*s as f32 - 32768.0) / 32768.0).collect::<Vec<_>>()), err, None)
            }
            _ => return None,
        }
        .ok()?;
        stream.play().ok()?;
        let started = Instant::now();
        let (mut heard, mut quiet_since) = (false, Instant::now());
        while !self.0.stop.load(Ordering::Relaxed) && started.elapsed() < Duration::from_secs(120) {
            std::thread::sleep(Duration::from_millis(50));
            let l = *level.lock();
            (self.0.on_level)((l * 12.0).min(1.0));
            if let Some(give_up) = auto {
                if l > 0.02 {
                    heard = true;
                    quiet_since = Instant::now();
                } else if heard && quiet_since.elapsed() > Duration::from_millis(1200) {
                    break;
                }
                if !heard && started.elapsed().as_secs_f64() > give_up {
                    self.0.cancel.store(true, Ordering::Relaxed);
                    break;
                }
            }
        }
        drop(stream);
        (self.0.on_level)(0.0);
        let raw = std::mem::take(&mut *buf.lock());
        // Linear resample to 16 kHz.
        let ratio = rate / 16_000.0;
        let n = (raw.len() as f64 / ratio) as usize;
        Some((0..n).map(|i| {
            let x = i as f64 * ratio;
            let j = x as usize;
            let f = (x - j as f64) as f32;
            raw.get(j).copied().unwrap_or(0.0) * (1.0 - f) + raw.get(j + 1).copied().unwrap_or(0.0) * f
        }).collect())
    }

    async fn transcribe(&self, samples: &[f32]) -> anyhow::Result<String> {
        if !self.ready() {
            self.prepare().await?;
        } else {
            self.ensure_server().await?;
        }
        *self.0.last_used.lock() = Instant::now();
        let wav = wav(samples);
        let part = reqwest::multipart::Part::bytes(wav).file_name("audio.wav").mime_str("audio/wav")?;
        let form = reqwest::multipart::Form::new().part("file", part).text("response_format", "json").text("temperature", "0.0");
        let r: serde_json::Value = reqwest::Client::new().post(format!("http://127.0.0.1:{PORT}/inference")).multipart(form).timeout(Duration::from_secs(60)).send().await?.json().await?;
        let text = r["text"].as_str().unwrap_or("").trim().to_string();
        // Whisper's stock hallucinations on silence.
        let junk = ["[BLANK_AUDIO]", "(silence)", "[ Silence ]", "Thank you.", "Thanks for watching!"];
        Ok(if junk.iter().any(|j| text.eq_ignore_ascii_case(j)) { String::new() } else { text })
    }

    /// Stops the local server after a while unused (it holds the model in memory).
    pub fn idle_check(&self) {
        if self.0.last_used.lock().elapsed() > Duration::from_secs(15 * 60) {
            if let Some(mut c) = self.0.server.lock().take() {
                let _ = c.kill();
            }
        }
    }
}

impl Drop for Inner {
    fn drop(&mut self) {
        if let Some(mut c) = self.server.lock().take() {
            let _ = c.kill();
        }
    }
}

/// 16-bit PCM WAV, 16 kHz mono.
fn wav(samples: &[f32]) -> Vec<u8> {
    let data: Vec<u8> = samples.iter().flat_map(|s| ((s.clamp(-1.0, 1.0) * 32767.0) as i16).to_le_bytes()).collect();
    let mut out = Vec::with_capacity(44 + data.len());
    out.extend(b"RIFF");
    out.extend((36 + data.len() as u32).to_le_bytes());
    out.extend(b"WAVEfmt ");
    out.extend(16u32.to_le_bytes());
    out.extend(1u16.to_le_bytes());
    out.extend(1u16.to_le_bytes());
    out.extend(16_000u32.to_le_bytes());
    out.extend(32_000u32.to_le_bytes());
    out.extend(2u16.to_le_bytes());
    out.extend(16u16.to_le_bytes());
    out.extend(b"data");
    out.extend((data.len() as u32).to_le_bytes());
    out.extend(data);
    out
}
