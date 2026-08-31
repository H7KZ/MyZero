//! PIR motion sensor: read its digital OUT pin.

use rppal::gpio::{Gpio, InputPin};

/// Configures `pin` (BCM) as an input for the PIR sensor's OUT line.
pub fn init_pin(pin: u8) -> InputPin {
    Gpio::new()
        .expect("GPIO init failed")
        .get(pin)
        .expect("cannot get PIR GPIO pin")
        .into_input()
}

/// Returns `true` while the PIR reports motion (OUT is HIGH).
pub fn is_detected(pin: &InputPin) -> bool {
    pin.is_high()
}
