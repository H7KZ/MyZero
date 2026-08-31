# Pi Zero 2 WH Setup Package

## Quick Start — 3 steps

```bash
# 1. Create your config from the template, then edit it.
#    pizero.conf is gitignored (holds WiFi password + SSH key) — never commit it.
cp provision/pizero.conf.example provision/pizero.conf
nano provision/pizero.conf

# 2. Copy the package to your Pi (from your laptop/desktop)
scp -r provision/ pi@192.168.x.x:~/

# 3. Run the installer on the Pi
sudo bash ~/provision/scripts/install.sh
# → reboot when prompted
```

---

## pizero.conf — all your settings

| Setting            | Default           | Description                                       |
|--------------------|-------------------|---------------------------------------------------|
| `WIFI_SSID`        | —                 | Your home network name **(required)**             |
| `WIFI_PASSWORD`    | —                 | Your home network password **(required)**         |
| `WIFI_COUNTRY`     | `DE`              | 2-letter ISO country code (DE CZ GB US AT…)       |
| `WIFI_SECURITY`    | `wpa2`            | `wpa2` or `wpa3`                                  |
| `HOTSPOT_SSID`     | `PiZero-Fallback` | Fallback AP name                                  |
| `HOTSPOT_PASSWORD` | `raspberry`       | Fallback AP password                              |
| `HOTSPOT_IP`       | `10.42.0.1`       | Pi's IP inside the hotspot                        |
| `HOTSPOT_CHANNEL`  | `6`               | Default 2.4 GHz channel (1, 6, or 11 recommended) |
| `HOTSPOT_TIMEOUT`  | `60`              | Seconds before raising hotspot                    |
| `PI_HOSTNAME`      | `raspberry`       | Sets `raspberry.local` via mDNS                   |
| `TIMEZONE`         | `Europe/Berlin`   | Any tz from `/usr/share/zoneinfo/`                |
| `SSH_PUBLIC_KEY`   | `""`              | Paste `~/.ssh/id_ed25519.pub` here                |
| `HEADLESS`         | `no`              | `yes` = disable HDMI, free ~224 MB RAM            |
| `OVERCLOCK`        | `none`            | `none` / `safe` (1.2 GHz) / `power` (700 MHz)     |
| `INSTALL_VOICE_ASSISTANT` | `no`       | `yes` = install libvosk + voice-assistant binary + service |
| `VOSK_VERSION`     | `0.3.45`          | libvosk release to download for the runtime `.so` |

---

## Package structure

```
provision/
├── pizero.conf.example      ← copy to pizero.conf, then edit
├── README.md
├── scripts/
│   ├── install.sh           ← run this with sudo
│   ├── lib.sh               ← shared functions (auto-sourced)
│   ├── hotspot-start.sh     ← raises the fallback AP
│   ├── hotspot-stop.sh      ← tears down the fallback AP
│   ├── wifi-watchdog.sh     ← runs as systemd service at boot
│   └── pizero-headless.sh   ← toggle headless mode on/off
├── configs/
│   ├── 99-pizero-sysctl.conf    → /etc/sysctl.d/
│   ├── 60-pizero-ioscheduler.rules → /etc/udev/rules.d/
│   ├── pizero-journald.conf     → /etc/systemd/journald.conf.d/
│   ├── pizero-sshd.conf         → /etc/ssh/sshd_config.d/
│   ├── pizero-brcmfmac.conf     → /etc/modprobe.d/
│   └── earlyoom                 → /etc/default/earlyoom
├── templates/
│   ├── nm-connection.conf   NM WiFi keyfile template
│   ├── nm-global.conf       NM global settings template
│   ├── hostapd.conf         hostapd template
│   └── dnsmasq-hotspot.conf dnsmasq template
└── systemd/
    └── pizero-hotspot.service  → /etc/systemd/system/
```

---

## Fallback hotspot — how it works

The CYW43438 radio in the Pi Zero 2 WH supports **AP/STA concurrency**:
it can simultaneously be a WiFi client (connecting to your home network)
and broadcast its own access point, using a virtual interface.

```
Physical radio (CYW43438)
 ├─ wlan0  [managed/STA]  ← NetworkManager keeps this connected to home WiFi
 └─ uap0   [AP]           ← hotspot-start.sh creates this virtual interface
                             hostapd + dnsmasq bind to uap0 only
```

