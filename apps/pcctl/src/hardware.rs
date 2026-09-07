//! The front-panel switch fallback, behind the `gpio` feature.
//!
//! Everything else in `pcctl` is pure std and runs anywhere; this is the one
//! part that needs `rppal` and therefore a Linux host. Without the feature the
//! same functions compile to a clear "not built in" message, so the CLI and the
//! HTTP API keep the same shape on every platform.
//!
//! Switches are claimed per actuation rather than held open for the process's
//! lifetime: outside a press the pin is an ordinary input, which is the state
//! the optocoupler reads as "button not pressed".

use crate::config;
use std::time::Duration;

/// What a press is meant to achieve — which decides the pulse length and
/// whether the caller has to confirm it.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Actuation {
    /// A tap on PWR_SW: powers an off machine on, or asks a running one to shut
    /// down gracefully via ACPI. Safe — it's the case button.
    Press,
    /// PWR_SW held past the ATX force-off threshold. Cuts power under the OS's
    /// feet and loses unsaved work.
    ForceOff,
    /// RESET_SW. Same abruptness as ForceOff, minus the power cycle.
    Reset,
}

impl Actuation {
    pub fn name(self) -> &'static str {
        match self {
            Actuation::Press => "press",
            Actuation::ForceOff => "force-off",
            Actuation::Reset => "reset",
        }
    }

    /// Actuations that destroy unsaved work need `confirm=<name>` in the
    /// request. A short press doesn't — it's what the case button does.
    pub fn needs_confirmation(self) -> bool {
        !matches!(self, Actuation::Press)
    }

    #[cfg_attr(not(feature = "gpio"), allow(dead_code))]
    fn hold(self) -> Duration {
        Duration::from_millis(match self {
            Actuation::Press => config::PRESS_MS,
            Actuation::ForceOff => config::FORCE_OFF_MS,
            Actuation::Reset => config::RESET_MS,
        })
    }

    #[cfg_attr(not(feature = "gpio"), allow(dead_code))]
    fn pin(self) -> Option<u8> {
        match self {
            Actuation::Press | Actuation::ForceOff => config::POWER_SW_GPIO_PIN,
            Actuation::Reset => config::RESET_SW_GPIO_PIN,
        }
    }
}

#[cfg(feature = "gpio")]
mod imp {
    use super::Actuation;
    use crate::config;
    use devices::powerswitch::{PowerLed, PowerSwitch};
    use std::time::Duration;

    pub fn actuate(what: Actuation) -> Result<String, String> {
        let Some(pin) = what.pin() else {
            return Err(format!(
                "{}: no GPIO wired (set {} in .env)",
                what.name(),
                match what {
                    Actuation::Reset => "RESET_SW_GPIO_PIN",
                    _ => "POWER_SW_GPIO_PIN",
                }
            ));
        };

        let cooldown = Duration::from_secs(config::PRESS_COOLDOWN_SECS);
        let mut switch =
            PowerSwitch::new(pin, cooldown).map_err(|e| format!("{}: {e}", what.name()))?;

        // The cooldown lives in the driver, but a switch built fresh for each
        // actuation has no memory of the last one — so the caller (control.rs)
        // holds the process-wide gate. This one is the in-actuation guard.
        let held = switch
            .actuate(what.hold())
            .map_err(|e| format!("{}: {e}", what.name()))?;

        Ok(format!(
            "{}: held BCM {pin} for {} ms",
            what.name(),
            held.as_millis()
        ))
    }

    /// `Some(true)` if the PC's power LED is lit, `None` if no LED is wired or
    /// the GPIO can't be read.
    pub fn power_led() -> Option<bool> {
        let pin = config::POWER_LED_GPIO_PIN?;
        PowerLed::new(pin, config::POWER_LED_INVERT)
            .ok()
            .map(|led| led.is_lit())
    }

    /// Drives every configured switch low, releasing anything a previous crash
    /// left asserted. Called once at service start.
    pub fn release_all() {
        let cooldown = Duration::from_secs(0);
        for pin in [config::POWER_SW_GPIO_PIN, config::RESET_SW_GPIO_PIN]
            .into_iter()
            .flatten()
        {
            // Construction drives the pin low; dropping it hands the pin back.
            match PowerSwitch::new(pin, cooldown) {
                Ok(_) => println!("[pcctl] released BCM {pin}"),
                Err(e) => eprintln!("[pcctl] could not release BCM {pin}: {e}"),
            }
        }
    }

    pub fn available() -> bool {
        config::POWER_SW_GPIO_PIN.is_some() || config::RESET_SW_GPIO_PIN.is_some()
    }
}

#[cfg(not(feature = "gpio"))]
mod imp {
    use super::Actuation;

    pub fn actuate(what: Actuation) -> Result<String, String> {
        Err(format!(
            "{}: this build has no GPIO support (built with --no-default-features)",
            what.name()
        ))
    }

    pub fn power_led() -> Option<bool> {
        None
    }

    pub fn release_all() {}

    pub fn available() -> bool {
        false
    }
}

pub use imp::{actuate, available, power_led, release_all};
