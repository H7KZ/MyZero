//! Sound sensor (KY-038 / LM393): read its digital threshold output (D0).
//!
//! The module's onboard comparator drives D0 HIGH whenever the ambient sound
//! crosses a potentiometer-set threshold — a clap, a knock, a loud noise. It is
//! not a microphone: there is no waveform here, just a "loud enough" flag. The
//! analog pin (A0) is unusable on the Pi (no ADC), so we only read D0.

use rppal::gpio::{Gpio, InputPin};
use std::time::{Duration, Instant};

pub struct Sound {
    pin: InputPin,
    was_high: bool,
    last_clap: Instant,
    debounce: Duration,
}

impl Sound {
    /// D0 wired to `pin` (BCM). `debounce_ms` collapses the burst of fast edges
    /// a single clap produces into one detection.
    pub fn new(pin: u8, debounce_ms: u64) -> Self {
        let pin = Gpio::new()
            .expect("GPIO init failed")
            .get(pin)
            .expect("cannot get sound-sensor GPIO pin")
            .into_input();
        Sound {
            pin,
            was_high: false,
            last_clap: Instant::now(),
            debounce: Duration::from_millis(debounce_ms),
        }
    }

    /// Returns `true` once per clap: a LOW→HIGH edge on D0, ignoring edges that
    /// land within the debounce window of the previous clap.
    pub fn clapped(&mut self) -> bool {
        let high = self.pin.is_high();
        let rising = high && !self.was_high;
        self.was_high = high;

        if rising && self.last_clap.elapsed() >= self.debounce {
            self.last_clap = Instant::now();
            true
        } else {
            false
        }
    }
}
