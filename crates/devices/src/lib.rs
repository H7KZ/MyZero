//! Drivers for the Pi Zero 2's physical peripherals on the breadboard.
//!
//! Each module is a thin wrapper over `rppal`/`sh1106` and takes pin numbers
//! (BCM) as parameters — no app config baked in, so any app in the workspace
//! can reuse them.

pub mod button;
pub mod display;
pub mod led;
pub mod motion;
