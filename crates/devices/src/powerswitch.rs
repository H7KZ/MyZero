//! Front-panel switch actuation: "press the PC's power button" from a GPIO.
//!
//! Wire a Pi GPIO through an **optocoupler** to the motherboard's `PWR_SW`
//! header, in parallel with the case button. The optocoupler matters: it keeps
//! the Pi's ground and the PC's ground galvanically separate, which is what you
//! want between two boxes that each have their own PSU.
//!
//! This is the escape hatch for when Wake-on-LAN can't help — a Modern Standby
//! board that won't arm its NIC, a hung OS, a BIOS that forgot its settings
//! after a power cut. It presses the same button you would.
//!
//! # Safety
//!
//! A GPIO stuck high means the power button is held down forever: the PC either
//! force-offs or can never start. Four things guard against that, and one
//! residual risk is documented rather than hidden:
//!
//! 1. **Pin choice is validated.** At boot every Pi GPIO is an input, and
//!    BCM 0–8 come up with pull-*ups* while 9–27 come up with pull-*downs*.
//!    Using 0–8 would assert the optocoupler for the whole ~20 s from power-on
//!    until this program takes the pin, so [`PowerSwitch::new`] refuses them.
//! 2. **Construction drives the pin low** before anything else, releasing a
//!    press left over from a previous crash.
//! 3. **Every pulse is bounded** by [`MAX_HOLD`] and released by a `Drop` guard,
//!    so a panic mid-press still lets the button go.
//! 4. **A cooldown** rejects a second actuation too soon after the last, so a
//!    stuck client can't power-cycle the machine in a loop.
//!
//! Residual risk: `rppal` resets pins on drop, but `Drop` does not run if the
//! process is killed outright (`SIGKILL`). A kill landing inside the ~250 ms
//! press window would leave the button held. systemd's `Restart=always` brings
//! the service back within seconds and step 2 releases it — the worst case is a
//! hold long enough to force the PC off, not a permanently jammed button. Add
//! an external ~10 kΩ pull-down on the optocoupler's input if you want belt and
//! braces.

use rppal::gpio::{Gpio, InputPin, OutputPin};
use std::time::{Duration, Instant};

/// Longest any single actuation may assert the pin. A real ATX board force-offs
/// after ~4 s, so anything past this is a bug, not an intention.
pub const MAX_HOLD: Duration = Duration::from_secs(12);

/// Lowest BCM pin whose boot-time pull is *down*. See the safety notes above.
pub const MIN_SAFE_PIN: u8 = 9;

/// Why an actuation was refused.
#[derive(Debug)]
pub enum Error {
    /// BCM 0–8 float high at boot and would hold the button down.
    UnsafePin(u8),
    /// Another actuation happened too recently.
    Cooldown(Duration),
    /// The GPIO itself is unavailable (not a Pi, pin busy, no permission).
    Gpio(rppal::gpio::Error),
}

impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Error::UnsafePin(pin) => write!(
                f,
                "BCM {pin} boots with a pull-up and would hold the button down — use {MIN_SAFE_PIN}–27"
            ),
            Error::Cooldown(left) => {
                write!(f, "cooling down, {} s left", left.as_secs().max(1))
            }
            Error::Gpio(e) => write!(f, "GPIO unavailable: {e}"),
        }
    }
}

impl std::error::Error for Error {}

impl From<rppal::gpio::Error> for Error {
    fn from(e: rppal::gpio::Error) -> Self {
        Error::Gpio(e)
    }
}

/// One front-panel switch (`PWR_SW` or `RESET_SW`) behind an optocoupler.
///
/// Held only for the duration of an actuation: dropping it returns the pin to
/// an input, which the optocoupler reads as "not pressed".
pub struct PowerSwitch {
    pin: OutputPin,
    cooldown: Duration,
    last_release: Option<Instant>,
}

impl PowerSwitch {
    /// Claims `pin` (BCM) and immediately drives it low.
    ///
    /// Returns `Err` rather than panicking: this runs inside a long-lived
    /// service, where "no GPIO here" should degrade to a clear message rather
    /// than take the whole control API down.
    pub fn new(pin: u8, cooldown: Duration) -> Result<Self, Error> {
        if pin < MIN_SAFE_PIN {
            return Err(Error::UnsafePin(pin));
        }
        // into_output_low() drives the pin before returning, so this doubles as
        // "release anything a previous crash left asserted".
        let pin = Gpio::new()?.get(pin)?.into_output_low();
        Ok(Self {
            pin,
            cooldown,
            last_release: None,
        })
    }

    /// Asserts the switch for `hold`, clamped to [`MAX_HOLD`].
    ///
    /// Returns how long it was actually held.
    pub fn actuate(&mut self, hold: Duration) -> Result<Duration, Error> {
        if let Some(last) = self.last_release {
            let since = last.elapsed();
            if since < self.cooldown {
                return Err(Error::Cooldown(self.cooldown - since));
            }
        }

        let hold = hold.min(MAX_HOLD);
        {
            // The guard releases the pin on the way out of this scope — normal
            // return or unwinding panic alike.
            let _pressed = Pressed::assert(&mut self.pin);
            std::thread::sleep(hold);
        }
        self.last_release = Some(Instant::now());
        Ok(hold)
    }
}

/// Asserts a pin for as long as it is alive.
struct Pressed<'a>(&'a mut OutputPin);

impl<'a> Pressed<'a> {
    fn assert(pin: &'a mut OutputPin) -> Self {
        pin.set_high();
        Pressed(pin)
    }
}

impl Drop for Pressed<'_> {
    fn drop(&mut self) {
        self.0.set_low();
    }
}

/// The PC's front-panel power LED, read back through an optocoupler.
///
/// This is ground truth in a way a network probe isn't: it says whether the
/// machine has power, even when the OS is hung or still in POST. What it
/// *doesn't* say reliably is S3 — boards vary between off, lit, and a slow
/// pulse while asleep — so treat "lit" as "on", and read "dark" together with
/// the TCP probe rather than on its own.
pub struct PowerLed {
    pin: InputPin,
    invert: bool,
}

impl PowerLed {
    /// Claims `pin` (BCM) as a pulled-down input.
    ///
    /// `invert` flips the sense for a wiring where the optocoupler pulls the
    /// line low while the LED is lit — cheaper than resoldering.
    pub fn new(pin: u8, invert: bool) -> Result<Self, Error> {
        let pin = Gpio::new()?.get(pin)?.into_input_pulldown();
        Ok(Self { pin, invert })
    }

    /// Is the PC's power LED lit?
    pub fn is_lit(&self) -> bool {
        self.pin.is_high() != self.invert
    }
}
