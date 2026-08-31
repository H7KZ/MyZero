//! Intent matching: recognized Czech text → an [`Action`].
//!
//! [`GRAMMAR`] is the closed vocabulary handed to Vosk. Keeping it in lockstep
//! with the matcher is what makes recognition fast and misfire-resistant: the
//! recognizer can only ever return one of these phrases (or `[unk]`).

use crate::config;
use net::wol;

/// Phrases Vosk is allowed to recognize. `[unk]` catches everything else.
pub const GRAMMAR: &[&str] = &["zapni počítač", "vypni počítač", "[unk]"];

pub enum Action {
    /// Send a Wake-on-LAN magic packet to the configured PC.
    WakePc,
    /// Recognized nothing actionable.
    Unknown,
}

/// Maps a transcript to an action (lenient contains-matching).
pub fn match_intent(text: &str) -> Action {
    let t = text.trim().to_lowercase();
    if t.contains("zapni") && t.contains("počítač") {
        Action::WakePc
    } else {
        Action::Unknown
    }
}

impl Action {
    /// Runs the action and returns a Czech sentence to speak back.
    pub fn execute(&self) -> String {
        match self {
            Action::WakePc => {
                match wol::send(
                    config::WOL_TARGET_MAC,
                    config::WOL_BROADCAST_ADDR,
                    config::WOL_PORT,
                ) {
                    Ok(()) => "Zapínám počítač.".into(),
                    Err(e) => {
                        eprintln!("[wol] {e}");
                        "Nepodařilo se zapnout počítač.".into()
                    }
                }
            }
            Action::Unknown => "Nerozuměl jsem.".into(),
        }
    }
}
