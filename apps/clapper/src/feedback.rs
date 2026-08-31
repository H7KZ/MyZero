//! Optional visual feedback: a status LED and the SH1106 OLED.
//!
//! Both are optional so clapper runs headless on any Pi. Hardware access goes
//! through the shared `devices` crate.

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

    /// Standby, waiting for the first clap.
    pub fn idle(&mut self, clap_count: u32) {
        self.led_off();
        self.show(&format!("Tleskni {clap_count}x"));
    }

    /// A clap was counted (`n` of `total` within the window).
    pub fn clap(&mut self, n: u32, total: u32) {
        self.led_on();
        self.show(&format!("Tlesk {n}/{total}"));
    }

    /// The clap pattern fired the action.
    pub fn triggered(&mut self, msg: &str) {
        self.led_on();
        self.show(msg);
    }

    fn led_on(&mut self) {
        if let Some(l) = &mut self.led {
            l.on();
        }
    }

    fn led_off(&mut self) {
        if let Some(l) = &mut self.led {
            l.off();
        }
    }

    fn show(&mut self, msg: &str) {
        if let Some(d) = &mut self.display {
            display::show_status(d, msg);
        }
    }
}
