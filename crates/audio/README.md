# audio

Microphone capture for the workspace, over [`cpal`](https://crates.io/crates/cpal).
On the Pi that's the USB sound card via ALSA.

## API

```rust
let capture = audio::start(16_000)?;   // 16 kHz mono i16
for chunk in capture.rx {              // blocking iterator of Vec<i16>
    // feed `chunk` to a recognizer…
}
```

`start(sample_rate)` opens the default input device as **mono i16** at the given
rate and streams sample buffers over a channel. Keep the returned `Capture`
alive — dropping it stops the stream.

## Notes

- 16 kHz mono i16 is what Vosk (and most on-device speech models) expect.
- If the USB card can't do 16 kHz natively, route it through an ALSA `plug`
  device so ALSA resamples; `start` then still sees 16 kHz.
- `cpal` needs ALSA dev headers to build (`libasound2-dev`); it links native
  audio libs, so this crate builds for the Pi, not on a Windows/macOS host.

Playback (for TTS) currently lives in the `voice-assistant` app via `aplay`; it
can move here if a second app needs it.
