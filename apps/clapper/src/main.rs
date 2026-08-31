mod config;
mod feedback;

use devices::sound::Sound;
use net::wol;
use std::collections::VecDeque;
use std::time::{Duration, Instant};

/// Clap-activated Wake-on-LAN for the Pi Zero 2.
///
/// A KY-038 sound sensor's D0 pin fires on each loud clap; clap `CLAP_COUNT`
/// times within `CLAP_WINDOW_MS` and clapper sends a WoL magic packet to the PC.
///
/// Usage:
///   clapper        run the clap detector (default)
///   clapper run    run the clap detector
///   clapper wol    send the WoL magic packet once (test)
fn main() {
    let cmd = std::env::args().nth(1).unwrap_or_else(|| "run".into());
    match cmd.as_str() {
        "run" => run(),
        "wol" => send_wol(),
        other => {
            eprintln!("unknown command: {other:?} (try: run | wol)");
            std::process::exit(2);
        }
    }
}

fn run() {
    println!("=== Clapper ===");
    println!(
        "Clap {}x within {} ms → Wake-on-LAN",
        config::CLAP_COUNT,
        config::CLAP_WINDOW_MS
    );

    let mut fb = feedback::Feedback::init(config::LED_GPIO_PIN, config::ENABLE_OLED);
    let mut sound = Sound::new(config::SOUND_GPIO_PIN, config::CLAP_DEBOUNCE_MS);
    let window = Duration::from_millis(config::CLAP_WINDOW_MS);

    // Timestamps of the claps still inside the rolling window.
    let mut claps: VecDeque<Instant> = VecDeque::new();
    fb.idle(config::CLAP_COUNT);

    loop {
        let now = Instant::now();

        // Drop claps that have aged out of the window; reset feedback if the
        // partial sequence just expired.
        let had_claps = !claps.is_empty();
        while let Some(&oldest) = claps.front() {
            if now.duration_since(oldest) > window {
                claps.pop_front();
            } else {
                break;
            }
        }
        if had_claps && claps.is_empty() {
            fb.idle(config::CLAP_COUNT);
        }

        if sound.clapped() {
            claps.push_back(now);
            let n = claps.len() as u32;
            println!("[clap] {n}/{}", config::CLAP_COUNT);
            fb.clap(n, config::CLAP_COUNT);

            if n >= config::CLAP_COUNT {
                trigger(&mut fb);
                claps.clear();
                fb.idle(config::CLAP_COUNT);
            }
        }

        std::thread::sleep(Duration::from_millis(5));
    }
}

/// The clap pattern matched — send the magic packet.
fn trigger(fb: &mut feedback::Feedback) {
    println!("[trigger] Wake-on-LAN → {}", config::WOL_TARGET_MAC);
    let msg = match wol::send(
        config::WOL_TARGET_MAC,
        config::WOL_BROADCAST_ADDR,
        config::WOL_PORT,
    ) {
        Ok(()) => "Zapinam pocitac",
        Err(e) => {
            eprintln!("[wol] {e}");
            "WoL selhal"
        }
    };
    fb.triggered(msg);
}

fn send_wol() {
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
