//! Offline speech-to-text via Vosk, constrained to a small grammar.
//!
//! Limiting recognition to a handful of fixed phrases (the intent grammar)
//! makes decoding fast and robust on the Zero 2 — the model only ever tries to
//! match the commands we understand, not open Czech.

use vosk::{DecodingState, Model, Recognizer};

pub struct Stt {
    // Model must outlive the recognizer that was built from it. The recognizer
    // holds no Rust borrow (its `new` returns no lifetime), so keeping both in
    // one struct is sound as long as the model isn't dropped first.
    _model: Model,
    rec: Recognizer,
}

impl Stt {
    /// Loads the Vosk model and builds a grammar-constrained recognizer.
    pub fn new(model_path: &str, sample_rate: f32, grammar: &[&str]) -> Result<Self, String> {
        let model =
            Model::new(model_path).ok_or_else(|| format!("cannot load Vosk model: {model_path}"))?;
        let rec = Recognizer::new_with_grammar(&model, sample_rate, grammar)
            .ok_or("cannot create Vosk recognizer")?;
        Ok(Self { _model: model, rec })
    }

    /// Feeds samples; returns `Some(text)` once an utterance finalizes
    /// (i.e. the speaker paused).
    pub fn accept(&mut self, samples: &[i16]) -> Option<String> {
        match self.rec.accept_waveform(samples) {
            Ok(DecodingState::Finalized) => {
                self.rec.result().single().map(|r| r.text.to_string())
            }
            _ => None,
        }
    }

    /// Forces a final result (used on listen-timeout).
    pub fn finalize(&mut self) -> Option<String> {
        self.rec.final_result().single().map(|r| r.text.to_string())
    }

    /// Clears state before a new utterance.
    pub fn reset(&mut self) {
        self.rec.reset();
    }
}
