mod config;
mod wol;

/// Phase 3: manual Wake-on-LAN trigger. Voice pipeline arrives in Phase 4.
///
/// Usage:
///   voice-assistant wol           send the magic packet (default)
///   voice-assistant wake-word     print the configured wake word
fn main() {
    let cmd = std::env::args().nth(1).unwrap_or_else(|| "wol".into());

    match cmd.as_str() {
        "wol" => {
            println!(
                "[WoL] {} → {}:{}",
                config::WOL_TARGET_MAC,
                config::WOL_BROADCAST_ADDR,
                config::WOL_PORT
            );
            match wol::send(
                config::WOL_TARGET_MAC,
                config::WOL_BROADCAST_ADDR,
                config::WOL_PORT,
            ) {
                Ok(()) => println!("[WoL] magic packet sent"),
                Err(e) => {
                    eprintln!("[WoL] failed: {e}");
                    std::process::exit(1);
                }
            }
        }
        "wake-word" => println!("{}", config::WAKE_WORD),
        other => {
            eprintln!("unknown command: {other:?} (try: wol | wake-word)");
            std::process::exit(2);
        }
    }
}
