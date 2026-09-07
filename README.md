# MyZero — Pi Zero 2 playground

Personal Raspberry Pi Zero 2 WH playground: a Cargo workspace of small embedded apps sharing one hardware layer, plus
the OS provisioning that sets the Pi up.

## Layout

```
crates/
  devices/            OLED, LED, button, PIR motion, sound sensor, power-switch drivers
  net/                wake-on-lan + TCP liveness probe
apps/
  departure-board/    PIR-woken OLED public-transport departure board
  clapper/            clap on the sound sensor → Wake-on-LAN your PC
  pcctl/              wake / sleep / shut down the PC — CLI + HTTP control API
docs/                 design + usage notes
provision/            OS setup/hardening (WiFi, hotspot, headless, systemd)
  pc/windows/         scripts that run on the *PC*: arm WoL, SSH power hook
Makefile              build / deploy / run helpers
```

Each part has its own README:
[devices](crates/devices/README.md) · [net](crates/net/README.md) ·
[departure-board](apps/departure-board/README.md) ·
[clapper](apps/clapper/README.md) · [pcctl](apps/pcctl/README.md) ·
[provision](provision/README.md) · [PC side](provision/pc/windows/README.md)

## Remote PC control

The Pi is always on and sits on the PC's LAN segment, so it can do the one thing a VPN can't: put a layer-2 magic
packet on the wire. `pcctl` turns that into a wake / sleep / shut-down button you can press from anywhere:

```
laptop ──Tailscale──▶ Pi ──magic packet──▶ PC ◀──Moonlight / RDP── laptop
                       └──ssh forced command──▶ sleep
```

When the network can't help — a board that won't arm its NIC, a hung OS — `pcctl press` closes a contact across the
motherboard's power-switch header through an optocoupler, exactly like the case button.

- [**docs/remote-pc-control.md**](docs/remote-pc-control.md) — the deep version: power states and why Fast Startup
  breaks WoL, ARP-cache failures, getting in from outside, remote-shutdown mechanics, the security review, and a
  step-by-step build order.
- [**docs/using-the-remote-pc.md**](docs/using-the-remote-pc.md) — the practical version: Moonlight vs RDP, game
  controllers, every way to build a wake button (phone shortcut, ESP32, Zigbee, a real button on the Pi), and latency
  tuning.
- [**docs/software-guide.md**](docs/software-guide.md) — what each piece of software actually is and how it works,
  the install order with a verification gate after every step, and what talks to what.

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

All three apps cross-compile cleanly with plain `cross` — they're `rppal` GPIO + std (departure-board also HTTP/JSON),
no native audio/ML libraries. `pcctl` uses no GPIO at all, so it builds and runs on your laptop too. The Rust HW crates
are Linux-only, so on a Windows/macOS host only the pure-std parts test (`cargo test -p net -p pcctl`).

## Config & secrets

Each app bakes config from a **gitignored `.env`** at compile time (via
`build.rs`); a committed `.env.example` documents the keys. `provision` uses the same pattern (`pizero.conf` gitignored,
`pizero.conf.example` committed). Real secrets — WiFi password, SSH key, the PC's MAC, the `pcctl` API token — never
enter git. `pcctl` additionally falls back to its `.env.example` when no `.env` exists, so a fresh clone still builds
(with a `cargo:warning` saying it used placeholders).

## Status

| Piece                                               | State            |
|-----------------------------------------------------|------------------|
| Cargo workspace + `devices` / `net`                 | ✅               |
| `departure-board`                                   | ✅ builds for Pi |
| `clapper` (clap → Wake-on-LAN)                      | ✅ builds for Pi |
| `pcctl` (wake / sleep / shutdown, CLI + HTTP API)   | ✅ builds + tested |
| `powerswitch` front-panel fallback (GPIO + opto)    | ⏳ needs wiring   |
| PC-side setup (`provision/pc/windows`)              | ⏳ needs a real PC |
| `provision/` OS setup (idempotent, re-run = update) | ✅               |
| Validate on real hardware (sensor wiring, PC WoL)   | ⏳               |
