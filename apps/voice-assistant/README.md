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
     │  16 kHz mono i16                     [audio crate → cpal]
     ▼
 wake word ──"jarvis"?──►  Vosk (1-word grammar)      \
     │ yes                                             │ one shared
     ▼                                                 │ Vosk model
 command ────────────────►  Vosk (command grammar)    /   (src/speech.rs)
     │ transcript ("zapni počítač")
     ▼
 intent match ───────────►  Action                    src/intent.rs
     │
     ├─► Wake-on-LAN magic packet → PC                [net crate]
     ├─► spoken reply "Zapínám počítač."              src/tts.rs → Piper
     └─► LED / OLED status (optional)                 src/feedback.rs → devices
```

Both the wake word and the command are recognized by **one Vosk model** loaded
once (`src/speech.rs`) — the wake side uses a single-word grammar, the command
side the intent grammar. State machine (`src/main.rs`): **Idle** → **Listening**
(until a pause or `LISTEN_TIMEOUT_SECS`) → act → Idle.

## Modules

| File / crate | Responsibility |
|--------------|----------------|
| `audio` (crate) | Mic capture → channel of i16 samples (cpal) |
| `src/speech.rs` | Wake-word spotting + command recognition, one shared Vosk model |
| `src/intent.rs` | Transcript → `Action`, holds the closed grammar |
| `net` (crate) | `wol::send` — the Wake-on-LAN magic packet (unit-tested) |
| `src/tts.rs` | Spoken replies via Piper CLI + `aplay` |
| `src/feedback.rs` | Optional LED + OLED status (`devices` crate) |
| `src/config.rs` | Compile-time config baked from `.env` (`build.rs`) |

## Hardware

- **USB sound card** on the micro-USB OTG port (mic + speaker) — the Zero 2 has
  no analog audio. Find it with `aplay -l` / `arecord -l`; set `APLAY_DEVICE`
  (e.g. `plughw:1,0`).
- Optional **LED** (`LED_GPIO_PIN`) lights while listening, and the shared
  **SH1106 OLED** (`ENABLE_OLED=true`) shows status — wiring in
  [`devices`](../../crates/devices/README.md).

## Models (gitignored — see [`models/`](models/README.md))

1. **STT** — download the small Czech Vosk model, unzip to
   `models/vosk-model-small-cs`.
2. **TTS** — download a Piper `cs_CZ` voice `.onnx` (+ `.onnx.json`).

The **wake word** is just a word the Czech model transcribes: set `WAKE_WORD` to
its lowercase spelling (e.g. `jarvis`). No separate wake-word model to train.
(Vosk keyword-spotting is simple and dependency-light; if false triggers become
a problem, a dedicated wake engine can slot into `speech.rs` later.)

## Build

The voice deps link native libraries, so this app builds **on the Pi** (or a
cross image with the extras), unlike `departure-board`:

- `cpal` needs ALSA dev headers: `sudo apt install libasound2-dev`
- `vosk` needs `libvosk` (`libvosk.so`) on the linker path. Download the aarch64
  build from <https://alphacephei.com/vosk/> and:
  ```sh
  sudo cp libvosk.so /usr/local/lib/ && sudo ldconfig
  ```

Then, natively on the Pi:

```sh
cp .env.example .env      # fill in WOL_TARGET_MAC etc.
cargo build --release -p voice-assistant
```

Cross-compiling instead? The repo's [`Cross.toml`](../../Cross.toml) adds
`libasound2-dev` **and** downloads an aarch64 `libvosk` into the build image; the
same `libvosk.so` must also be present on the Pi at runtime.

## Run

```sh
make ship BIN=voice-assistant && make run BIN=voice-assistant   # from repo root

./voice-assistant            # run the assistant (default)
./voice-assistant wol        # send the WoL packet once (test)
./voice-assistant wake-word  # print the configured wake word
```

The **PC side** needs WoL enabled once: BIOS "Wake on LAN", the NIC's "Wake on
Magic Packet" + "Allow this device to wake the computer", and Fast Startup off
(or wake from Sleep/Hibernate). Pi and PC must share the LAN subnet.

## Autostart (systemd)

Unit at
[`provision/systemd/voice-assistant.service`](../../provision/systemd/voice-assistant.service):

```sh
sudo cp provision/systemd/voice-assistant.service /etc/systemd/system/
sudo systemctl enable --now voice-assistant
journalctl -fu voice-assistant
```

## `.env` reference

| Key | Meaning |
|-----|---------|
| `WAKE_WORD` | Wake word, lowercase as the Vosk model spells it. |
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
  resamples (set `APLAY_DEVICE`/default via `~/.asoundrc`).
- **`cannot load Vosk model`** — wrong `VOSK_MODEL_PATH` or model not unzipped.
- **Wake word never fires / misfires** — pick a word the cs model transcribes
  cleanly; check mic gain; adjust `WAKE_WORD` spelling to match its output.
- **PC doesn't wake** — verify with `./voice-assistant wol`; re-check BIOS/NIC WoL
  and that both devices share the subnet.
