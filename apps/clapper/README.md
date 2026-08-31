# clapper

Clap-activated Wake-on-LAN for the Pi Zero 2. Clap a few times and the Pi boots your PC — no cloud, no accounts, no
microphone, no tokens.

> **clap · clap** → Pi sends a Wake-on-LAN magic packet → PC turns on.

## How it works

A **KY-038 sound sensor** (LM393 comparator) drives its **D0** pin HIGH whenever a sound crosses a knob-set threshold.
clapper counts those pulses: `CLAP_COUNT`
claps within `CLAP_WINDOW_MS` fire the action.

```
 sound sensor D0 ──edge──►  clap counter (window + debounce)   src/main.rs
                                 │  N claps within the window
                                 ▼
                          Wake-on-LAN magic packet → PC          [net crate]
                          + LED / OLED status (optional)         src/feedback.rs → devices
```

> The sensor is **not** a microphone — D0 is only a "loud enough" flag and A0
> (analog) is unusable on the Pi (no ADC). So this is a clap switch, not speech.
> Real voice commands would need a proper USB or I2S mic (deliberately out of
> scope — YAGNI).

## Modules

| File / crate      | Responsibility                                           |
|-------------------|----------------------------------------------------------|
| `devices::sound`  | Read the sensor's D0 pin, debounced per clap             |
| `src/main.rs`     | Clap-counting loop → trigger                             |
| `net` (crate)     | `wol::send` — the Wake-on-LAN magic packet (unit-tested) |
| `src/feedback.rs` | Optional LED + OLED status (`devices` crate)             |
| `src/config.rs`   | Compile-time config baked from `.env` (`build.rs`)       |

## Hardware

Sensor: `+ → 5V`, `G → GND`, `D0 → SOUND_GPIO_PIN` (BCM). Leave `A0`
unconnected. Optional status **LED** (`LED_GPIO_PIN`) and the shared **SH1106 OLED** (`ENABLE_OLED=true`) — wiring in
[`devices`](../../crates/devices/README.md).

## Build & run

Pure GPIO + std, so it cross-compiles cleanly (no native libs):

```sh
cp .env.example .env      # set WOL_TARGET_MAC, SOUND_GPIO_PIN, …
make ship BIN=clapper && make run BIN=clapper   # from repo root

./clapper        # run the clap detector (default)
./clapper wol    # send the WoL packet once (test the PC wakes)
```

The **PC side** needs WoL enabled once: BIOS "Wake on LAN", the NIC's "Wake on Magic Packet" + "Allow this device to
wake the computer", and Fast Startup off (or wake from Sleep/Hibernate). Pi and PC must share the LAN subnet.

Tuning: raise `CLAP_DEBOUNCE_MS` if one clap counts twice; lower the sensor's potentiometer sensitivity if ambient noise
triggers it.

## Autostart (systemd)

Unit at
[`provision/systemd/clapper.service`](../../provision/systemd/clapper.service), or set `INSTALL_CLAPPER="yes"` in
`pizero.conf` and run the provisioner.

## `.env` reference

| Key                                                  | Meaning                                              |
|------------------------------------------------------|------------------------------------------------------|
| `SOUND_GPIO_PIN`                                     | BCM pin wired to the sensor's D0.                    |
| `CLAP_COUNT`                                         | Claps needed within the window to fire.              |
| `CLAP_WINDOW_MS`                                     | Window all claps must fall within.                   |
| `CLAP_DEBOUNCE_MS`                                   | Per-clap debounce (collapses one clap's edge burst). |
| `LED_GPIO_PIN`                                       | Status LED (BCM); `0` = none.                        |
| `ENABLE_OLED`                                        | `true`/`false` — drive the SH1106.                   |
| `WOL_TARGET_MAC` / `WOL_BROADCAST_ADDR` / `WOL_PORT` | Wake-on-LAN target.                                  |

`.env` is **gitignored** (holds the real MAC); `.env.example` is the template.
