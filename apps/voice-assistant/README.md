# voice-assistant

Offline, all-local voice assistant for the Pi Zero 2. Say the wake word, give a
Czech command, and the Pi acts — no cloud, no accounts, no tokens. The flagship
command boots a PC:

> **"Jarvis … zapni počítač"** → Pi sends a Wake-on-LAN magic packet → PC turns on.

There is deliberately **no LLM**. The task is a fixed command → action map, so it
runs in milliseconds on the Zero 2's CPU and stays completely private.

## Pipeline

```
 mic (USB card)
     │  16 kHz mono i16               [cpal]           src/audio.rs
     ▼
 wake word ──"Jarvis"?──►  rustpotter (.rpw model)     src/wake.rs
     │ yes
     ▼
 speech-to-text ──────────►  Vosk + small grammar      src/stt.rs
     │ transcript ("zapni počítač")
     ▼
 intent match ────────────►  Action                    src/intent.rs
     │
     ├─► Wake-on-LAN magic packet → PC                 src/wol.rs
     ├─► spoken reply  "Zapínám počítač."  [Piper]     src/tts.rs
     └─► LED / OLED status (optional)      [board-hal] src/feedback.rs
```

State machine (`src/main.rs`): **Idle** (feeding audio to the wake detector) →
**Listening** (transcribing until a pause or `LISTEN_TIMEOUT_SECS`) → act → Idle.

## Modules

| File | Responsibility | Key dependency |
|------|----------------|----------------|
| `audio.rs` | Mic capture → channel of i16 samples | `cpal` (ALSA) |
| `wake.rs` | Wake-word detection | `rustpotter` (pure Rust) |
| `stt.rs` | Grammar-constrained transcription | `vosk` (native `libvosk`) |
| `intent.rs` | Transcript → `Action`, holds the closed grammar | — |
| `wol.rs` | Build + send WoL magic packet (pure std, unit-tested) | — |
| `tts.rs` | Spoken replies via Piper CLI + `aplay` | external `piper` |
| `feedback.rs` | Optional LED + OLED status | `board-hal` |
| `config.rs` | Compile-time config baked from `.env` | `build.rs` |

## Hardware

- **USB sound card** on the micro-USB OTG port (mic + speaker). The Zero 2 has no
  analog audio; a USB card is the reliable path. Find it with `aplay -l` /
  `arecord -l` and set `APLAY_DEVICE` (e.g. `plughw:1,0`).
- Optional **LED** (`LED_GPIO_PIN`) lights while listening, and the shared
  **SH1106 OLED** (`ENABLE_OLED=true`) shows status — wiring in
  [`board-hal`](../../crates/board-hal/README.md).

## Models (gitignored — see [`models/`](models/README.md))

1. **Wake word** — train `models/jarvis.rpw` (below).
2. **STT** — download the small Czech Vosk model, unzip to
   `models/vosk-model-small-cs`.
3. **TTS** — download a Piper `cs_CZ` voice `.onnx` (+ `.onnx.json`).

### Train the wake word (on the Pi)

rustpotter trains from your own recordings — nothing leaves the device:

```sh
# record several "Jarvis" samples (16 kHz mono), then build a .rpw model
# using the rustpotter CLI. See: https://github.com/GiviMAD/rustpotter-cli
rustpotter-cli record jarvis1.wav          # repeat for a handful of takes
rustpotter-cli build --model-name Jarvis \
  --model-path models/jarvis.rpw jarvis*.wav
```

## Build

The voice deps link native libraries, so this app builds **on the Pi** (or a
cross image with the extras), unlike `departure-board`:

- `cpal` needs ALSA dev headers: `sudo apt install libasound2-dev`
- `vosk` needs `libvosk` (`libvosk.so`) on the linker path. Download the aarch64
  build from <https://alphacephei.com/vosk/> and, e.g.:
  ```sh
  sudo cp libvosk.so /usr/local/lib/ && sudo ldconfig
  ```

Then, natively on the Pi:

```sh
cp .env.example .env      # fill in WOL_TARGET_MAC etc.
cargo build --release -p voice-assistant
```

Cross-compiling instead? A [`Cross.toml`](../../Cross.toml) at the repo root adds
`libasound2-dev` to the image; you must still supply an aarch64 `libvosk` to the
container's linker path.

## Run

```sh
# from the repo root, using the Makefile
make ship BIN=voice-assistant && make run BIN=voice-assistant

# or directly on the Pi
./voice-assistant            # run the assistant (default)
./voice-assistant wol        # send the WoL packet once (test)
./voice-assistant wake-word  # print the configured wake word
```

The **PC side** needs WoL enabled once: BIOS "Wake on LAN", the NIC's
"Wake on Magic Packet" + "Allow this device to wake the computer", and Fast
Startup off (or wake from Sleep/Hibernate). Pi and PC must share the LAN subnet.

## Autostart (systemd)

A unit is provided at
[`provision/systemd/voice-assistant.service`](../../provision/systemd/voice-assistant.service):

```sh
sudo cp provision/systemd/voice-assistant.service /etc/systemd/system/
sudo systemctl enable --now voice-assistant
journalctl -fu voice-assistant
```

## `.env` reference

| Key | Meaning |
|-----|---------|
| `WAKE_WORD` | Informational label (detection uses the `.rpw` model). |
| `WAKEWORD_MODEL_PATH` | Path to the trained rustpotter model. |
| `VOSK_MODEL_PATH` | Unpacked Vosk model directory. |
| `AUDIO_SAMPLE_RATE` | Capture/recognition rate (16000). |
| `LISTEN_TIMEOUT_SECS` | Max seconds to transcribe after the wake word. |
| `PIPER_BIN` / `PIPER_VOICE` | Piper executable + voice `.onnx`. |
| `APLAY_DEVICE` | ALSA playback device; empty = default. |
| `LED_GPIO_PIN` | "Listening" LED (BCM); `0` = none. |
| `ENABLE_OLED` | `true`/`false` — drive the SH1106. |
| `WOL_TARGET_MAC` / `WOL_BROADCAST_ADDR` / `WOL_PORT` | Wake-on-LAN target. |

`.env` is **gitignored** (holds the real MAC); `.env.example` is the template.

## Add a command

1. Add the phrase to `GRAMMAR` in `intent.rs`.
2. Add a variant to `Action` + a branch in `match_intent`.
3. Implement it in `Action::execute` (return the Czech reply to speak).

## Troubleshooting

- **`no default input device`** — USB card not detected; check `arecord -l`.
- **Stream won't open at 16 kHz** — route through an ALSA `plug` device so ALSA
  resamples (set `APLAY_DEVICE`/default to `plughw:` via `~/.asoundrc`).
- **`cannot load Vosk model`** — wrong `VOSK_MODEL_PATH` or model not unzipped.
- **Wake word never fires** — retrain with more/cleaner samples; check mic gain.
- **PC doesn't wake** — verify with `./voice-assistant wol`; re-check BIOS/NIC WoL
  and that both devices are on the same subnet.
