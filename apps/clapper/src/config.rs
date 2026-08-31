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

// ── Sound sensor (clap trigger) ───────────────────────────────────────────
/// BCM pin wired to the sensor's D0 (digital threshold) output.
pub const SOUND_GPIO_PIN: u8 = parse_u16(env!("SOUND_GPIO_PIN")) as u8;
/// Claps required within the window to fire the action.
pub const CLAP_COUNT: u32 = parse_u32(env!("CLAP_COUNT"));
/// Window (ms) the claps must all fall within.
pub const CLAP_WINDOW_MS: u64 = parse_u64(env!("CLAP_WINDOW_MS"));
/// Debounce (ms) that collapses one clap's burst of edges into a single count.
pub const CLAP_DEBOUNCE_MS: u64 = parse_u64(env!("CLAP_DEBOUNCE_MS"));

// ── Feedback hardware (optional) ──────────────────────────────────────────
/// BCM pin for the status LED. None = no LED.
pub const LED_GPIO_PIN: Option<u8> = {
    let v = parse_u16(env!("LED_GPIO_PIN"));
    if v == 0 {
        None
    } else {
        Some(v as u8)
    }
};
/// Whether to drive the SH1106 OLED for status text.
pub const ENABLE_OLED: bool = matches!(env!("ENABLE_OLED").as_bytes(), b"true" | b"1" | b"yes");

// ── Wake-on-LAN target ────────────────────────────────────────────────────
/// MAC of the PC to wake, e.g. "D5-45-BC-0D-62-D0" (also accepts ':').
pub const WOL_TARGET_MAC: &str = env!("WOL_TARGET_MAC");
/// Broadcast address for the magic packet (usually 255.255.255.255).
pub const WOL_BROADCAST_ADDR: &str = env!("WOL_BROADCAST_ADDR");
/// UDP port for the magic packet (conventionally 9, sometimes 7).
pub const WOL_PORT: u16 = parse_u16(env!("WOL_PORT"));
