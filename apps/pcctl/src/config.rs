//! Runtime config: env vars, optionally filled in by a `.env` file (see
//! [`appconfig::Env`] for the lookup order). Loaded once at startup by
//! [`load`]; every other module reads it back through [`get`].

use appconfig::{ConfigError, Env};
use std::sync::OnceLock;

static CONFIG: OnceLock<Config> = OnceLock::new();

pub struct Config {
    /// Where config actually came from — an `.env` path, or "environment"
    /// when no file was found.
    pub source: String,

    // ── Target PC ────────────────────────────────────────────────────────
    /// MAC of the PC's wired NIC, e.g. "D5-45-BC-0D-62-D0" (also accepts ':').
    pub pc_mac: String,
    /// Hostname or IP for the liveness probe.
    pub pc_host: String,
    /// TCP port that proves the PC is usable (22 / 3389 / 47989).
    pub pc_probe_port: u16,

    // ── Wake-on-LAN ──────────────────────────────────────────────────────
    /// Broadcast addresses to spray the magic packet at, in order.
    pub wol_broadcasts: Vec<String>,
    /// UDP ports to send to; falls back to the conventional 9 + 7.
    pub wol_ports: Vec<u16>,
    /// Local IP to send from, pinning the outgoing interface. `None` = kernel picks.
    pub wol_bind: Option<String>,
    /// Bursts of magic packets to send per wake.
    pub wol_repeat: u32,

    // ── Power-down commands ──────────────────────────────────────────────
    /// Shell command line for `pcctl sleep`. Empty = verb disabled.
    pub sleep_command: String,
    /// Shell command line for `pcctl shutdown`. Empty = verb disabled.
    pub shutdown_command: String,
    /// Seconds before a power-down command is killed.
    pub command_timeout_secs: u64,

    // ── Hardware fallback: the front-panel switch ───────────────────────
    /// BCM pin wired to PWR_SW through an optocoupler. `None` = not wired.
    pub power_sw_gpio_pin: Option<u8>,
    /// BCM pin wired to RESET_SW. `None` = not wired.
    pub reset_sw_gpio_pin: Option<u8>,
    /// BCM pin reading the front-panel power LED. `None` = not wired.
    pub power_led_gpio_pin: Option<u8>,
    /// True if the LED wiring pulls the line low while lit.
    #[cfg_attr(not(feature = "gpio"), allow(dead_code))]
    pub power_led_invert: bool,
    /// Short press — the ACPI power event (on, or graceful shutdown).
    pub press_ms: u64,
    /// Long press — the hard cut. Requires explicit confirmation.
    pub force_off_ms: u64,
    /// Reset pulse length.
    pub reset_ms: u64,
    /// Minimum gap between actuations.
    pub press_cooldown_secs: u64,

    // ── HTTP control API ─────────────────────────────────────────────────
    /// `ip:port` the `serve` subcommand binds.
    pub listen_addr: String,
    /// Bearer token for the HTTP API; empty = no auth (loopback only).
    pub api_token: String,
    /// Seconds `--wait` polls for the PC to answer on `pc_probe_port`.
    pub wake_timeout_secs: u64,
}

/// Loads config from the process environment plus an optional `.env` file
/// (`--config <path>` / `ENV_FILE`, else `.env` next to the binary or in the
/// CWD). Errors out with a clear message if a required key is missing or
/// unparseable.
pub fn load(args: impl IntoIterator<Item = String>) -> Result<(), ConfigError> {
    let args: Vec<String> = args.into_iter().collect();
    let env = Env::load(args.iter().cloned());

    let wol_ports: Vec<u16> = split_list(&env.get_or("WOL_PORTS", ""))
        .iter()
        .filter_map(|p| p.parse().ok())
        .collect();
    let wol_ports = if wol_ports.is_empty() {
        net::wol::DEFAULT_PORTS.to_vec()
    } else {
        wol_ports
    };

    let wol_bind = env.get_or("WOL_BIND", "");
    let wol_bind = (!wol_bind.trim().is_empty()).then(|| wol_bind.trim().to_string());

    let config = Config {
        source: env
            .source
            .as_ref()
            .map(|p| p.display().to_string())
            .unwrap_or_else(|| "environment (no .env file found)".to_string()),

        pc_mac: env.require("PC_MAC")?,
        pc_host: env.require("PC_HOST")?,
        pc_probe_port: env.require_parse("PC_PROBE_PORT")?,

        wol_broadcasts: split_list(&env.get_or("WOL_BROADCASTS", "")),
        wol_ports,
        wol_bind,
        wol_repeat: env.require_parse("WOL_REPEAT")?,

        sleep_command: env.get_or("SLEEP_COMMAND", ""),
        shutdown_command: env.get_or("SHUTDOWN_COMMAND", ""),
        command_timeout_secs: env.require_parse("COMMAND_TIMEOUT_SECS")?,

        power_sw_gpio_pin: env.optional_pin("POWER_SW_GPIO_PIN")?,
        reset_sw_gpio_pin: env.optional_pin("RESET_SW_GPIO_PIN")?,
        power_led_gpio_pin: env.optional_pin("POWER_LED_GPIO_PIN")?,
        power_led_invert: env.bool_flag("POWER_LED_INVERT"),
        press_ms: env.require_parse("PRESS_MS")?,
        force_off_ms: env.require_parse("FORCE_OFF_MS")?,
        reset_ms: env.require_parse("RESET_MS")?,
        press_cooldown_secs: env.require_parse("PRESS_COOLDOWN_SECS")?,

        listen_addr: env.require("LISTEN_ADDR")?,
        api_token: env.get_or("API_TOKEN", ""),
        wake_timeout_secs: env.require_parse("WAKE_TIMEOUT_SECS")?,
    };

    // pcctl's one hard security rule: refuse to even start configured to bind
    // a non-loopback address without a token. Checked here (not just in
    // http::serve) so `pcctl config` and every other verb see the same
    // validation up front.
    if config.api_token.trim().is_empty() && !is_loopback(&config.listen_addr) {
        return Err(ConfigError(format!(
            "refusing to configure LISTEN_ADDR={} without an API_TOKEN — set one in .env (openssl rand -hex 32)",
            config.listen_addr
        )));
    }

    let _ = CONFIG.set(config);
    Ok(())
}

/// The loaded config. Panics if called before [`load`] — every entry point
/// calls it first thing in `main`.
pub fn get() -> &'static Config {
    CONFIG.get().expect("config::load was not called")
}

/// Splits a comma-separated config value, dropping blanks.
fn split_list(raw: &str) -> Vec<String> {
    raw.split(',')
        .map(str::trim)
        .filter(|s| !s.is_empty())
        .map(str::to_string)
        .collect()
}

/// Is this bind address reachable only from the Pi itself?
fn is_loopback(addr: &str) -> bool {
    let host = addr.rsplit_once(':').map_or(addr, |(h, _)| h);
    let host = host.trim_start_matches('[').trim_end_matches(']');
    host == "localhost" || host == "::1" || host.starts_with("127.")
}
