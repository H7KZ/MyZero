# ZeroDepartureBoard

Public transport departure board on Raspberry Pi Zero 2 WH. PIR motion sensor wakes a 128×64 OLED, which shows upcoming
departures fetched from a backend API.

```
PIR sensor ──[motion]──► fetch /departures ──► SH1106 OLED
                              │
                     backend (separate repo)
                              │
                         Golemio PID API
```

## Hardware

| Component              | Notes                                       |
|------------------------|---------------------------------------------|
| Raspberry Pi Zero 2 WH | target board                                |
| SH1106 128×64 OLED     | I2C on `/dev/i2c-1`                         |
| PIR motion sensor      | GPIO, BCM numbering                         |
| Tactile button         | GPIO, cycles through stops (optional)       |
| White LED + resistor   | GPIO, lit when display is active (optional) |

**OLED wiring (I2C):**

| OLED pin | Pi pin               |
|----------|----------------------|
| VCC      | 3.3V (pin 1)         |
| GND      | GND (pin 6)          |
| SCL      | GPIO 3 / SCL (pin 5) |
| SDA      | GPIO 2 / SDA (pin 3) |

**PIR wiring:** VCC → 5V, GND → GND, OUT → `PIR_GPIO_PIN` (BCM).

**Button wiring:** one leg → `BUTTON_GPIO_PIN` (BCM), other leg → GND. Uses internal pull-up (active LOW).

**LED wiring:** `LED_GPIO_PIN` (BCM) → 330Ω resistor → LED anode → LED cathode → GND.

## Display layout

Single stop (clock in header):

```
┌─────────────────────┐
│Bořislavka      12:34│  ← stop name + local clock
│22   Bílá Hora    2m │
│119  Prosek       5m │
│147  Letiště     12m │
│A    Dep.Hostivař 18m│
└─────────────────────┘
```

Multiple stops (index replaces clock, button cycles):

```
┌─────────────────────┐
│Nádraží Veleslavín 1/2│  ← stop name + index
│S1   Praha hl.n.   3m │
│S3   Hostivice     8m │
│...                   │
└─────────────────────┘
```

FONT_6X10, 21 chars × 5 rows. `NOW ` shown for departures ≤0 min. `>99m` for >99 min.

## Configuration

All config is baked into the binary at compile time. Copy the example and fill in your values:

```sh
cp .env.example .env
$EDITOR .env
```

| Key                    | Description                                        |
|------------------------|----------------------------------------------------|
| `BACKEND_URL`          | Base URL of the backend server                     |
| `BACKEND_API_KEY`      | Bearer token (leave empty if no auth)              |
| `BACKEND_TIMEOUT_SECS` | HTTP timeout in seconds                            |
| `PIR_GPIO_PIN`         | BCM GPIO pin for PIR sensor                        |
| `BUTTON_GPIO_PIN`      | BCM GPIO pin for stop-cycle button. `0` = disabled |
| `LED_GPIO_PIN`         | BCM GPIO pin for active-state LED. `0` = disabled  |
| `IDLE_TIMEOUT_SECS`    | Seconds of no motion before display sleeps         |
| `POLL_INTERVAL_SECS`   | How often to re-fetch while display is active      |
| `STOP_NAME`            | Fallback stop name if backend returns empty stops  |
| `MAX_DEPARTURES`       | Max rows on display (4 fits with header)           |

`.env` is gitignored. `.env.example` is the committed template.

## Backend API contract

Device calls one endpoint. Backend (separate repo) handles Golemio auth and stop config.

```
GET /departures
Authorization: Bearer <BACKEND_API_KEY>   (omitted if key is empty)

200 OK:
{
  "stop_name": "Bořislavka",       // optional — falls back to STOP_NAME
  "fetched_at": "2026-04-20T12:34:56Z",
  "departures": [
    {
      "line":        "22",
      "destination": "Bílá Hora",
      "minutes":     2              // minutes until departure; ≤0 = departing now
    }
  ]
}

503 Service Unavailable:
{
  "error":   "upstream_unavailable",
  "message": "Cannot reach Golemio API"
}
```

## Prerequisites

### Build machine (Linux / macOS / WSL)

```sh
# Rust toolchain
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# cross — cross-compilation wrapper (requires Docker or Podman)
cargo install cross

# Docker (Ubuntu/WSL)
sudo apt install docker.io
sudo usermod -aG docker $USER   # log out and back in
```

### Raspberry Pi

```sh
sudo apt update && sudo apt upgrade -y

# Enable I2C
sudo raspi-config
# → Interface Options → I2C → Enable → reboot
```

No runtime dependencies beyond the binary itself.

## Build

```sh
# cross-compile for Pi Zero 2
make build

# lint + format check
make check
```

Output: `target/aarch64-unknown-linux-gnu/release/departure-board`

## Deploy & run

```sh
make ship      # build + scp to Pi
make run       # ssh and execute on Pi
```

Or separately:

```sh
make build
make deploy
```

If `raspberrypi.local` doesn't resolve, set `PI_HOST` in `Makefile` to the Pi's IP.

SSH key setup (avoids password prompts):

```sh
ssh-copy-id pi@raspberrypi.local
```

## Makefile targets

| Target        | Action                       |
|---------------|------------------------------|
| `make build`  | Cross-compile release binary |
| `make deploy` | `scp` binary to Pi           |
| `make ship`   | build + deploy               |
| `make run`    | `ssh` and run on Pi          |
| `make check`  | clippy + fmt check           |

## Systemd service (auto-start on boot)

```sh
sudo nano /etc/systemd/system/departure-board.service
```

```ini
[Unit]
Description=ZeroDepartureBoard
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/home/pi/departure-board
WorkingDirectory=/home/pi
Restart=on-failure
RestartSec=5
User=pi

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable departure-board
sudo systemctl start departure-board
sudo journalctl -fu departure-board
```

## Troubleshooting

**`Cannot open /dev/i2c-1`**
I2C not enabled. `sudo raspi-config` → Interface Options → I2C → Enable → reboot.

**Display stays blank after motion**
Check PIR wiring and `PIR_GPIO_PIN` value. Verify with `gpio readall` (BCM column).

**`[API] Error: …`**
Backend unreachable. Display shows "Chyba spojeni" and retries every `POLL_INTERVAL_SECS`. Check `BACKEND_URL` and
network connectivity.

**Czech characters not rendering**
Display uses `embedded_graphics::mono_font::iso_8859_2::FONT_6X10` which covers full Czech alphabet. If characters
appear as blocks, verify the embedded-graphics version supports iso_8859_2 (requires 0.8+).
