mod config;
mod control;
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

fn or_unset(value: &str) -> &str {
    if value.trim().is_empty() {
        "(disabled)"
    } else {
        value
    }
}
