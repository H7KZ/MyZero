mod config;
mod control;
mod hardware;
mod http;

/// Remote power control for the PC, from the Pi.
///
/// The Pi sits on the PC's LAN segment permanently and draws about a watt, so
/// it can do the one thing a VPN can't: put a layer-2 magic packet on the wire.
/// Everything else (probing, sleeping, shutting down) is layer 3 and rides SSH.
///
/// Usage:
///   pcctl status            is the PC up? (TCP knock on PC_PROBE_PORT)
///   pcctl wake [--wait]     send the magic packet; --wait blocks until it answers
///   pcctl sleep             run SLEEP_COMMAND on the PC
///   pcctl shutdown          run SHUTDOWN_COMMAND on the PC
///   pcctl press             tap the front-panel power switch (GPIO)
///   pcctl force-off --yes   hold it past the ATX cut-off — loses unsaved work
///   pcctl reset --yes       pulse the front-panel reset switch
///   pcctl serve             HTTP control API on LISTEN_ADDR
///   pcctl config            print the baked-in configuration
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let cmd = args.first().map(String::as_str).unwrap_or("status");
    let flags: Vec<&str> = args.iter().skip(1).map(String::as_str).collect();

    let outcome = match cmd {
        "status" => control::status(),
        "wake" => control::wake(flags.contains(&"--wait")),
        "sleep" => control::sleep(),
        "shutdown" => control::shutdown(),
        // --yes is the CLI spelling of the API's confirm=<verb>: a long press
        // cuts power under the OS's feet, so it is never one typo away.
        "press" => control::actuate(hardware::Actuation::Press, true),
        "force-off" => control::actuate(hardware::Actuation::ForceOff, flags.contains(&"--yes")),
        "reset" => control::actuate(hardware::Actuation::Reset, flags.contains(&"--yes")),
        "serve" => {
            if let Err(e) = http::serve() {
                eprintln!("[pcctl] serve failed: {e}");
                std::process::exit(1);
            }
            return;
        }
        "config" => {
            print_config();
            return;
        }
        "--help" | "-h" | "help" => {
            print_usage();
            return;
        }
        other => {
            eprintln!("unknown command: {other:?}");
            print_usage();
            std::process::exit(2);
        }
    };

    println!(
        "[{}] {}",
        if outcome.ok { "ok" } else { "fail" },
        outcome.message
    );
    if !outcome.ok {
        std::process::exit(1);
    }
}

fn print_usage() {
    eprintln!(
        "\
pcctl — remote power control for the PC

  pcctl status            is the PC up? (TCP knock on PC_PROBE_PORT)
  pcctl wake [--wait]     send the Wake-on-LAN magic packet
  pcctl sleep             run SLEEP_COMMAND on the PC
  pcctl shutdown          run SHUTDOWN_COMMAND on the PC
  pcctl press             tap the front-panel power switch (GPIO)
  pcctl force-off --yes   hold it past the ATX cut-off — loses unsaved work
  pcctl reset --yes       pulse the front-panel reset switch
  pcctl serve             HTTP control API on LISTEN_ADDR
  pcctl config            print the baked-in configuration

Configuration is baked in at compile time from apps/pcctl/.env."
    );
}

fn print_config() {
    println!("config source:  apps/pcctl/{}", config::CONFIG_SOURCE);
    println!("PC_MAC:         {}", config::PC_MAC);
    println!(
        "probe:          {}:{}",
        config::PC_HOST,
        config::PC_PROBE_PORT
    );
    println!(
        "wol:            {} ports {:?} ×{} bursts, from {}",
        config::wol_broadcasts().join(", "),
        config::wol_ports(),
        config::WOL_REPEAT,
        config::wol_bind().unwrap_or("(kernel picks interface)")
    );
    println!(
        "front panel:    {}",
        match (config::POWER_SW_GPIO_PIN, config::RESET_SW_GPIO_PIN) {
            (None, None) => "(no switch wired)".to_string(),
            (pwr, rst) => format!(
                "PWR_SW {}, RESET_SW {}, LED {} — press {} ms, force-off {} ms",
                pin(pwr),
                pin(rst),
                pin(config::POWER_LED_GPIO_PIN),
                config::PRESS_MS,
                config::FORCE_OFF_MS
            ),
        }
    );
    println!(
        "gpio support:   {}",
        if cfg!(feature = "gpio") {
            "compiled in"
        } else {
            "absent (--no-default-features build)"
        }
    );
    println!("sleep:          {}", or_unset(config::SLEEP_COMMAND));
    println!("shutdown:       {}", or_unset(config::SHUTDOWN_COMMAND));
    println!("listen:         {}", config::LISTEN_ADDR);
    println!(
        "api token:      {}",
        if config::API_TOKEN.trim().is_empty() {
            "(unset — serve refuses any non-loopback bind)"
        } else {
            "(set)"
        }
    );
    println!("wake timeout:   {}s", config::WAKE_TIMEOUT_SECS);
}

fn pin(value: Option<u8>) -> String {
    value.map_or_else(|| "off".to_string(), |p| format!("BCM {p}"))
}

fn or_unset(value: &str) -> &str {
    if value.trim().is_empty() {
        "(disabled)"
    } else {
        value
    }
}
