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
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = config::load(args.iter().cloned()) {
        eprintln!("[clapper] config error: {e}");
        std::process::exit(1);
    }

    let cmd = args.get(1).cloned().unwrap_or_else(|| "run".into());
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
        config::get().clap_count,
        config::get().clap_window_ms
    );

    let cfg = config::get();
    let mut fb = feedback::Feedback::init(cfg.led_gpio_pin, cfg.enable_oled);
    let mut sound = Sound::new(cfg.sound_gpio_pin, cfg.clap_debounce_ms);
    let window = Duration::from_millis(cfg.clap_window_ms);

    // Timestamps of the claps still inside the rolling window.
    let mut claps: VecDeque<Instant> = VecDeque::new();
    fb.idle(cfg.clap_count);

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
            fb.idle(cfg.clap_count);
        }

        if sound.clapped() {
            claps.push_back(now);
            let n = claps.len() as u32;
            println!("[clap] {n}/{}", cfg.clap_count);
            fb.clap(n, cfg.clap_count);

            if n >= cfg.clap_count {
                trigger(&mut fb);
                claps.clear();
                fb.idle(cfg.clap_count);
            }
        }

        std::thread::sleep(Duration::from_millis(5));
    }
}

/// The clap pattern matched — send the magic packet.
fn trigger(fb: &mut feedback::Feedback) {
    let cfg = config::get();
    println!("[trigger] Wake-on-LAN → {}", cfg.wol_target_mac);
    let msg = match wol::send(&cfg.wol_target_mac, &cfg.wol_broadcast_addr, cfg.wol_port) {
        Ok(()) => "Zapinam pocitac",
        Err(e) => {
            eprintln!("[wol] {e}");
            "WoL selhal"
        }
    };
    fb.triggered(msg);
}

fn send_wol() {
    let cfg = config::get();
    println!(
        "[WoL] {} → {}:{}",
        cfg.wol_target_mac, cfg.wol_broadcast_addr, cfg.wol_port
    );
    match wol::send(&cfg.wol_target_mac, &cfg.wol_broadcast_addr, cfg.wol_port) {
        Ok(()) => println!("[WoL] magic packet sent"),
        Err(e) => {
            eprintln!("[WoL] failed: {e}");
            std::process::exit(1);
        }
    }
}
