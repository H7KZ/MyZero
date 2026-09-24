# Getting started: zero to running

One linear path from a blank SD card and a fresh Windows PC to a Pi running MyZero apps. Steps 1–7 are required;
8+ are optional tracks — do the ones you need.

## 1. Flash Raspberry Pi OS

Goal: bootable SD card with SSH enabled and your user set up.

Use **Raspberry Pi Imager** on Windows. Pick Raspberry Pi OS Lite (64-bit), your SD card, then in the advanced
options (gear icon) set: hostname, enable SSH (password or your public key), and Wi-Fi (optional — `provision`
will redo this properly in step 2, so a temporary network here is fine, just so you can reach the Pi once).

**Check it worked:** write completes without error and the card ejects cleanly.

## 2. Provision the OS

Goal: Wi-Fi with fallback hotspot, hostname, timezone, SSH key, headless/overclock tuning.

```sh
cp provision/pizero.conf.example provision/pizero.conf
notepad provision/pizero.conf   # fill WIFI_SSID, WIFI_PASSWORD, SSH_PUBLIC_KEY, etc.
scp -r provision/ pi@<pi-ip-or-hostname>:~/
ssh pi@<pi-ip-or-hostname> "sudo bash ~/provision/scripts/install.sh"
```

Reboot when prompted. Full option reference: [provision/README.md](../provision/README.md).

**Check it worked:** `ssh pi@<PI_HOSTNAME>.local` succeeds after reboot; `nmcli device status` shows `wlan0`
connected.

## 3. Set up the build toolchain (on your dev machine)

Goal: cross-compile Rust binaries for the Pi's `aarch64-unknown-linux-gnu` target.

Install Rust (`rustup`) and `cross` (needs Docker or Podman running). The pinned toolchain and target are in
[rust-toolchain.toml](../rust-toolchain.toml) — `rustup` picks them up automatically in this repo.

**Check it worked:** `cross --version` and `docker ps` (or `podman ps`) both run without error.

## 4. Build the apps

Goal: release binaries for the Pi.

```sh
make build BIN=pcctl   # cross-compiles one app (default BIN=departure-board)
make build-all         # or the whole workspace
make check             # clippy + fmt, optional but recommended
```

**Check it worked:** `target/aarch64-unknown-linux-gnu/release/` contains `departure-board`, `clapper`, `pcctl`.

## 5. Configure each app's `.env`

Goal: runtime config the binary reads at startup (via `crates/config`), never baked into the binary.

For each app you'll run, copy its `.env.example` to `.env` and fill in real values (pins, MAC address, API
token — see that app's README for its key list):

```sh
cp apps/clapper/.env.example provision/bin/clapper.env
cp apps/pcctl/.env.example   provision/bin/pcctl.env
notepad provision/bin/clapper.env
notepad provision/bin/pcctl.env
```

`install.sh` deploys these to `/home/pi/<app>.env` on the Pi, and each app's systemd unit sets
`Environment=ENV_FILE=/home/pi/<app>.env` so the binary finds it regardless of working directory.

Already provisioned Pi? Skip `install.sh` and use the Makefile instead:

```sh
make new-env BIN=pcctl   # creates apps/pcctl/.env from .env.example (gitignored)
make env BIN=pcctl       # copies it to the Pi as ~/pcctl.env
```

**Check it worked:** `provision/bin/clapper.env` / `pcctl.env` (or `apps/<app>/.env`) exist and are filled in (not the placeholder
values).

## 6. Deploy

Goal: get the built binary onto the Pi.

```sh
make ship BIN=pcctl     # build + scp to the Pi + restart its systemd service
# or, if already built:
make deploy BIN=clapper
make status BIN=pcctl   # systemd status
make logs BIN=pcctl     # follow the journal
```

`deploy` restarts the app's systemd unit, so it expects step 7 done; `departure-board` has no unit, so for it the
restart step fails harmlessly after the copy — run it with `make run BIN=departure-board`.

No local toolchain? Run the **Build** workflow manually on GitHub (Actions → Build → Run workflow, pick the app) and
download the binary from the run's artifacts.

**Check it worked:** `ssh pi@<pi> "ls ~/<binary-name>"` shows the file.

## 7. Enable systemd autostart

Goal: app starts on boot and restarts on failure.

For `clapper`/`pcctl`, set `INSTALL_CLAPPER=yes` / `INSTALL_PCCTL=yes` in `provision/pizero.conf` **before**
running `install.sh` (step 2), after building the binary and placing it at `provision/bin/<app>` (per the comments
in `pizero.conf.example`). Re-run `install.sh` to apply.

**Check it worked:** `ssh pi@<pi> "systemctl status clapper"` (or `pcctl`) shows `active (running)`.

---

## 8. Optional: departure-board

PIR-woken OLED public-transport display. Wiring (OLED I2C, PIR sensor) and `.env` keys are in
[apps/departure-board/README.md](../apps/departure-board/README.md). Deploy/run it with `make ship BIN=departure-board`
/ `make run BIN=departure-board` (steps 4–6 above), no systemd unit provided — run it manually or add your own.

**Check it worked:** OLED lights up on PIR motion and shows departure data.

## 9. Optional: clapper (clap → Wake-on-LAN)

Goal: clap near the KY-038 sensor to send a magic packet to your PC.

Wire the KY-038: `+` → 5V (pin 2/4), `GND` → GND, `D0` → any GPIO (A0 unused, no ADC needed) — set that pin in
`SOUND_GPIO_PIN` in `clapper.env` (default `17`). Optional status LED and SH1106 OLED are also configurable; full
pinout in [crates/devices/README.md](../crates/devices/README.md#wiring).

Do steps 4–7 with `BIN=clapper` and `INSTALL_CLAPPER=yes`.

**Check it worked:** clap twice near the sensor within `CLAP_WINDOW_MS`; the target PC wakes. `journalctl -u
clapper -f` on the Pi shows detected claps.

## 10. Optional: pcctl (remote PC control)

Goal: wake/sleep/shutdown a PC over the network (and a GPIO fallback), from anywhere via Tailscale.

Do steps 4–7 with `BIN=pcctl` and `INSTALL_PCCTL=yes`. Then run
`provision/pc/windows/Setup-RemotePower.ps1` on the PC using the public key `install.sh` prints, to arm
Wake-on-LAN and install the SSH power hook.

This is the shallow version — BIOS WoL settings, router config, Tailscale, and the GPIO power-switch fallback are
covered end to end in **[docs/remote-pc-setup.md](remote-pc-setup.md)**; day-to-day use in
[docs/remote-pc-usage.md](remote-pc-usage.md).

**Check it worked:** `ssh pi@<pi> "pcctl wake"` (or the HTTP API) brings the PC out of sleep.
