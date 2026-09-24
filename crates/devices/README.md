# devices

Drivers for the Pi Zero 2's physical peripherals on the breadboard. Thin wrappers over `rppal` (GPIO) and `sh1106`/
`embedded-graphics` (OLED). Every function takes pin numbers (BCM) as parameters — no app config baked in — so any app
in the workspace reuses them.

## Modules

| Module    | API                                                    | Purpose                                                    |
|-----------|--------------------------------------------------------|------------------------------------------------------------|
| `led`     | `Led::new(pin)`, `.on()`, `.off()`                     | Drive an indicator LED.                                    |
| `button`  | `Button::new(pin)`, `.pressed()`                       | Read a button; `pressed()` is true once per HIGH→LOW edge. |
| `motion`  | `init_pin(pin)`, `is_detected(&pin)`                   | Read a PIR sensor's digital OUT.                           |
| `sound`   | `Sound::new(pin, debounce_ms)`, `.clapped()`           | Debounced clap detection off a KY-038 sensor's D0 pin.     |
| `display` | `init()`, `render_board()`, `show_status()`, `sleep()` | 128×64 SH1106 OLED over I2C (`/dev/i2c-1`).                |
| `powerswitch` | `PowerSwitch::new(pin, cooldown)`, `.actuate(hold)`, `PowerLed::new(pin, invert)`, `.is_lit()` | Press a PC's front-panel switch through an optocoupler; read its power LED back. |

`display` uses `FONT_6X10` with the `iso_8859_2` (Latin-2) glyph set, so full Czech diacritics render. 21 chars × 5 rows
fit the panel.

## Wiring reference

All logic is 3.3 V. GPIO pins source/sink ~16 mA each, **50 mA total across the bank** — keep LED currents low (≈5 mA
each via the resistors below) if several are lit at once.

| Peripheral     | Signal  | Pi pin (BCM)     | Notes                                                    |
|----------------|---------|------------------|----------------------------------------------------------|
| SH1106 OLED    | VCC     | 3.3 V (pin 1)    | —                                                        |
|                | GND     | GND (pin 6)      |                                                          |
|                | SDA     | GPIO 2 (pin 3)   | I2C1 data (on-board pull-up)                             |
|                | SCL     | GPIO 3 (pin 5)   | I2C1 clock (on-board pull-up)                            |
| PIR (HC-SR501) | VCC     | 5 V (pin 2/4)    | needs 5 V; **OUT is 3.3 V** — safe to GPIO               |
|                | OUT     | any GPIO         | set repeatable-trigger (H) mode                          |
| KY-038 sound   | +       | 5 V (pin 2/4)    | D0 output is 3.3 V-safe                                  |
|                | G       | GND              |                                                          |
|                | D0      | any GPIO         | HIGH over threshold (set by the pot); A0 unused (no ADC) |
|                | GND     | GND              |                                                          |
| Button         | leg A   | any GPIO         | internal pull-up, active-LOW                             |
|                | leg B   | GND              | GPIO → button → GND                                      |
| LED            | anode   | any GPIO → 330 Ω | red/yellow ~2.0 Vf; blue/white/violet ~3.0 Vf            |
|                | cathode | GND              |                                                          |
| PWR_SW opto    | GPIO    | **BCM 9–27** → 330 Ω → opto pin 1 | see the safety note below — **never BCM 0–8** |
|                | GND     | opto pin 2 → GND | Pi side only; the PC's ground stays separate              |
|                | PC      | opto pins 3/4 → motherboard `PWR_SW` header | in parallel with the case button          |
| Power LED opto | PC      | `PLED+` → 1 kΩ → opto pin 1, `PLED−` → opto pin 2 | polarity matters on this one    |
|                | GPIO    | opto pin 4 → any GPIO, opto pin 3 → GND | read as pulled-down input                 |

Enable I2C once on the Pi: `sudo raspi-config` → Interface Options → I2C → reboot.

### The front-panel switch — read this before wiring it

This is the one peripheral that can do something you'd regret, so it has rules.

**Use an optocoupler (PC817 or similar), not a direct wire and not a bare transistor.** The Pi and the PC each have
their own PSU; tying their grounds together to switch a signal invites a ground loop, and the optocoupler's whole job is
to pass the "press" as light instead of current. A relay works too, but it's slower, noisier, and larger for a job that
switches a few hundred microamps.

**The GPIO must be BCM 9–27.** Every Pi GPIO comes up as an input at power-on, and BCM 0–8 come up with internal
*pull-ups* while 9–27 come up with *pull-downs*. A pull-up on the optocoupler's input means the PC's power button is
held down for the ~20 seconds between the Pi powering on and your program claiming the pin — which force-offs a running
PC, or stops a stopped one from ever starting. `PowerSwitch::new` refuses pins below 9 rather than let you find this out
the hard way. An external ~10 kΩ pull-down across the optocoupler's input is cheap insurance on top.

**`PWR_SW` is not polarised** — it's a momentary switch, so the header pins are interchangeable *for a switch*. The
optocoupler's output is a phototransistor, though, which conducts only one way: if nothing happens, swap the two wires
going to the header. Nothing is damaged either way. The **power LED header is polarised** (`PLED+` / `PLED−`) and needs
the series resistor.

**What each pulse means to the PC**, from the motherboard's point of view — it cannot tell you apart from the case
button:

| Hold      | Effect                                                                              |
|-----------|-------------------------------------------------------------------------------------|
| ~250 ms   | ACPI power event: powers an off machine on, asks a running one to shut down politely |
| ~4 s+     | ATX force-off. Cuts power under the OS. Unsaved work is gone.                        |
| RESET_SW  | Immediate reset, same abruptness, no power cycle.                                    |

`PowerSwitch` clamps any hold to `MAX_HOLD` (12 s), releases the pin through a `Drop` guard so a panic can't leave the
button pressed, and enforces a cooldown between actuations. The one gap it can't close is `SIGKILL` landing inside the
press window — `Drop` doesn't run then. systemd's `Restart=always` plus the release-on-construct behaviour recovers
within seconds; the external pull-down closes it properly.

## Consumers

- [`departure-board`](../../apps/departure-board) — PIR + OLED + button + LED
- [`clapper`](../../apps/clapper) — optional LED + OLED feedback
- [`pcctl`](../../apps/pcctl) — `powerswitch`, as the fallback when Wake-on-LAN can't help

`rppal`/`sh1106` are Linux-only, so this crate builds as part of a Pi (cross)
build, not on a Windows/macOS host.
