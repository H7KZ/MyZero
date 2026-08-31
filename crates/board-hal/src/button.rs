use rppal::gpio::{Gpio, InputPin};

pub struct Button {
    pin: InputPin,
    was_high: bool,
}

impl Button {
    /// Pin wired: GPIO → button → GND. Uses internal pull-up (active LOW).
    pub fn new(pin_num: u8) -> Self {
        let pin = Gpio::new()
            .expect("GPIO init failed")
            .get(pin_num)
            .expect("Cannot get button GPIO pin")
            .into_input_pullup();
        Button {
            pin,
            was_high: false,
        }
    }

    /// Returns true once per press (rising edge on active-low: HIGH→LOW transition).
    pub fn pressed(&mut self) -> bool {
        let low = self.pin.is_low();
        let edge = !self.was_high && low;
        self.was_high = low;
        edge
    }
}
