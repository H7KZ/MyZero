//! Runtime config: env vars, optionally filled in by a `.env` file (see
//! [`appconfig::Env`] for the lookup order). Loaded once at startup by
//! [`load`]; every other module reads it back through [`get`].

use appconfig::{ConfigError, Env};
use std::sync::OnceLock;

static CONFIG: OnceLock<Config> = OnceLock::new();

pub struct Config {
    pub backend_url: String,
    pub backend_api_key: String,
    pub backend_timeout_secs: u64,

    pub pir_gpio_pin: u8,
    pub idle_timeout_secs: u64,
    pub poll_interval_secs: u64,

    pub stop_name: String,
    pub max_departures: usize,

    /// BCM pin for stop-cycle button. None = no button.
    pub button_gpio_pin: Option<u8>,
    /// BCM pin for active-state LED. None = no LED.
    pub led_gpio_pin: Option<u8>,
}

/// Loads config from the process environment plus an optional `.env` file
/// (`--config <path>` / `ENV_FILE`, else `.env` next to the binary or in the
/// CWD). Errors out with a clear message if a required key is missing or
/// unparseable.
pub fn load(args: impl IntoIterator<Item = String>) -> Result<(), ConfigError> {
    let env = Env::load(args);
    let config = Config {
        backend_url: env.require("BACKEND_URL")?,
        backend_api_key: env.get_or("BACKEND_API_KEY", ""),
        backend_timeout_secs: env.require_parse("BACKEND_TIMEOUT_SECS")?,
        pir_gpio_pin: env.require_parse("PIR_GPIO_PIN")?,
        idle_timeout_secs: env.require_parse("IDLE_TIMEOUT_SECS")?,
        poll_interval_secs: env.require_parse("POLL_INTERVAL_SECS")?,
        stop_name: env.require("STOP_NAME")?,
        max_departures: env.require_parse("MAX_DEPARTURES")?,
        button_gpio_pin: env.optional_pin("BUTTON_GPIO_PIN")?,
        led_gpio_pin: env.optional_pin("LED_GPIO_PIN")?,
    };
    let _ = CONFIG.set(config);
    Ok(())
}

/// The loaded config. Panics if called before [`load`] — every entry point
/// calls it first thing in `main`.
pub fn get() -> &'static Config {
    CONFIG.get().expect("config::load was not called")
}
