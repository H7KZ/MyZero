use rppal::gpio::{Gpio, InputPin};

/// Inicializuje GPIO pin jako vstupní (PIR senzor).
///
/// PIR pin je zachován pro případ kombinovaného použití
/// (hardware trigger + ONVIF event pro double-check).
pub fn init_pin(pin_number: u8) -> InputPin {
    Gpio::new()
        .expect("GPIO init selhal")
        .get(pin_number)
        .expect("Nelze získat GPIO pin")
        .into_input()
}

/// Vrátí `true` pokud PIR detekuje pohyb (pin je HIGH).
pub fn is_detected(pin: &InputPin) -> bool {
    pin.is_high()
}
