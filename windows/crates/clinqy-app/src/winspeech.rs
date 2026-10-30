//! Voice through Windows' own speech service (VOICE_ENGINE=windows). It listens to the microphone itself, while
//! `voice.rs` keeps recording, so the same words can go to Whisper when this returns nothing or can't run.

use parking_lot::Mutex;
use std::sync::Arc;
use std::time::Duration;
use windows::core::{Interface, HSTRING};
use windows::Foundation::{TimeSpan, TypedEventHandler};
use windows::Media::SpeechRecognition::*;

/// Windows refuses dictation until "Online speech recognition" is on: audio then goes to Microsoft.
const PRIVACY_NOT_ACCEPTED: u32 = 0x8004_5509;

fn explain(e: windows::core::Error) -> String {
    if e.code().0 as u32 == PRIVACY_NOT_ACCEPTED {
        "turn on Online speech recognition in Windows Settings → Privacy & security → Speech".into()
    } else {
        format!("{} ({:#010x})", e.message(), e.code().0 as u32)
    }
}

fn run(stop: &dyn Fn() -> bool) -> windows::core::Result<String> {
    let recognizer = SpeechRecognizer::new()?;
    let dictation = SpeechRecognitionTopicConstraint::Create(SpeechRecognitionScenario::Dictation, &HSTRING::from("dictation"))?;
    recognizer.Constraints()?.Append(&dictation.cast::<ISpeechRecognitionConstraint>()?)?;
    recognizer.CompileConstraintsAsync()?.get()?;
    let session = recognizer.ContinuousRecognitionSession()?;
    // Long enough that only letting go of the keys ends it.
    session.SetAutoStopSilenceTimeout(TimeSpan { Duration: Duration::from_secs(600).as_nanos() as i64 / 100 })?;
    let heard = Arc::new(Mutex::new(Vec::<String>::new()));
    let sink = heard.clone();
    session.ResultGenerated(&TypedEventHandler::new(move |_, args: &Option<SpeechContinuousRecognitionResultGeneratedEventArgs>| {
        if let Some(args) = args {
            let text = args.Result()?.Text()?.to_string();
            if !text.is_empty() {
                sink.lock().push(text);
            }
        }
        Ok(())
    }))?;
    session.StartAsync()?.get()?;
    while !stop() {
        std::thread::sleep(Duration::from_millis(30));
    }
    session.StopAsync()?.get()?;
    let text = heard.lock().join(" ");
    Ok(text)
}

/// Listens until `stop` says so and returns what it heard.
pub fn listen(stop: &dyn Fn() -> bool) -> Result<String, String> {
    run(stop).map_err(explain)
}
