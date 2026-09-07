# pcctl

Remote power control for the PC, from the Pi. One binary that wakes the machine, tells you whether it's up, and puts
it back to sleep — as a CLI, or as a token-authenticated HTTP API you can hit from your phone.

> The Pi is on the PC's LAN segment permanently and costs about a watt. That's the whole trick: a VPN can reach your
> flat, but only something already on the wire can put a layer-2 magic packet on it.

The design reasoning — power states, Fast Startup, why sleep beats shutdown, how to reach the Pi from outside — is in
[`docs/remote-pc-control.md`](../../docs/remote-pc-control.md).

## Commands

```sh
pcctl status            # TCP knock on PC_PROBE_PORT — is it actually usable?
pcctl wake              # send the magic packet
pcctl wake --wait       # …and block until the PC answers (or WAKE_TIMEOUT_SECS)
pcctl sleep             # run SLEEP_COMMAND on the PC (SSH, forced command)
pcctl shutdown          # run SHUTDOWN_COMMAND on the PC
pcctl press             # tap the front-panel power switch through the GPIO
pcctl force-off --yes   # hold it past the ATX cut-off — loses unsaved work
pcctl reset --yes       # pulse the front-panel reset switch
pcctl serve             # HTTP control API on LISTEN_ADDR
pcctl config            # print the baked-in configuration
```

Exit status is 0 on success, 1 on failure — usable straight from a shell script or a cron job.

Only one power operation runs at a time, process-wide. Two clients pressing *sleep* and *wake* in the same second would
otherwise race and leave the PC in a state neither of them asked for; the loser gets a clear "already running" instead.

### The hardware verbs

