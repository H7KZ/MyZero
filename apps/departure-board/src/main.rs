mod api;
mod board;
mod config;

use devices::{button, display, led, motion};
use std::time::{Duration, Instant};

struct ActiveState {
    last_motion: Instant,
    last_fetch: Option<Instant>,
    stops: Vec<api::Stop>,
    current_stop: usize,
}

enum State {
    Idle,
    Active(ActiveState),
}

#[tokio::main]
async fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Err(e) = config::load(args) {
        eprintln!("[departure-board] config error: {e}");
        std::process::exit(1);
    }
    let cfg = config::get();

    println!("=== Departure Board ===");
    println!("Backend:       {}", cfg.backend_url);
    println!("Stop fallback: {}", cfg.stop_name);
    println!("Button pin:    {:?}", cfg.button_gpio_pin);
    println!("LED pin:       {:?}", cfg.led_gpio_pin);

    let client = reqwest::Client::new();
    let mut display = display::init();
    let pir = motion::init_pin(cfg.pir_gpio_pin);
    let mut button = cfg.button_gpio_pin.map(button::Button::new);
    let mut led = cfg.led_gpio_pin.map(led::Led::new);

    display::show_status(&mut display, "Cekam na pohyb...");

    let mut state = State::Idle;

    loop {
        let motion = motion::is_detected(&pir);
        let btn_pressed = button.as_mut().map(|b| b.pressed()).unwrap_or(false);

        state = match state {
            State::Idle => {
                if motion || btn_pressed {
                    println!("[WAKE] Display on");
                    if let Some(l) = &mut led {
                        l.on();
                    }
                    State::Active(ActiveState {
                        last_motion: Instant::now(),
                        last_fetch: None,
                        stops: vec![],
                        current_stop: 0,
                    })
                } else {
                    State::Idle
                }
            }

            State::Active(mut s) => {
                if motion || btn_pressed {
                    s.last_motion = Instant::now();
                }

                if s.last_motion.elapsed().as_secs() >= cfg.idle_timeout_secs {
                    println!("[IDLE] No motion for {}s — sleeping", cfg.idle_timeout_secs);
                    display::sleep(&mut display);
                    if let Some(l) = &mut led {
                        l.off();
                    }
                    State::Idle
                } else {
                    // Cycle stop on button press
                    if btn_pressed && !s.stops.is_empty() {
                        s.current_stop = (s.current_stop + 1) % s.stops.len();
                        println!("[BUTTON] Stop → {}", s.stops[s.current_stop].stop_name);
                        render_stop(&mut display, &s);
                    }

                    // Periodic fetch
                    let should_fetch = s
                        .last_fetch
                        .map(|t| t.elapsed().as_secs() >= cfg.poll_interval_secs)
                        .unwrap_or(true);

                    if should_fetch {
                        match api::fetch(&client).await {
                            Ok(data) => {
                                println!("[API] OK — {} stop(s)", data.stops.len());
                                s.stops = data.stops;
                                // Keep current index in bounds
                                if s.current_stop >= s.stops.len() {
                                    s.current_stop = 0;
                                }
                                if !s.stops.is_empty() {
                                    render_stop(&mut display, &s);
                                } else {
                                    display::show_status(&mut display, "Zadne odjezdy");
                                }
                            }
                            Err(e) => {
                                eprintln!("[API] Error: {e}");
                                display::show_status(&mut display, "Chyba spojeni");
                            }
                        }
                        s.last_fetch = Some(Instant::now());
                    }

                    State::Active(s)
                }
            }
        };

        tokio::time::sleep(Duration::from_millis(100)).await;
    }
}

fn render_stop(display: &mut display::Display, s: &ActiveState) {
    let stop = &s.stops[s.current_stop];
    let header = board::header(&stop.stop_name, s.current_stop, s.stops.len());
    let rows = board::render(&stop.departures, config::get().max_departures);
    display::render_board(display, &header, &rows);
}
