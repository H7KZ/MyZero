//! Optional visual feedback on the breadboard: a "listening" LED and the OLED.
//!
//! Both are optional so the assistant runs headless on any Pi. Hardware access
//! goes through the shared `devices` crate.

use devices::{display, led::Led};

pub struct Feedback {
    led: Option<Led>,
    display: Option<display::Display>,
}

impl Feedback {
    /// `led_pin` None = no LED; `oled` false = no display.
    pub fn init(led_pin: Option<u8>, oled: bool) -> Self {
        Self {
            led: led_pin.map(Led::new),
            display: oled.then(display::init),
        }
    }

    /// Wake word heard — listening for a command.
    pub fn listening(&mut self, wake_word: &str) {
        if let Some(l) = &mut self.led {
            l.on();
        }
        self.show(&format!("Poslouchám... ({wake_word})"));
    }

    /// Back to standby, waiting for the wake word.
    pub fn idle(&mut self, wake_word: &str) {
        if let Some(l) = &mut self.led {
            l.off();
        }
        self.show(&format!("Řekni \"{wake_word}\""));
    }

    /// Show a short status/reply line.
    pub fn show(&mut self, msg: &str) {
        if let Some(d) = &mut self.display {
            display::show_status(d, msg);
        }
    }
}
