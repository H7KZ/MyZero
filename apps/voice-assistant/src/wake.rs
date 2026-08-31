//! Wake-word detection via rustpotter (pure Rust, locally trained).
//!
//! The model is a `.rpw` file you train from your own recordings of the wake
//! word — so "Jarvis" works regardless of language and never touches a cloud.
//! rustpotter expects 16 kHz mono i16 and processes fixed-size frames.

use rustpotter::{Rustpotter, RustpotterConfig, RustpotterDetection};

pub struct WakeWord {
    rp: Rustpotter,
    frame: usize,
}

impl WakeWord {
    /// Loads the trained wake-word model. Default config is 16 kHz mono i16.
    pub fn new(model_path: &str) -> Result<Self, String> {
        let config = RustpotterConfig::default();
        let mut rp = Rustpotter::new(&config)?;
        rp.add_wakeword_from_file("wake", model_path)
            .map_err(|e| format!("cannot load wake-word model {model_path}: {e}"))?;
        let frame = rp.get_samples_per_frame();
        Ok(Self { rp, frame })
    }

    /// Number of i16 samples rustpotter wants per `process` call.
    pub fn samples_per_frame(&self) -> usize {
        self.frame
    }

    /// Processes exactly one frame; `Some(_)` means the wake word fired.
    pub fn process(&mut self, frame: Vec<i16>) -> Option<RustpotterDetection> {
        self.rp.process_samples(frame)
    }
}
