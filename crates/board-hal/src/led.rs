use rppal::gpio::{Gpio, OutputPin};

pub struct Led(OutputPin);

impl Led {
    pub fn new(pin: u8) -> Self {
        let pin = Gpio::new()
            .expect("GPIO init failed")
            .get(pin)
            .expect("Cannot get LED GPIO pin")
            .into_output_low();
        Led(pin)
    }

    pub fn on(&mut self) {
        self.0.set_high();
    }

    pub fn off(&mut self) {
        self.0.set_low();
    }
}
