// All values baked in at compile time from .env via build.rs

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

pub const BACKEND_URL: &str = env!("BACKEND_URL");
pub const BACKEND_API_KEY: &str = env!("BACKEND_API_KEY");
pub const BACKEND_TIMEOUT_SECS: u64 = parse_u64(env!("BACKEND_TIMEOUT_SECS"));

pub const PIR_GPIO_PIN: u8 = parse_u64(env!("PIR_GPIO_PIN")) as u8;
pub const IDLE_TIMEOUT_SECS: u64 = parse_u64(env!("IDLE_TIMEOUT_SECS"));
pub const POLL_INTERVAL_SECS: u64 = parse_u64(env!("POLL_INTERVAL_SECS"));

pub const STOP_NAME: &str = env!("STOP_NAME");
pub const MAX_DEPARTURES: usize = parse_u64(env!("MAX_DEPARTURES")) as usize;

/// BCM pin for stop-cycle button. None = no button.
pub const BUTTON_GPIO_PIN: Option<u8> = {
    let v = parse_u64(env!("BUTTON_GPIO_PIN"));
    if v == 0 {
        None
    } else {
        Some(v as u8)
    }
};

/// BCM pin for active-state LED. None = no LED.
pub const LED_GPIO_PIN: Option<u8> = {
    let v = parse_u64(env!("LED_GPIO_PIN"));
    if v == 0 {
        None
    } else {
        Some(v as u8)
    }
};
