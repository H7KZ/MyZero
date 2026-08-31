# MyZero — Pi Zero 2 playground

Personal Raspberry Pi Zero 2 WH playground: a Cargo workspace of small embedded
apps sharing one hardware layer, plus the OS provisioning that sets the Pi up.

## Layout

```
crates/
  board-hal/          shared HW wrappers: OLED, LED, button, PIR motion
apps/
  departure-board/    PIR-woken OLED public-transport departure board
  voice-assistant/    offline Czech voice → actions (wake word → WoL, …)
provision/            OS setup/hardening (WiFi, hotspot, headless, systemd)
Cross.toml            extras for cross-compiling to the Pi (ALSA)
Makefile              build / deploy / run helpers
```

Each part has its own README:
[board-hal](crates/board-hal/README.md) ·
[departure-board](apps/departure-board/README.md) ·
[voice-assistant](apps/voice-assistant/README.md) ·
[provision](provision/README.md)

## Components on the breadboard

| Component | Bus / IO | Used by |
|-----------|----------|---------|
| SH1106 128×64 OLED | I2C1 (GPIO 2/3) | departure-board, voice-assistant |
| PIR motion sensor (HC-SR501) | GPIO in (5 V vcc, 3.3 V out) | departure-board |
| Push button | GPIO in, pull-up | departure-board |
| LED (+ 330 Ω) | GPIO out | both (status) |
| USB sound card (mic + speaker) | micro-USB OTG | voice-assistant |

Pin numbers are configurable per app via its `.env`; wiring + BCM pin reference
is in [board-hal/README.md](crates/board-hal/README.md). All GPIO logic is
3.3 V; respect the ~50 mA total GPIO bank limit.

## Build

```sh
make build                          # cross-compile the whole workspace for the Pi
make check                          # clippy + fmt

make ship BIN=departure-board       # build + scp a chosen app to the Pi
make run  BIN=voice-assistant       # ssh + run it
```

`departure-board` cross-compiles cleanly. `voice-assistant` links native
libraries (`libvosk`, ALSA) — build it on the Pi or use `Cross.toml`; see its
README. The Rust HW crates are Linux-only, so nothing here compiles on a
Windows/macOS host except `voice-assistant`'s pure-std WoL/unit tests.

## Config & secrets

Each app bakes config from a **gitignored `.env`** at compile time (via
`build.rs`); a committed `.env.example` documents the keys. `provision` uses the
same pattern (`pizero.conf` gitignored, `pizero.conf.example` committed). Real
secrets — WiFi password, SSH key, the PC's MAC — never enter git.

## Status

| Phase | What | State |
|-------|------|-------|
| 1 | Cargo workspace + `board-hal` | ✅ |
| 2 | `provision/` OS setup merged in | ✅ |
| 3 | `voice-assistant` Wake-on-LAN | ✅ (tested on host) |
| 4 | Voice pipeline (wake word → STT → intent → TTS) | ✅ (builds on Pi) |
| — | Validate on real hardware (mic, models, PC WoL) | ⏳ |
