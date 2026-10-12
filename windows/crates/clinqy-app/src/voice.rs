//! Voice: hold the hotkey and talk, release to send — transcribed on this PC by Whisper (whisper.cpp, the same
//! model family the Mac app runs). The first use downloads whisper.cpp and the model into
//! %LOCALAPPDATA%\Clinqy\voice. Each request is transcribed with Whisper's audio window sized to what was said (a
//! 3-second request costs a tenth of the usual 30-second window), so it takes a second or two on a laptop CPU.
//! Nothing leaves the PC.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use parking_lot::Mutex;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::{Duration, Instant};

/// whisper.cpp's Windows build, pinned.
const WHISPER_ZIP: &str = "https://github.com/ggml-org/whisper.cpp/releases/download/b5130/whisper-bin-x64.zip";

type LevelFn = Box<dyn Fn(f32) + Send + Sync>;
type TextFn = Box<dyn Fn(String, bool) + Send + Sync>;

struct Inner {
    listening: AtomicBool,
    cancel: AtomicBool,
    stop: AtomicBool,
    transcript: Mutex<String>,
    on_level: LevelFn,
    on_text: TextFn,
}

#[derive(Clone)]
pub struct Voice(Arc<Inner>);

fn dir() -> PathBuf {
    let d = clinqy_core::paths::local_dir().join("voice");
    let _ = std::fs::create_dir_all(&d);
    d
}

/// The model: `small` by default — on a CPU it's the best accuracy that still answers in a second or two
/// (large-v3-turbo, the Mac's model, needs Apple's Neural Engine or a GPU to be quick). WHISPER_MODEL picks another
/// ggml model (base, medium, large-v3-turbo-q5_0…); the Mac's WhisperKit names in a shared env file mean the default.
fn model_name() -> String {
    match clinqy_core::config::value("WHISPER_MODEL") {
        Some(m) if !m.contains("_632MB") && !m.contains("v20240930") => m.trim_start_matches("ggml-").trim_end_matches(".bin").to_string(),
        _ => "small-q5_1".into(),
    }
}

fn model_path() -> PathBuf {
    dir().join(format!("ggml-{}.bin", model_name()))
}

fn cli_exe() -> PathBuf {
    dir().join("whisper").join("whisper-cli.exe")
}

/// The voice language (tray menu; saved in the env file): en (default), hinglish, hi, auto, or any Whisper code.
pub fn language_setting() -> String {
    clinqy_core::config::value("VOICE_LANGUAGE").unwrap_or_else(|| "en".into()).to_lowercase()
}

/// The tray's choices: (setting, label).
pub const LANGUAGES: [(&str, &str); 6] = [
    ("en", "English"),
    ("hinglish", "Hinglish (Hindi + English)"),
    ("hi", "Hindi"),
    ("es", "Spanish"),
    ("fr", "French"),
    ("auto", "Detect automatically (slower)"),
];

/// Whisper's language and prompt. "auto" detects it every time, which costs a full extra pass (slower).
fn language() -> (String, Option<&'static str>) {
    match language_setting().as_str() {
        "hinglish" => ("en".into(), Some("Hinglish: Hindi and English mixed, written in English letters.")),
        "" => ("en".into(), None),
        other => (other.to_string(), None),
    }
}