**Hardware constraint:** both interfaces must use the same channel.
`hotspot-start.sh` detects `wlan0`'s active channel with `iw dev wlan0 info`
and patches the hostapd config to match before starting. If `wlan0` is not connected, the channel from `pizero.conf`
(`HOTSPOT_CHANNEL`) is used.

**What happens at boot:**

1. `pizero-hotspot.service` starts the watchdog (`wifi-watchdog.sh`)
2. Watchdog waits up to `HOTSPOT_TIMEOUT` seconds for `wlan0` to get an IP **and** for the gateway to respond to ping
   (IP alone isn't enough)
3. **If home WiFi connects** → watchdog enters normal mode, checks every 45 s
4. **If no WiFi** → watchdog creates `uap0`, starts hostapd + dnsmasq → hotspot up
5. Every 30 s in hotspot mode → briefly checks if home network came back
6. **If home WiFi returns** → hotspot drops, `uap0` deleted, `wlan0` takes over

**Connect to the hotspot:**

1. Join `PiZero-Fallback` (password: `raspberry`)
2. SSH in:
   ```bash
   ssh pi@10.42.0.1           # always works
   ssh pi@raspberry.local     # works on macOS/Linux with Bonjour
   ```

**Manual control:**

```bash
sudo pizero-hotspot-start     # force hotspot on
sudo pizero-hotspot-stop      # force hotspot off
sudo systemctl status pizero-hotspot
sudo journalctl -t pizero-wifi-watchdog -f
sudo journalctl -t pizero-hotspot -f
```

---

## Headless mode

Set `HEADLESS=yes` in `pizero.conf` before installing, **or** toggle afterwards:

```bash
sudo bash ~/provision/scripts/pizero-headless.sh on      # enable
sudo bash ~/provision/scripts/pizero-headless.sh off     # restore desktop
sudo bash ~/provision/scripts/pizero-headless.sh status  # show state
```

Headless mode:

- Disables HDMI output (~14 mA saved)
- Reduces CMA from 256 MB to 32 MB (~224 MB freed)
- Disables Bluetooth and audio
- Enables hardware watchdog
- Speeds up boot (removes splash, sets `initial_turbo=60`)

---

## Re-running (this is the update path)

Re-running **is** how you update the Pi. Edit `pizero.conf` or any file under
`configs/`/`templates/`, copy the folder over again, and re-run — every step is
idempotent (`cp -f` overwrites, appends are guarded), so the Pi converges to the
new state without duplicating anything:

```bash
sudo bash ~/provision/scripts/install.sh           # apply / re-apply (= update)
sudo bash ~/provision/scripts/install.sh --dry-run # preview only
```

---

## Troubleshooting

**WiFi not connecting after reboot:**

```bash
nmcli device status
nmcli connection show
journalctl -t NetworkManager --no-pager -n 30
cat /etc/NetworkManager/system-connections/pizero-home.nmconnection
```

**Hotspot not appearing:**

```bash
sudo journalctl -t pizero-wifi-watchdog --no-pager -n 50
sudo journalctl -t hostapd --no-pager -n 30
sudo journalctl -t pizero-hotspot --no-pager -n 30
iw list | grep -A10 "valid interface combinations"
rfkill list
```

**Clients connect to hotspot but get no IP:**

```bash
cat /run/pizero-dnsmasq.log
ss -tulnp | grep ':53 '    # check for port 53 conflicts
ss -tulnp | grep ':67 '    # check DHCP port
```

**Check hotspot interface:**

```bash
ip link show uap0           # should show UP when hotspot is active
ip addr show uap0           # should show 10.42.0.1/24
```

---

## Design notes

- **WPA2-PSK only** — WPA3/SAE is broken on the CYW43438 firmware; attempting it causes all client authentication to
  fail at the handshake phase.
- **No `feature_disable` flags in brcmfmac** — disabling firmware features (especially the 4-way handshake, 0x002000)
  breaks WPA2 on many APs. Only `roamoff=1` is set.
- **NM powersave disabled** — `wifi.powersave=2` (disabled) in the NM config. The CYW43438 drops connections with power
  saving enabled.
- **Watchdog has no `set -euo pipefail`** — by design. It runs forever and must survive any transient command failure.
  Systemd `Restart=always` handles unexpected exits.
- **Runtime configs under `/run/`** — hostapd and dnsmasq are patched to
  `/run/pizero-*.conf` at start time. The installed `/etc/` configs are never modified at runtime.
