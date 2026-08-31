# board-hal

Shared hardware layer for the Pi Zero 2 breadboard IO. Thin wrappers over
`rppal` (GPIO) and `sh1106`/`embedded-graphics` (OLED). Every function takes
pin numbers (BCM) as parameters — no app config baked in — so any app in the
workspace reuses them.

## Modules

| Module | Type / fn | Wraps | Purpose |
|--------|-----------|-------|---------|
| `led` | `Led::new(pin)`, `.on()`, `.off()` | `rppal` OutputPin | Drive an indicator LED. |
| `button` | `Button::new(pin)`, `.pressed()` | `rppal` InputPin (pull-up) | Debounced-ish edge read; `pressed()` is true once per HIGH→LOW. |
| `motion` | `init_pin(pin)`, `is_detected(&pin)` | `rppal` InputPin | Read a PIR sensor's digital OUT. |
| `display` | `init()`, `render_board()`, `show_status()`, `sleep()` | `sh1106` + `embedded-graphics` | 128×64 SH1106 OLED over I2C (`/dev/i2c-1`). |

`display` uses `FONT_6X10` with the `iso_8859_2` (Latin-2) glyph set, so full
Czech diacritics render. 21 chars × 5 rows fit the 128×64 panel.

## Wiring reference

All logic is 3.3 V. GPIO pins can source/sink ~16 mA each, **50 mA total across
the bank** — keep LED currents low (≈5 mA each via the resistors below) if many
are on at once.

| Peripheral | Signal | Pi pin (BCM) | Notes |
|------------|--------|--------------|-------|
| SH1106 OLED | VCC | 3.3 V (pin 1) | — |
| | GND | GND (pin 6) | |
| | SDA | GPIO 2 (pin 3) | I2C1 data (on-board pull-up) |
| | SCL | GPIO 3 (pin 5) | I2C1 clock (on-board pull-up) |
| PIR (HC-SR501) | VCC | 5 V (pin 2/4) | needs 5 V; **OUT is 3.3 V** — safe to GPIO |
| | OUT | any GPIO | set repeatable-trigger (H) mode |
| | GND | GND | |
| Button | leg A | any GPIO | internal pull-up, active-LOW |
| | leg B | GND | GPIO → button → GND |
| LED | anode | any GPIO → 330 Ω | red/yellow ~2.0 Vf; blue/white/violet ~3.0 Vf |
| | cathode | GND | |

Enable I2C once on the Pi: `sudo raspi-config` → Interface Options → I2C → reboot.

## Consumers

- [`departure-board`](../../apps/departure-board) — PIR + OLED + button + LED
- [`voice-assistant`](../../apps/voice-assistant) — optional LED + OLED feedback

## Note

`rppal` and `sh1106`/`linux-embedded-hal` are Linux-only; this crate compiles as
part of a cross build for the Pi, not on a Windows/macOS host.
