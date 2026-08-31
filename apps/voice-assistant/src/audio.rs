//! Microphone capture via cpal.
//!
//! Opens the default input device as **16 kHz mono i16** and streams samples
//! over a channel. rustpotter and Vosk both consume this exact format.
//!
//! On the Pi the input device is the USB sound card. If it can't natively do
//! 16 kHz mono, route it through an ALSA `plug` device (see the app README) —
//! cpal will then get resampled 16 kHz from ALSA.

use cpal::traits::{DeviceTrait, HostTrait, StreamTrait};
use std::sync::mpsc::{self, Receiver};

/// A running capture. Keep it alive — dropping it stops the stream.
pub struct Capture {
    _stream: cpal::Stream,
    /// Blocking iterator of sample buffers until the stream stops.
    pub rx: Receiver<Vec<i16>>,
}

/// Starts capturing at `sample_rate` Hz, mono, i16.
pub fn start(sample_rate: u32) -> Result<Capture, String> {
    let host = cpal::default_host();
    let device = host
        .default_input_device()
        .ok_or("no default input device (is the USB sound card plugged in?)")?;

    let config = cpal::StreamConfig {
        channels: 1,
        sample_rate: cpal::SampleRate(sample_rate),
        buffer_size: cpal::BufferSize::Default,
    };

    let (tx, rx) = mpsc::channel::<Vec<i16>>();

    let stream = device
        .build_input_stream(
            &config,
            move |data: &[i16], _: &cpal::InputCallbackInfo| {
                // Best-effort: if the consumer is gone the send just fails.
                let _ = tx.send(data.to_vec());
            },
            move |err| eprintln!("[audio] stream error: {err}"),
            None,
        )
        .map_err(|e| format!("cannot open input stream at {sample_rate} Hz mono i16: {e}"))?;

    stream.play().map_err(|e| e.to_string())?;
    Ok(Capture { _stream: stream, rx })
}
