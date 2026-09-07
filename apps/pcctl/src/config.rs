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

/// Which file build.rs read (".env" or the ".env.example" fallback).
pub const CONFIG_SOURCE: &str = env!("PCCTL_CONFIG_SOURCE");

// ── Target PC ─────────────────────────────────────────────────────────────
/// MAC of the PC's wired NIC, e.g. "D5-45-BC-0D-62-D0" (also accepts ':').
pub const PC_MAC: &str = env!("PC_MAC");
/// Hostname or IP for the liveness probe.
pub const PC_HOST: &str = env!("PC_HOST");
/// TCP port that proves the PC is usable (22 / 3389 / 47989).
pub const PC_PROBE_PORT: u16 = parse_u16(env!("PC_PROBE_PORT"));

// ── Wake-on-LAN ───────────────────────────────────────────────────────────
const WOL_BROADCASTS: &str = env!("WOL_BROADCASTS");
const WOL_PORTS: &str = env!("WOL_PORTS");
const WOL_BIND: &str = env!("WOL_BIND");
/// Bursts of magic packets to send per wake.
pub const WOL_REPEAT: u32 = parse_u32(env!("WOL_REPEAT"));

/// Broadcast addresses to spray the magic packet at, in order.
pub fn wol_broadcasts() -> Vec<&'static str> {
    split_list(WOL_BROADCASTS)
}

/// UDP ports to send to; falls back to the conventional 9 + 7.
pub fn wol_ports() -> Vec<u16> {
    let ports: Vec<u16> = split_list(WOL_PORTS)
        .iter()
        .filter_map(|p| p.parse().ok())
        .collect();
    if ports.is_empty() {
        net::wol::DEFAULT_PORTS.to_vec()
    } else {
        ports
    }
}

/// Local IP to send from, pinning the outgoing interface. `None` = kernel picks.
pub fn wol_bind() -> Option<&'static str> {
    let b = WOL_BIND.trim();
    (!b.is_empty()).then_some(b)
}

// ── Power-down commands ───────────────────────────────────────────────────
/// Shell command line for `pcctl sleep`. Empty = verb disabled.
pub const SLEEP_COMMAND: &str = env!("SLEEP_COMMAND");
/// Shell command line for `pcctl shutdown`. Empty = verb disabled.
pub const SHUTDOWN_COMMAND: &str = env!("SHUTDOWN_COMMAND");
/// Seconds before a power-down command is killed.
pub const COMMAND_TIMEOUT_SECS: u64 = parse_u64(env!("COMMAND_TIMEOUT_SECS"));

// ── HTTP control API ──────────────────────────────────────────────────────
/// `ip:port` the `serve` subcommand binds.
pub const LISTEN_ADDR: &str = env!("LISTEN_ADDR");
/// Bearer token for the HTTP API; empty = no auth (loopback only).
pub const API_TOKEN: &str = env!("API_TOKEN");
/// Seconds `--wait` polls for the PC to answer on `PC_PROBE_PORT`.
pub const WAKE_TIMEOUT_SECS: u64 = parse_u64(env!("WAKE_TIMEOUT_SECS"));

/// Splits a comma-separated config value, dropping blanks.
fn split_list(raw: &'static str) -> Vec<&'static str> {
    raw.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .collect()
}
