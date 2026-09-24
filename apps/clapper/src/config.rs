//! Runtime config: env vars, optionally filled in by a `.env` file (see
//! [`appconfig::Env`] for the lookup order). Loaded once at startup by
//! [`load`]; every other module reads it back through [`get`].

use appconfig::{ConfigError, Env};
use std::sync::OnceLock;

static CONFIG: OnceLock<Config> = OnceLock::new();

pub struct Config {
    // ── Sound sensor (clap trigger) ─────────────────────────────────────
    /// BCM pin wired to the sensor's D0 (digital threshold) output.
    pub sound_gpio_pin: u8,
    /// Claps required within the window to fire the action.
    pub clap_count: u32,
    /// Window (ms) the claps must all fall within.
    pub clap_window_ms: u64,
    /// Debounce (ms) that collapses one clap's burst of edges into a single count.
    pub clap_debounce_ms: u64,

    // ── Feedback hardware (optional) ────────────────────────────────────
    /// BCM pin for the status LED. None = no LED.
    pub led_gpio_pin: Option<u8>,
    /// Whether to drive the SH1106 OLED for status text.
    pub enable_oled: bool,

    // ── Wake-on-LAN target ──────────────────────────────────────────────
    /// MAC of the PC to wake, e.g. "D5-45-BC-0D-62-D0" (also accepts ':').
    pub wol_target_mac: String,
    /// Broadcast address for the magic packet (usually 255.255.255.255).
    pub wol_broadcast_addr: String,
    /// UDP port for the magic packet (conventionally 9, sometimes 7).
    pub wol_port: u16,
}

/// Loads config from the process environment plus an optional `.env` file
/// (`--config <path>` / `ENV_FILE`, else `.env` next to the binary or in the
/// CWD). Errors out with a clear message if a required key is missing or
/// unparseable.
pub fn load(args: impl IntoIterator<Item = String>) -> Result<(), ConfigError> {
    let env = Env::load(args);
    let config = Config {
        sound_gpio_pin: env.require_parse("SOUND_GPIO_PIN")?,
        clap_count: env.require_parse("CLAP_COUNT")?,
        clap_window_ms: env.require_parse("CLAP_WINDOW_MS")?,
        clap_debounce_ms: env.require_parse("CLAP_DEBOUNCE_MS")?,
        led_gpio_pin: env.optional_pin("LED_GPIO_PIN")?,
        enable_oled: env.bool_flag("ENABLE_OLED"),
        wol_target_mac: env.require("WOL_TARGET_MAC")?,
        wol_broadcast_addr: env.require("WOL_BROADCAST_ADDR")?,
        wol_port: env.require_parse("WOL_PORT")?,
    };
    let _ = CONFIG.set(config);
    Ok(())
}

/// The loaded config. Panics if called before [`load`] — every entry point
/// calls it first thing in `main`.
pub fn get() -> &'static Config {
    CONFIG.get().expect("config::load was not called")
}