async fn download(url: &str, to: &std::path::Path, label: &str, on_progress: &(dyn Fn(String) + Sync)) -> anyhow::Result<()> {
    use futures_util::StreamExt;
    use tokio::io::AsyncWriteExt;
    let client = reqwest::Client::builder().timeout(Duration::from_secs(3600)).build()?;
    let resp = client.get(url).send().await?.error_for_status()?;
    let total = resp.content_length().unwrap_or(0);
    let tmp = to.with_extension("part");
    let mut file = tokio::fs::File::create(&tmp).await?;
    let (mut got, mut last) = (0u64, Instant::now());
    let mut stream = resp.bytes_stream();
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
        cli_exe().is_file() && model_path().is_file()
    }

    /// Gets whisper.cpp and the model, once.
    async fn prepare(&self) -> anyhow::Result<()> {
        let progress = |m: String| {
            *self.0.transcript.lock() = m.clone();
            (self.0.on_text)(m, false);
        };
        if !cli_exe().is_file() {
            progress("Setting up voice (once): downloading Whisper…".into());
            let zip = dir().join("whisper.zip");
            download(WHISPER_ZIP, &zip, "Whisper", &progress).await?;
            let out = dir().join("whisper");
            let _ = std::fs::create_dir_all(&out);
            let mut archive = zip::ZipArchive::new(std::fs::File::open(&zip)?)?;
            for i in 0..archive.len() {
                let mut f = archive.by_index(i)?;
                let name = f.name().rsplit('/').next().unwrap_or("").to_string();
                if name == "whisper-cli.exe" || (name.ends_with(".dll") && (name.starts_with("ggml") || name == "whisper.dll")) {
                    std::io::copy(&mut f, &mut std::fs::File::create(out.join(&name))?)?;
                }
            }
            let _ = std::fs::remove_file(zip);
        }
        if !model_path().is_file() {
            let url = format!("https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-{}.bin", model_name());
            progress(format!("Setting up voice (once): downloading the {} model…", model_name()));
            download(&url, &model_path(), "the voice model", &progress).await?;
        }
        Ok(())
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
        // The download happens while the user is still talking, the first time.
        if !self.ready() {
            let m = self.clone();
            rt.spawn(async move {
                let _ = m.prepare().await;
            });
        }
        std::thread::spawn(move || {
            let samples = me.record(auto);
            me.0.listening.store(false, Ordering::Relaxed);
            let samples = match samples {
                Some(s) if !me.0.cancel.load(Ordering::Relaxed) && s.len() >= 16_000 / 3 => s,
                _ => {
                    me.set_transcript("", true);
                    return;
                }
            };
            rt.spawn(async move {
                me.set_transcript("Transcribing…", false);
                let text = match me.transcribe(&samples).await {
                    Ok(t) => t,
                    Err(e) => {
                        clinqy_core::log::write(&format!("voice: {e}"));
                        me.set_transcript(&format!("Voice didn't work: {e}"), false);
                        String::new()
                    }
                };
                me.set_transcript(&text, true);
            });
        });
    }

    /// Records 16 kHz mono until stopped (or, auto, until a pause after speech).
    fn record(&self, auto: Option<f64>) -> Option<Vec<f32>> {
        let device = match cpal::default_host().default_input_device() {
            Some(d) => d,
            None => {
                self.set_transcript("No microphone found", false);
                return None;
            }
        };
        let config = device.default_input_config().ok()?;
        let rate = config.sample_rate().0 as f64;
        let channels = (config.channels() as usize).max(1);
        let buf: Arc<Mutex<Vec<f32>>> = Arc::new(Mutex::new(Vec::new()));
        let level: Arc<Mutex<f32>> = Arc::new(Mutex::new(0.0));
        let (b2, l2) = (buf.clone(), level.clone());
        let push = move |data: &[f32]| {
            let mut sum = 0.0f32;
            let mut mono = Vec::with_capacity(data.len() / channels);
            for frame in data.chunks(channels) {
                let s = frame.iter().sum::<f32>() / frame.len() as f32;
                sum += s * s;
                mono.push(s);
            }
            *l2.lock() = (sum / mono.len().max(1) as f32).sqrt();
            b2.lock().extend(mono);
        };
        let err = |e| clinqy_core::log::write(&format!("voice: microphone error {e}"));
        let cfg: cpal::StreamConfig = config.clone().into();
        let stream = match config.sample_format() {
            cpal::SampleFormat::F32 => device.build_input_stream(&cfg, move |d: &[f32], _: &_| push(d), err, None),
            cpal::SampleFormat::I16 => device.build_input_stream(&cfg, move |d: &[i16], _: &_| push(&d.iter().map(|s| *s as f32 / 32768.0).collect::<Vec<_>>()), err, None),
            cpal::SampleFormat::U16 => device.build_input_stream(&cfg, move |d: &[u16], _: &_| push(&d.iter().map(|s| (*s as f32 - 32768.0) / 32768.0).collect::<Vec<_>>()), err, None),
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
        Some(resample(&raw, rate))
    }

    async fn transcribe(&self, samples: &[f32]) -> anyhow::Result<String> {
        if !self.ready() {
            self.prepare().await?;
        }
        let file = std::env::temp_dir().join(format!("clinqy-voice-{}.wav", std::process::id()));
        std::fs::write(&file, wav(samples))?;
        // Whisper's encoder costs the same for 3 seconds as for 30 unless told how much audio there is
        // (1500 frames = 30 s); a little headroom keeps the last word.
        let secs = samples.len() as f64 / 16_000.0;
        let ctx = (((secs + 1.5) / 30.0 * 1500.0) as u32).clamp(160, 1500);
        let (lang, prompt) = language();
        let threads = std::thread::available_parallelism().map(|n| (n.get() / 2).clamp(2, 8)).unwrap_or(4).to_string();
        let mut cmd = tokio::process::Command::new(cli_exe());
        cmd.args(["-m", &model_path().display().to_string(), "-f", &file.display().to_string(), "-l", &lang, "-t", &threads, "-nt", "-np"]);
        if ctx < 1500 {
            cmd.args(["-ac", &ctx.to_string()]);
        }
        if let Some(p) = prompt {
            cmd.args(["--prompt", p]);
        }
        let out = cmd.current_dir(dir().join("whisper")).creation_flags(0x0800_0000).kill_on_drop(true).output().await?;
        let _ = std::fs::remove_file(&file);
        if !out.status.success() {
            anyhow::bail!("Whisper failed: {}", String::from_utf8_lossy(&out.stderr).lines().last().unwrap_or(""));
        }
        let text = String::from_utf8_lossy(&out.stdout).split_whitespace().collect::<Vec<_>>().join(" ");
        // Whisper's stock hallucinations on silence.
        let junk = ["[BLANK_AUDIO]", "(silence)", "[ Silence ]", "Thank you.", "Thanks for watching!", "you"];
        Ok(if junk.iter().any(|j| text.eq_ignore_ascii_case(j)) { String::new() } else { text })
    }

    /// Transcribes a WAV file (16-bit PCM, any rate, mono or stereo): `clinqy transcribe`.
    pub async fn transcribe_file(&self, path: &std::path::Path) -> anyhow::Result<String> {
        let bytes = std::fs::read(path)?;
        let (rate, channels, data) = parse_wav(&bytes).ok_or_else(|| anyhow::anyhow!("not a 16-bit PCM WAV file"))?;
        let mono: Vec<f32> = data.chunks(channels).map(|f| f.iter().sum::<f32>() / channels as f32).collect();
        self.transcribe(&resample(&mono, rate as f64)).await
    }
}

