//! Offline text-to-speech via Piper, played through ALSA (`aplay`).
//!
//! Piper reads text on stdin and writes a WAV file; we then play it. Shelling
//! out keeps the heavy neural TTS in its own process, freeing the Zero 2's RAM
//! between replies.

use std::io::Write;
use std::process::{Command, Stdio};

/// Synthesizes `text` with `voice` and plays it. `aplay_device` empty = default.
pub fn speak(piper_bin: &str, voice: &str, aplay_device: &str, text: &str) -> std::io::Result<()> {
    let wav = std::env::temp_dir().join("voice-assistant-tts.wav");

    let mut piper = Command::new(piper_bin)
        .arg("--model")
        .arg(voice)
        .arg("--output_file")
        .arg(&wav)
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()?;

    piper
        .stdin
        .take()
        .expect("piper stdin")
        .write_all(text.as_bytes())?;
    piper.wait()?;

    let mut aplay = Command::new("aplay");
    if !aplay_device.is_empty() {
        aplay.arg("-D").arg(aplay_device);
    }
    aplay
        .arg(&wav)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()?;

    Ok(())
}
