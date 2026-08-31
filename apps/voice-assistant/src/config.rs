// Compile-time config, baked from .env by build.rs.

const fn parse_u16(s: &str) -> u16 {
    let b = s.as_bytes();
    let mut v = 0u16;
    let mut i = 0;
    while i < b.len() {
        v = v * 10 + (b[i] - b'0') as u16;
        i += 1;
    }
    v
}

const fn parse_u32(s: &str) -> u32 {
    let b = s.as_bytes();
    let mut v = 0u32;
    let mut i = 0;
    while i < b.len() {
        v = v * 10 + (b[i] - b'0') as u32;
        i += 1;
    }
    v
}

const fn parse_u64(s: &str) -> u64 {
    let b = s.as_bytes();
    let mut v = 0u64;
    let mut i = 0;
    while i < b.len() {
        v = v * 10 + (b[i] - b'0') as u64;
        i += 1;
    }
    v
}

// ── Wake word ─────────────────────────────────────────────────────────────
/// Spoken wake word; must match the spelling the Vosk model returns (lowercase).
pub const WAKE_WORD: &str = env!("WAKE_WORD");

// ── Speech-to-text (Vosk) ─────────────────────────────────────────────────
/// Directory of the unpacked Vosk model (e.g. vosk-model-small-cs).
pub const VOSK_MODEL_PATH: &str = env!("VOSK_MODEL_PATH");
/// Capture + recognition sample rate. Vosk expects 16000 Hz mono.
pub const AUDIO_SAMPLE_RATE: u32 = parse_u32(env!("AUDIO_SAMPLE_RATE"));
/// Seconds to keep transcribing after the wake word before giving up.
pub const LISTEN_TIMEOUT_SECS: u64 = parse_u64(env!("LISTEN_TIMEOUT_SECS"));

// ── Text-to-speech (Piper) ────────────────────────────────────────────────
/// Piper executable (on PATH or absolute).
pub const PIPER_BIN: &str = env!("PIPER_BIN");
/// Piper voice model (.onnx), e.g. a cs_CZ voice.
pub const PIPER_VOICE: &str = env!("PIPER_VOICE");
/// ALSA device for playback (e.g. "plughw:1,0"). Empty = default device.
pub const APLAY_DEVICE: &str = env!("APLAY_DEVICE");

// ── Feedback hardware (optional) ──────────────────────────────────────────
/// BCM pin for the "listening" LED. None = no LED.
pub const LED_GPIO_PIN: Option<u8> = {
    let v = parse_u16(env!("LED_GPIO_PIN"));
    if v == 0 {
        None
    } else {
        Some(v as u8)
    }
};
/// Whether to drive the SH1106 OLED for status/partial text.
pub const ENABLE_OLED: bool = matches!(env!("ENABLE_OLED").as_bytes(), b"true" | b"1" | b"yes");

// ── Wake-on-LAN target ────────────────────────────────────────────────────
/// MAC of the PC to wake, e.g. "D8-43-AE-5A-89-A6" (also accepts ':').
pub const WOL_TARGET_MAC: &str = env!("WOL_TARGET_MAC");
/// Broadcast address for the magic packet (usually 255.255.255.255).
pub const WOL_BROADCAST_ADDR: &str = env!("WOL_BROADCAST_ADDR");
/// UDP port for the magic packet (conventionally 9, sometimes 7).
pub const WOL_PORT: u16 = parse_u16(env!("WOL_PORT"));
