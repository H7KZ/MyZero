mod audio;
mod config;
mod feedback;
mod intent;
mod stt;
mod tts;
mod wake;
mod wol;

use std::time::{Duration, Instant};

/// Offline, all-local voice assistant for the Pi Zero 2.
///
/// Pipeline: mic (cpal) → wake word (rustpotter) → command (Vosk grammar)
///           → intent → action (Wake-on-LAN, …) + spoken reply (Piper).
///
/// Usage:
///   voice-assistant            run the assistant (default)
///   voice-assistant run        run the assistant
///   voice-assistant wol        send the WoL magic packet once
///   voice-assistant wake-word  print the configured wake word
fn main() {
    let cmd = std::env::args().nth(1).unwrap_or_else(|| "run".into());

    match cmd.as_str() {
        "run" => run(),
        "wol" => send_wol(),
        "wake-word" => println!("{}", config::WAKE_WORD),
        other => {
            eprintln!("unknown command: {other:?} (try: run | wol | wake-word)");
            std::process::exit(2);
        }
    }
}

fn send_wol() {
    println!(
        "[WoL] {} → {}:{}",
        config::WOL_TARGET_MAC,
        config::WOL_BROADCAST_ADDR,
        config::WOL_PORT
    );
    match wol::send(
        config::WOL_TARGET_MAC,
        config::WOL_BROADCAST_ADDR,
        config::WOL_PORT,
    ) {
        Ok(()) => println!("[WoL] magic packet sent"),
        Err(e) => {
            eprintln!("[WoL] failed: {e}");
            std::process::exit(1);
        }
    }
}

enum State {
    /// Standby: feeding audio to the wake-word detector.
    Idle,
    /// Wake word fired: transcribing a command until a pause or timeout.
    Listening { since: Instant },
}

fn run() {
    println!("=== voice-assistant ===");
    println!("Wake word: {}", config::WAKE_WORD);

    let mut fb = feedback::Feedback::init(config::LED_GPIO_PIN, config::ENABLE_OLED);
    let mut wake = wake::WakeWord::new(config::WAKEWORD_MODEL_PATH)
        .unwrap_or_else(|e| fatal("wake word", e));
    let mut stt = stt::Stt::new(
        config::VOSK_MODEL_PATH,
        config::AUDIO_SAMPLE_RATE as f32,
        intent::GRAMMAR,
    )
    .unwrap_or_else(|e| fatal("vosk", e));

    let capture = audio::start(config::AUDIO_SAMPLE_RATE).unwrap_or_else(|e| fatal("audio", e));
    // Keep `_stream` bound (not bare `_`) so the mic keeps running.
    let audio::Capture { _stream, rx } = capture;

    let frame_len = wake.samples_per_frame();
    let mut buf: Vec<i16> = Vec::with_capacity(frame_len * 2);
    let mut state = State::Idle;

    fb.idle(config::WAKE_WORD);
    println!("Ready. Say \"{}\".", config::WAKE_WORD);

    for chunk in rx {
        match state {
            State::Idle => {
                buf.extend_from_slice(&chunk);
                // rustpotter needs exactly one frame per call.
                while buf.len() >= frame_len {
                    let frame: Vec<i16> = buf.drain(..frame_len).collect();
                    if let Some(det) = wake.process(frame) {
                        println!("[wake] '{}' score={:.2}", det.name, det.score);
                        stt.reset();
                        buf.clear();
                        fb.listening(config::WAKE_WORD);
                        state = State::Listening {
                            since: Instant::now(),
                        };
                        break;
                    }
                }
            }
            State::Listening { since } => {
                if let Some(text) = stt.accept(&chunk) {
                    handle(&text, &mut fb);
                    fb.idle(config::WAKE_WORD);
                    state = State::Idle;
                } else if since.elapsed() >= Duration::from_secs(config::LISTEN_TIMEOUT_SECS) {
                    let text = stt.finalize().unwrap_or_default();
                    handle(&text, &mut fb);
                    fb.idle(config::WAKE_WORD);
                    state = State::Idle;
                }
            }
        }
    }
}

/// Transcript → intent → action + spoken reply.
fn handle(text: &str, fb: &mut feedback::Feedback) {
    let text = text.trim();
    println!("[stt] \"{text}\"");
    if text.is_empty() {
        return;
    }
    let reply = intent::match_intent(text).execute();
    println!("[reply] {reply}");
    fb.show(&reply);
    if let Err(e) = tts::speak(
        config::PIPER_BIN,
        config::PIPER_VOICE,
        config::APLAY_DEVICE,
        &reply,
    ) {
        eprintln!("[tts] {e}");
    }
}

fn fatal(what: &str, e: String) -> ! {
    eprintln!("[fatal] {what}: {e}");
    std::process::exit(1);
}
