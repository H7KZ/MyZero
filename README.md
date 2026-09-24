# MyZero — Pi Zero 2 playground

Personal Raspberry Pi Zero 2 WH playground: a Cargo workspace of small embedded apps sharing one hardware layer,
plus the OS provisioning that sets the Pi up.

## Layout

```
crates/
  devices/            OLED, LED, button, PIR motion, sound sensor, power-switch drivers
  net/                wake-on-lan + TCP liveness probe
  config/              runtime .env loader shared by all three apps ("appconfig")
apps/
  departure-board/    PIR-woken OLED public-transport departure board
  clapper/            clap on the sound sensor → Wake-on-LAN your PC
  pcctl/              wake / sleep / shut down the PC — CLI + HTTP control API
docs/                 setup + usage notes for the remote-PC-control system
provision/            OS setup/hardening (WiFi, hotspot, headless, systemd)
  pc/windows/         scripts that run on the *PC*: arm WoL, SSH power hook
Makefile              build / deploy / run helpers
AGENTS.md             instructions for coding agents working in this repo
```

Each part has its own README:
[devices](crates/devices/README.md) · [net](crates/net/README.md) · [config](crates/config/README.md) ·
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

When the network can't help — a board that won't arm its NIC, a hung OS — `pcctl press` closes a contact across
the motherboard's power-switch header through an optocoupler, exactly like the case button.

- [**docs/remote-pc-setup.md**](docs/remote-pc-setup.md) — the one-time build, end to end: BIOS, PC, router, Pi,
  Tailscale, the optional GPIO fallback, and the security review.
- [**docs/remote-pc-usage.md**](docs/remote-pc-usage.md) — the day-to-day version: Moonlight vs RDP, controllers,
  every way to build a wake button, latency tuning, and troubleshooting.

## Components on the breadboard

| Component                    | Bus / IO                          | Used by                             |
|------------------------------|------------------------------------|--------------------------------------|
| SH1106 128×64 OLED           | I2C1 (GPIO 2/3)                   | departure-board, clapper (optional) |
| PIR motion sensor (HC-SR501) | GPIO in (5 V vcc, 3.3 V out)      | departure-board                     |
| Push button                  | GPIO in, pull-up                  | departure-board                     |
| LED (+ 330 Ω)                | GPIO out                          | both (status)                       |
| KY-038 sound sensor          | D0 → GPIO in (5 V vcc; A0 unused) | clapper                             |

Pin numbers are configurable per app via its `.env`; wiring + BCM pin reference is
in [devices/README.md](crates/devices/README.md). All GPIO logic is 3.3 V; respect the ~50 mA total GPIO bank
limit.

## Build

```sh
make build                          # cross-compile the whole workspace for the Pi
make check                          # clippy + fmt

make ship BIN=departure-board       # build + scp a chosen app to the Pi
make run  BIN=clapper               # ssh + run it
```

All three apps cross-compile cleanly with plain `cross` — they're `rppal` GPIO + std (departure-board also
HTTP/JSON), no native audio/ML libraries. `pcctl` uses no GPIO at all, so it builds and runs on your laptop too.
The Rust HW crates (`rppal`, `sh1106`) are Linux-only, so on a Windows/macOS host only the pure-std parts build —
see [AGENTS.md](AGENTS.md) for the exact command.

## Config & secrets

Each app reads its config **at runtime** from a gitignored `.env` (via the shared [`config`](crates/config/README.md)
crate); a committed `.env.example` documents the keys and is each app's canonical key reference — see its own
README. `provision` uses the same pattern (`pizero.conf` gitignored, `pizero.conf.example` committed). Real
secrets — WiFi password, SSH key, the PC's MAC, the `pcctl` API token — never enter git, and no longer live inside
the binary either: editing config only needs a restart, not a rebuild.

## Status

| Piece                                               | State            |
|-----------------------------------------------------|------------------|
| Cargo workspace + `devices` / `net` / `config`      | ✅               |
| `departure-board`                                   | ✅ builds for Pi |
| `clapper` (clap → Wake-on-LAN)                      | ✅ builds for Pi |
| `pcctl` (wake / sleep / shutdown, CLI + HTTP API)   | ✅ builds + tested |
| `powerswitch` front-panel fallback (GPIO + opto)    | ⏳ needs wiring   |
| PC-side setup (`provision/pc/windows`)              | ⏳ needs a real PC |
| `provision/` OS setup (idempotent, re-run = update) | ✅               |
| Validate on real hardware (sensor wiring, PC WoL)   | ⏳               |
