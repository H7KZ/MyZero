//! Vosk speech: wake-word spotting and command recognition from one model.
//!
//! Both jobs use the same loaded Vosk model — loaded once and shared between
//! two recognizers — so the 512 MB Pi holds ~40 MB of acoustic model, not 80.
//! Each recognizer is grammar-constrained (the wake word, or the command
//! phrases), which keeps decoding fast and misfire-resistant.

use vosk::{DecodingState, Model, Recognizer};

pub struct Speech {
    // Owned here so it outlives the recognizers built from it. The recognizers
    // hold no Rust borrow (Vosk's `new` returns no lifetime), so sharing one
    // model across both is sound as long as it isn't dropped first.
    _model: Model,
    wake: Recognizer,
    wake_word: String,
    command: Recognizer,
}

impl Speech {
    /// Loads the model once and builds both recognizers.
    ///
    /// `wake_word` must match the model's spelling of it (lowercase, e.g.
    /// "jarvis"); `grammar` is the closed set of command phrases.
    pub fn new(
        model_path: &str,
        sample_rate: f32,
        wake_word: &str,
        grammar: &[&str],
    ) -> Result<Self, String> {
        let model =
            Model::new(model_path).ok_or_else(|| format!("cannot load Vosk model: {model_path}"))?;
        let wake = Recognizer::new_with_grammar(&model, sample_rate, &[wake_word])
            .ok_or("cannot create wake-word recognizer")?;
        let command = Recognizer::new_with_grammar(&model, sample_rate, grammar)
            .ok_or("cannot create command recognizer")?;
        Ok(Self {
            _model: model,
            wake,
            wake_word: wake_word.to_lowercase(),
            command,
        })
    }

    /// Feeds standby audio; returns `true` when the wake word is heard.
    pub fn detect_wake(&mut self, samples: &[i16]) -> bool {
        match self.wake.accept_waveform(samples) {
            Ok(DecodingState::Finalized) => text_of(self.wake.result()).contains(&self.wake_word),
            _ => false,
        }
    }

    /// Clears command state before a new utterance.
    pub fn reset_command(&mut self) {
        self.command.reset();
    }

    /// Feeds command audio; returns `Some(text)` once the speaker pauses.
    pub fn accept_command(&mut self, samples: &[i16]) -> Option<String> {
        match self.command.accept_waveform(samples) {
            Ok(DecodingState::Finalized) => Some(text_of(self.command.result())),
            _ => None,
        }
    }

    /// Forces a final command result (used on listen-timeout).
    pub fn finalize_command(&mut self) -> String {
        text_of(self.command.final_result())
    }
}

/// Pulls the recognized text out of a Vosk result (empty if none).
fn text_of(result: vosk::CompleteResult<'_>) -> String {
    result.single().map(|r| r.text.to_string()).unwrap_or_default()
}
