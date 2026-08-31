# MyZero — Pi Zero 2 playground

Personal Raspberry Pi Zero 2 WH playground. A Cargo workspace of small embedded
apps sharing one hardware layer, plus the OS provisioning that sets the Pi up.

## Layout

```
crates/
  board-hal/          shared HW wrappers: OLED, LED, button, PIR motion
apps/
  departure-board/    PIR-woken OLED public-transport departure board
  voice-assistant/    (WIP) offline Czech voice → actions (WoL, …)  ← Phase 4
provision/            OS setup/hardening scripts (from PiZero2Installation) ← Phase 2
```

## Hardware (breadboard)

Pi Zero 2 WH + SH1106 128×64 OLED (I2C), PIR motion sensor, buttons, LEDs,
and — for the voice assistant — a USB sound card (mic + speaker), RFID (RC522).

## Build

```sh
# build everything for the Pi (cross-compile)
make build

# lint + format check
make check
```

Per-app details live in each app's own README (e.g.
[apps/departure-board/README.md](apps/departure-board/README.md)).
