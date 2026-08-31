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

/// Local wake word (handled by rustpotter, not the STT model).
pub const WAKE_WORD: &str = env!("WAKE_WORD");

/// MAC of the PC to wake, e.g. "D8-43-AE-5A-89-A6" (also accepts ':').
pub const WOL_TARGET_MAC: &str = env!("WOL_TARGET_MAC");

/// Broadcast address to send the magic packet to (usually 255.255.255.255).
pub const WOL_BROADCAST_ADDR: &str = env!("WOL_BROADCAST_ADDR");

/// UDP port for the magic packet (conventionally 9, sometimes 7).
pub const WOL_PORT: u16 = parse_u16(env!("WOL_PORT"));