`press` / `force-off` / `reset` close a contact across the motherboard's front-panel header through an optocoupler —
the escape hatch for when Wake-on-LAN can't help at all. They need `POWER_SW_GPIO_PIN` (and/or `RESET_SW_GPIO_PIN`)
wired and set, on a **BCM pin between 9 and 27**: pins 0–8 boot with a pull-up that would hold the button down for the
first ~20 s after the Pi powers on, so `pcctl` refuses them. Wiring and the rest of the safety rules are in
[`devices`](../../crates/devices/README.md#the-front-panel-switch--read-this-before-wiring-it).

A short `press` is the ACPI power event — the case button — so it needs no confirmation. `force-off` and `reset` cut
power under the OS and require `--yes` (CLI) or `confirm=<verb>` (API).

## HTTP API

```
GET  /                       control page (phone-sized; token comes from ?token=)
GET  /status                 {"ok":true,"message":"up — …","up":true,"led":null,…}
GET  /wake[?wait=1]          also POST — GET so Moonlight's HTTP-wake can call it
POST /sleep
POST /shutdown
POST /press                  tap the front-panel power switch
POST /force-off?confirm=force-off
POST /reset?confirm=reset
```

`up` is the TCP probe, `led` the front-panel power LED if one is wired (`null` = not wired). The two disagreeing is
informative rather than contradictory — lit but not answering is "booting, or hung".

Auth is `Authorization: Bearer <API_TOKEN>` or `?token=<API_TOKEN>`. `/sleep` and `/shutdown` are POST-only on
purpose — a GET that changes power state is one browser prefetch away from an accidental shutdown. `/wake` is
idempotent, so it gets both.

**`serve` refuses to bind anything but loopback without a token.** An open wake endpoint is a remote power switch for
whoever finds it. There are no cookies anywhere, so there is no ambient authority for another tab to borrow — the token
must be presented explicitly on every request. Connection threads are capped, so a client that opens sockets and never
speaks can't walk the Pi into swap.

```sh
curl -H "Authorization: Bearer $TOKEN" http://100.x.y.z:8080/status
curl -X POST -H "Authorization: Bearer $TOKEN" http://100.x.y.z:8080/sleep
```

### Waking straight from Moonlight

Moonlight can issue an HTTP GET before it starts streaming ("Configure Wake" on the host). Point it at:

```
http://<pi-tailnet-ip>:8080/wake?token=<API_TOKEN>&wait=1
```

and pressing *start streaming* wakes the PC and waits for it, with no separate step.

## Setup

Three sides, in this order — each is testable on its own.

**1. The PC** — arm the NIC and install the SSH power hook:

```powershell
# elevated PowerShell, from provision/pc/windows/
.\Setup-RemotePower.ps1 -Report                       # what's the state now?
.\Setup-RemotePower.ps1 -PublicKey .\id_pcctl.pub     # do it
```

It prints the MAC and the exact `.env` lines to paste. See [that folder's README](../../provision/pc/windows/README.md).

**2. The Pi**:

```sh
cp .env.example .env      # set PC_MAC, PC_HOST, WOL_BROADCASTS, API_TOKEN …
make ship BIN=pcctl       # from repo root
make run  BIN=pcctl       # or: ssh pi@… ./pcctl wake --wait
```

**3. Autostart** — `provision/systemd/pcctl.service`, or set `INSTALL_PCCTL="yes"` in `pizero.conf` and re-run the
provisioner. That step also generates `~/.ssh/id_pcctl` on the Pi and prints the public half for step 1.

## `.env` reference

| Key                                        | Meaning                                                              |
|--------------------------------------------|----------------------------------------------------------------------|
| `PC_MAC`                                   | MAC of the PC's **wired** NIC. `getmac /v` on Windows.               |
| `PC_HOST` / `PC_PROBE_PORT`                | Where to knock to decide "up". 22 = SSH, 3389 = RDP, 47989 = Sunshine.|
| `WOL_BROADCASTS`                           | Comma list, subnet-directed first (`192.168.1.255`).                 |
| `WOL_PORTS`                                | Usually `9,7`.                                                       |
| `WOL_REPEAT`                               | Bursts per wake. ≥3 over Wi-Fi — broadcast frames aren't acked.      |
| `WOL_BIND`                                 | Local IP to send from; pins the interface if the Pi is multi-homed.  |
| `SLEEP_COMMAND` / `SHUTDOWN_COMMAND`       | Shell lines. Empty disables the verb.                                |
| `COMMAND_TIMEOUT_SECS`                     | The command is killed after this.                                    |
| `POWER_SW_GPIO_PIN` / `RESET_SW_GPIO_PIN`  | Front-panel switch pins. `0` = not wired. **Must be 9–27.**          |
| `POWER_LED_GPIO_PIN` / `POWER_LED_INVERT`  | Read the PC's power LED back. `0` = not wired.                       |
| `PRESS_MS` / `FORCE_OFF_MS` / `RESET_MS`   | Pulse lengths. ~250 ms taps; ~6 s is the ATX hard cut.               |
| `PRESS_COOLDOWN_SECS`                      | Minimum gap between actuations, so nothing can power-cycle in a loop.|
| `LISTEN_ADDR`                              | `serve` bind address. Prefer the Pi's tailnet IP over `0.0.0.0`.     |
| `API_TOKEN`                                | `openssl rand -hex 32`. Required for any non-loopback bind.          |
| `WAKE_TIMEOUT_SECS`                        | How long `--wait` polls. S3 wakes in seconds; S5 can take a minute.  |

`.env` is **gitignored** (it holds the real MAC and token); `.env.example` is the template — and the fallback, so a
fresh clone still builds, with a `cargo:warning` telling you it did.

## Notes

- Pure std apart from the optional GPIO driver, so it cross-compiles to the Zero 2 with nothing but a linker, and the
  HTTP server is a couple of hundred lines of `TcpListener` and threads.
- The front-panel switch lives behind the default-on **`gpio` feature**. Build with `--no-default-features` on a
  Windows/macOS host — `rppal` is Linux-only — and the hardware verbs compile to a clear "not built in" message while
  everything else works unchanged.
- Magic packets and the TCP probe live in the shared [`net`](../../crates/net/README.md) crate, which is unit-tested on
  any host (`cargo test -p net`).
- Without the `gpio` feature there's no hardware dependency at all, so `pcctl` builds and runs on your laptop — handy
  for testing before it ever reaches the Pi.
- How to actually drive all this day to day — phone shortcuts, Moonlight, RDP, physical buttons — is in
  [`docs/using-the-remote-pc.md`](../../docs/using-the-remote-pc.md).
