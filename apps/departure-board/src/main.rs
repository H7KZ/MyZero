mod api;
mod board;
mod config;

use board_hal::{button, display, led, motion};
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
    println!("=== ZeroDepartureBoard ===");
    println!("Backend:       {}", config::BACKEND_URL);
    println!("Stop fallback: {}", config::STOP_NAME);
    println!("Button pin:    {:?}", config::BUTTON_GPIO_PIN);
    println!("LED pin:       {:?}", config::LED_GPIO_PIN);

    let client = reqwest::Client::new();
    let mut display = display::init();
    let pir = motion::init_pin(config::PIR_GPIO_PIN);
    let mut button = config::BUTTON_GPIO_PIN.map(button::Button::new);
    let mut led = config::LED_GPIO_PIN.map(led::Led::new);

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

                if s.last_motion.elapsed().as_secs() >= config::IDLE_TIMEOUT_SECS {
                    println!(
                        "[IDLE] No motion for {}s — sleeping",
                        config::IDLE_TIMEOUT_SECS
                    );
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
                        .map(|t| t.elapsed().as_secs() >= config::POLL_INTERVAL_SECS)
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
    let rows = board::render(&stop.departures, config::MAX_DEPARTURES);
    display::render_board(display, &header, &rows);
}