/// Linear resample to 16 kHz.
fn resample(raw: &[f32], rate: f64) -> Vec<f32> {
    let ratio = rate / 16_000.0;
    let n = (raw.len() as f64 / ratio) as usize;
    (0..n)
        .map(|i| {
            let x = i as f64 * ratio;
            let j = x as usize;
            let f = (x - j as f64) as f32;
            raw.get(j).copied().unwrap_or(0.0) * (1.0 - f) + raw.get(j + 1).copied().unwrap_or(0.0) * f
        })
        .collect()
}

fn parse_wav(b: &[u8]) -> Option<(u32, usize, Vec<f32>)> {
    if b.len() < 44 || &b[0..4] != b"RIFF" || &b[8..12] != b"WAVE" {
        return None;
    }
    let (mut i, mut rate, mut channels, mut bits) = (12usize, 0u32, 1usize, 16u16);
    while i + 8 <= b.len() {
        let id = &b[i..i + 4];
        let size = u32::from_le_bytes(b[i + 4..i + 8].try_into().ok()?) as usize;
        let body = &b[i + 8..(i + 8 + size).min(b.len())];
        if id == b"fmt " {
            channels = u16::from_le_bytes(body[2..4].try_into().ok()?) as usize;
            rate = u32::from_le_bytes(body[4..8].try_into().ok()?);
            bits = u16::from_le_bytes(body[14..16].try_into().ok()?);
        } else if id == b"data" {
            if bits != 16 {
                return None;
            }
            let s = body.chunks_exact(2).map(|c| i16::from_le_bytes([c[0], c[1]]) as f32 / 32768.0).collect();
            return Some((rate, channels.max(1), s));
        }
        i += 8 + size + (size & 1);
    }
    None
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
