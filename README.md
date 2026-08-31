# MyZero — Pi Zero 2 playground

Personal Raspberry Pi Zero 2 WH playground: a Cargo workspace of small embedded apps sharing one hardware layer, plus
the OS provisioning that sets the Pi up.

## Layout

```
crates/
  devices/            OLED, LED, button, PIR motion, sound sensor drivers
  net/                wake-on-lan
apps/
  departure-board/    PIR-woken OLED public-transport departure board
  clapper/            clap on the sound sensor → Wake-on-LAN your PC
provision/            OS setup/hardening (WiFi, hotspot, headless, systemd)
Makefile              build / deploy / run helpers
```

Each part has its own README:
[devices](crates/devices/README.md) · [net](crates/net/README.md) ·
[departure-board](apps/departure-board/README.md) ·
[clapper](apps/clapper/README.md) · [provision](provision/README.md)

## Components on the breadboard

| Component                    | Bus / IO                          | Used by                             |
|------------------------------|-----------------------------------|-------------------------------------|
| SH1106 128×64 OLED           | I2C1 (GPIO 2/3)                   | departure-board, clapper (optional) |
| PIR motion sensor (HC-SR501) | GPIO in (5 V vcc, 3.3 V out)      | departure-board                     |
| Push button                  | GPIO in, pull-up                  | departure-board                     |
| LED (+ 330 Ω)                | GPIO out                          | both (status)                       |
| KY-038 sound sensor          | D0 → GPIO in (5 V vcc; A0 unused) | clapper                             |

Pin numbers are configurable per app via its `.env`; wiring + BCM pin reference is
in [devices/README.md](crates/devices/README.md). All GPIO logic is 3.3 V; respect the ~50 mA total GPIO bank limit.

## Build

```sh
make build                          # cross-compile the whole workspace for the Pi
make check                          # clippy + fmt

make ship BIN=departure-board       # build + scp a chosen app to the Pi
make run  BIN=clapper               # ssh + run it
```

Both apps cross-compile cleanly with plain `cross` — they're `rppal` GPIO + std (departure-board also HTTP/JSON), no
native audio/ML libraries. The Rust HW crates are Linux-only, so on a Windows/macOS host only `net`'s pure-std WoL unit
tests run (`cargo test -p net`).

## Config & secrets

Each app bakes config from a **gitignored `.env`** at compile time (via
`build.rs`); a committed `.env.example` documents the keys. `provision` uses the same pattern (`pizero.conf` gitignored,
`pizero.conf.example` committed). Real secrets — WiFi password, SSH key, the PC's MAC — never enter git.

## Status

| Piece                                               | State            |
|-----------------------------------------------------|------------------|
| Cargo workspace + `devices` / `net`                 | ✅               |
| `departure-board`                                   | ✅ builds for Pi |
| `clapper` (clap → Wake-on-LAN)                      | ✅ builds for Pi |
| `provision/` OS setup (idempotent, re-run = update) | ✅               |
| Validate on real hardware (sensor wiring, PC WoL)   | ⏳               |
