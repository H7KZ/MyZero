# Remote PC control: wake it, use it, put it back to sleep

Research notes and a recommended design for the thing this repo is edging towards: the desktop at home is the fast
machine, the laptop is the one you actually carry, and the Pi is the always-on scrap of hardware that bridges them.
GeForce NOW, but the datacentre is your living room.

Everything below is split into the three problems that actually exist — **wake**, **use**, **sleep** — plus the one
that ties them together: **how you reach any of it from outside the flat**.

---

## TL;DR — the recommended stack

| Layer               | Choice                                   | Why                                                                    |
|---------------------|------------------------------------------|------------------------------------------------------------------------|
| Wake                | Pi on the LAN sending the magic packet   | Only something already on the PC's layer-2 segment can wake it          |
| Resting state       | **Sleep (S3)**, not shutdown             | Wakes in ~2 s, keeps your session, and is the state Windows still arms  |
| Remote access       | **Tailscale** on Pi + laptop + PC        | No open ports, no DDNS, WireGuard crypto, works behind CGNAT            |
| Control surface     | `pcctl serve` — token-auth HTTP API      | One URL for wake/sleep/shutdown/status; phone bookmark or Moonlight     |
| Power-down          | SSH key with a **forced command**        | The Pi can sleep the PC and literally nothing else                      |
| Screen — games      | **Sunshine** (PC) + **Moonlight** (you)  | Free, open source, hardware-encoded, ~10–20 ms on a good link           |
| Screen — work       | **RDP** over Tailscale                   | Far lighter on bandwidth, better text, reconnects cleanly               |
| Last-resort power   | GPIO + optocoupler on the PWR_SW header  | Works when the NIC, the OS, or WoL itself has given up                  |

The rest of this document is why.

---

## Part 1 — What Wake-on-LAN actually is

A **magic packet** is 102 bytes: six `0xFF` bytes, then the target's 6-byte MAC repeated 16 times.

```
FF FF FF FF FF FF | MAC MAC MAC MAC MAC MAC | … 16 copies … = 102 bytes
```

That's the entire protocol. There is no header, no checksum, no version, no reply. The NIC — which stays powered by
+5 V standby rail even when the PC is "off" — watches every frame that reaches it and pattern-matches those 102
bytes anywhere in the payload.

Three consequences fall straight out of that, and they explain almost every WoL problem people have:

1. **It's layer 2.** The NIC has no IP address while the machine is off; it can't ARP, can't route, can't do DHCP.
   The frame has to physically arrive on its wire. This is the single most important fact in this document.
2. **The UDP wrapper is a costume.** Ports 9 (`discard`) and 7 (`echo`) are conventions, not requirements — the
   payload is what matches. Sending to both costs one extra datagram and removes a variable. `crates/net`'s
   `DEFAULT_PORTS` does exactly that.
3. **It's unauthenticated.** Anyone who can put a frame on your LAN with your MAC in it can boot your PC. MAC
   addresses are broadcast in the clear all day; they are not a secret.

### SecureOn is not the answer

Some NICs support **SecureOn**: a 6-byte password stored in the adapter that must appear in the magic packet. It is
worth knowing about and not worth using — it's transmitted in cleartext, so anyone who can sniff one wake can replay
it forever, and support is patchy enough that you'll spend an evening finding out your NIC doesn't have it.

The real answer is **don't let untrusted parties put frames on your LAN**, which is Part 5.

---

## Part 2 — Power states: what can actually be woken

This is where most WoL setups die, and it's worth being precise, because "off" means four different things.

| State    | Name                | RAM        | NIC powered?      | Resume | WoL?                                       |
|----------|---------------------|------------|-------------------|--------|--------------------------------------------|
| **S0**   | Running             | live       | yes               | —      | n/a — already on                            |
| **S0ix** | Modern Standby      | live       | *sometimes*       | instant| unreliable — see below                      |
| **S3**   | Sleep / suspend-RAM | refreshed  | yes, on standby   | ~2 s   | **yes — the sweet spot**                    |
| **S4**   | Hibernate           | on disk    | usually           | ~15 s  | yes, *if* you explicitly hibernated         |
| **S4**   | *Hybrid shutdown*   | kernel→disk| **disarmed**      | ~10 s  | **no — Windows switches it off on purpose** |
| **S5**   | Full shutdown       | gone       | firmware-dependent| ~40 s  | only if the BIOS keeps the NIC armed        |

### Fast Startup is the usual culprit

Windows 10 and 11 do not really shut down when you click Shut down. They do a **hybrid shutdown**: close your session,
write the kernel session to disk, and enter S4. Microsoft's own documentation is blunt about what that does to WoL:

> In Windows 10, the default shutdown behavior puts the system into the hybrid shutdown (also known as Fast Startup)
> state (S4)… In this scenario, WOL from S4 or S5 is unsupported. Network adapters are explicitly not armed for WOL in
> these cases, because users expect zero power consumption and battery drain in the shutdown state.
> — [Microsoft Learn, *Wake on LAN behavior*](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/wake-on-lan-feature)

Note the asymmetry Microsoft points out: an **explicit hibernate** leaves the NIC armed; a **hybrid shutdown** does
not, even though both land in S4. So "it works when I hibernate but not when I shut down" is expected behaviour, not
a broken driver.

`Setup-RemotePower.ps1` sets `HiberbootEnabled = 0` for this reason.

### Modern Standby (S0ix) is the newer culprit

On many recent machines — laptops especially — S3 is simply gone. Both Intel and AMD have dropped legacy S3 on
current mobile platforms in favour of **Modern Standby**, where the system stays nominally in S0 and components
power-gate individually. WoL from S0ix is, charitably, hit or miss: the Ethernet PHY often loses power anyway, which
is why the link light goes dark.

Check which one you have:

```powershell
powercfg /a          # "Standby (S3)" available → good. Only "Standby (S0 Low Power Idle)" → Modern Standby.
```

If you're stuck with Modern Standby, your realistic options are, in order: **hibernate** explicitly (S4 stays
wakeable), look for a `Modern Standby`/`S3` toggle in the UEFI (some desktop boards have one), or fall back to the
GPIO power-button trick in Part 9. A desktop with a proper ATX board — which is what "the machine at home is more
powerful" usually means — will almost always have real S3.

### The recommendation: sleep, don't shut down

For your use case, **sleep is strictly better than shutdown**:

- It wakes in ~2 seconds instead of ~40, so "open laptop → click wake → stream" feels instant.
- Your session survives: apps open, editors where you left them, no login-and-relaunch ritual.
- It's the one state Windows reliably keeps the NIC armed for.
- The power difference is real but small (see Part 11).

Shut down when you're away for a week. Sleep the rest of the time.

---

## Part 3 — The hardware checklist

In rough order of how often each one is the actual problem:

1. **UEFI/BIOS.** Look for `Wake on LAN`, `Resume by PCI-E Device`, `Power On By PCIE/PCI`, or `PME Event Wake` — and
   enable it. Then find **`ErP Ready` / `EuP` and set it to Disabled**: ErP is an EU standby-power compliance mode that
   cuts the standby rail, and it kills WoL from S5 outright. If the Ethernet port's LED is completely dark when the PC
   is off, this is almost always why.
2. **Wired, not Wi-Fi.** WoWLAN exists, needs the radio to stay associated in standby, and is unreliable on desktop
   cards. Use the Ethernet port. Use the *motherboard's* Ethernet port — a **USB NIC loses bus power at S5** and can
   never wake the machine.
3. **Windows NIC settings.** Device Manager → your adapter → Power Management: *Allow this device to wake the
   computer* + *Only allow a magic packet…*; Advanced tab: *Wake on Magic Packet* = Enabled. Leave *Wake on pattern
   match* **disabled** — pattern wake fires on ordinary broadcast chatter and your PC will never stay asleep.
4. **Energy-Efficient Ethernet / "Green Ethernet".** These park the PHY at low power and are a common cause of a dark
   link light. Turn them off on the adapter.
5. **Realtek on Linux.** The in-tree `r8169` driver has historically shaky WoL; the vendor `r8168` module fixes it.
   On Linux the setting is also not persistent — you need `ethtool -s <iface> wol g` re-applied at boot (see Part 6).

`Setup-RemotePower.ps1 -Report` prints the state of items 3–4 plus `powercfg /devicequery wake_armed`, which is the
authoritative "is this NIC actually armed right now" answer.

---

## Part 4 — Getting the packet to the NIC

### The subnet rule

Broadcasts don't route. A magic packet sent from outside your LAN has to be turned back into a local broadcast by
*something inside* the LAN. There are three ways to do that, and only one is pleasant:

| Approach                              | How it fails                                                                                  |
|---------------------------------------|-----------------------------------------------------------------------------------------------|
| Port-forward UDP 9 to the broadcast   | Most consumer routers refuse to forward to a broadcast address at all                          |
| Port-forward UDP 9 to the PC's IP     | Works until the router's **ARP entry expires** (5–10 min), then the packet is silently dropped |
| Static ARP entry + directed broadcast | Works, but needs router shell access, and directed broadcast is off by default for good reason |
| **Something already on the LAN**      | Doesn't fail. This is the Pi.                                                                  |

That ARP failure is worth understanding because it produces the most maddening symptom: *WoL works right after the PC
goes to sleep and stops working an hour later*. The router forwards the unicast packet by looking up the MAC for the
PC's IP; once that cache entry ages out it sends an ARP request, a powered-off machine doesn't answer, and the packet
is discarded. Nothing is logged. Nothing looks broken.

**A Pi on the LAN removes the entire category.** It broadcasts locally; there is no router in the path, no ARP lookup,
no cache to expire. This is also why the popular remote-wake recipes are all "VPN into a small always-on box, then
broadcast from there" — Tailscale's own writeup says as much:

> Tailscale can't send WoL packets… over a Layer 2 connection, even if you have enabled subnet routing.
> — [Tailscale, *Making a Wake-on-LAN server*](https://tailscale.com/blog/wake-on-lan-tailscale-upsnap)

### The Wi-Fi Pi caveat

The Zero 2 W has no Ethernet, so the packet leaves over Wi-Fi and the access point has to bridge it onto the wired
segment. On a normal home router — one SSID, one subnet, one bridge — this works. Three things can spoil it, and
`pcctl` is built to route around all three:

| Problem                                                         | Mitigation in `pcctl`                                 |
|-----------------------------------------------------------------|-------------------------------------------------------|
| Wi-Fi broadcast frames are unacknowledged; a lone packet is lost | `WOL_REPEAT=3` — send several bursts                  |
| Some APs drop `255.255.255.255` but pass `192.168.1.255`         | `WOL_BROADCASTS` takes a list; subnet-directed first  |
| The Pi is multi-homed (`wlan0` + the fallback hotspot `uap0`)    | `WOL_BIND` pins the source interface                  |

Also check your router for **AP isolation / client isolation** and turn it off, and put guest Wi-Fi out of the
picture entirely — a guest SSID is usually a separate broadcast domain by design.

If Wi-Fi turns out to be flaky in practice, a $10 USB-Ethernet adapter on a Pi with a USB host port (Zero 2's OTG
port works with an adapter) removes the last variable. Test first; you probably won't need it.

---

## Part 5 — Reaching the Pi from outside

Four options, in ascending order of how much I'd recommend them.

### ❌ Port forwarding UDP 9 to the internet

Don't. It gives every scanner on the internet a button that boots your PC, which is both a denial-of-*sleep* attack
(your machine never rests, and you pay for it) and an invitation to attack whatever your PC exposes once it's up. The
magic packet has no authentication to add. This is the one option with no redeeming version.

### ⚠️ Port-forward an authenticated service + DDNS

Better — you at least have a token in front of it — but you're still running a public listener maintained by you, on a
residential IP, with certificate and DDNS chores. Only worth it if you specifically need a URL that works without any
client software.

### ✅ Tailscale — the recommendation

A WireGuard mesh with identity-based auth and NAT traversal. Install on the Pi, your laptop, your phone, and the PC:

```sh
curl -fsSL https://tailscale.com/install.sh | sh
sudo tailscale up
```

Why it's the right default here:

- **Zero open ports.** Nothing is listening on your public IP. There is no attack surface to harden.
- **Works behind CGNAT**, which matters if you're on mobile broadband or a stingy ISP.
- Devices get stable `100.x.y.z` addresses, so `pcctl`'s `LISTEN_ADDR` can bind the Pi's tailnet IP and be reachable
  from your phone and nowhere else.
- The **PC joins the tailnet too**, so Moonlight/RDP go device-to-device rather than through the Pi. The Pi's only job
  stays "put a frame on the wire".

One caveat that matters for streaming: Tailscale prefers a **direct** connection but falls back to a **DERP relay**
when NAT traversal fails, and a relayed path will cap your stream around a few Mbps with fragmentation on top. Check
it with `tailscale status` — you want `direct`, not `relay`. If you're stuck on relay, forward **UDP 41641** to the
PC, which gives the NAT traversal something to work with.

Alternatives in the same family: **WireGuard** by hand (same crypto, more config, no NAT traversal help — fine if you
already run it), **Headscale** if you want the coordination server self-hosted too.

### ✅ Cloudflare Tunnel — for the browser-shaped half

Different tool for a different job: it publishes an HTTP service at a real hostname over Cloudflare's network, with
Cloudflare Access (Google/GitHub/OTP) in front. Good if you want `pcctl`'s page to work from a borrowed browser with
no client installed. Not useful for the streaming half — that's UDP.

You can run both: Tailscale for everything, plus a Cloudflare Tunnel in front of `pcctl serve` if you want the web
button available from anywhere.

---

## Part 6 — Turning it off again

Waking is broadcast-and-pray. Powering *down* is the easy direction: the PC is running, so you can just talk to it.

### Recommended: SSH with a forced command

Windows ships OpenSSH Server as an optional capability. Install it, create an **unprivileged local account**, and give
the Pi's public key a `command=` restriction so that key can run exactly one program:

```
command="powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File C:\ProgramData\pcctl\pcpower.ps1",
no-agent-forwarding,no-port-forwarding,no-pty,no-user-rc,no-X11-forwarding ssh-ed25519 AAAA…
```

sshd discards whatever the client asked for and runs the dispatcher; the dispatcher reads `$env:SSH_ORIGINAL_COMMAND`
and accepts four words — `sleep`, `hibernate`, `shutdown`, `status`. If the Pi is ever compromised, the attacker's
prize is the ability to turn your PC off.

Two Windows details that eat an afternoon if you don't know them:

- **Admin keys live somewhere else.** For accounts in the Administrators group, Win32-OpenSSH ignores
  `~/.ssh/authorized_keys` and reads `C:\ProgramData\ssh\administrators_authorized_keys`. Sidestep it entirely by
  using a standard user — which is what you want anyway. Members of `Users` already hold `SeShutdownPrivilege` on a
  Windows client, so a standard account can shut the machine down.
- **The profile folder doesn't exist yet.** `C:\Users\pcpower\` isn't created until the account first logs on, and
  pre-creating it makes Windows build the real profile as `pcpower.HOSTNAME` — after which sshd looks for the key
  somewhere else. `Setup-RemotePower.ps1` avoids the race by keeping the key at a fixed `ProgramData` path and
  pinning it with a `Match User` block in `sshd_config`.

### Sleep vs hibernate: the `SetSuspendState` trap

The command everyone copies from the internet is:

```
rundll32.exe powrprof.dll,SetSuspendState 0,1,0
```

Its arguments are decorative. The rundll32 entry point ignores them, and the machine **hibernates whenever
hibernation is enabled** — so you ask for a 2-second sleep and get a 15-second hibernate, or worse, a state your NIC
isn't armed for. Two ways out:

- **Call the API properly.** `pcpower.ps1` P/Invokes `SetSuspendState(hibernate:$false, forceCritical:$true, …)`,
  which is unambiguous and needs nothing installed. `forceCritical` also skips the "an app is preventing sleep" veto —
  important when nobody is at the keyboard to dismiss it.
- **Or remove the ambiguity:** `powercfg /hibernate off` disables hibernation *and* Fast Startup in one move (Fast
  Startup is built on hibernation) and reclaims `hiberfil.sys`. `Setup-RemotePower.ps1 -DisableHibernation` does this.
  The cost is losing S4 as a fallback.

Sysinternals **`psshutdown -d -t 0`** is the third option and genuinely reliable, at the price of a downloaded binary.
Worth remembering if the P/Invoke misbehaves on your hardware.

### If the PC runs Linux instead

Waking is identical. The PC side is:

```sh
sudo ethtool -s enp5s0 wol g          # arm it (not persistent!)
sudo ethtool enp5s0 | grep Wake-on    # "Wake-on: g" = armed
```

Make it persistent with a tiny unit, because most distros reset it on boot:

```ini
# /etc/systemd/system/wol.service      →  systemctl enable --now wol
[Unit]
Description=Arm Wake-on-LAN
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/sbin/ethtool -s enp5s0 wol g
[Install]
WantedBy=basic.target
```

Then point `SLEEP_COMMAND` at `ssh … systemctl suspend` (add a narrow sudoers rule or use a polkit-permitted user),
and `SHUTDOWN_COMMAND` at `systemctl poweroff`.

### Closing the loop: let the PC put itself to sleep

The best remote shutdown is the one you never have to send. Set a Windows sleep timeout of 20–30 minutes on AC:

```powershell
powercfg /change standby-timeout-ac 30
```

One wrinkle worth knowing: on Windows 11 the global idle timer is driven by **console** input, and activity inside an
RDP session doesn't always reset it — so an RDP-only session can put the machine to sleep out from under you.
Streaming with Sunshine (which drives the real console session) doesn't have this problem. If it bites you, PowerToys
**Awake** holds the machine up for the duration of a session without touching your power plan.

---

## Part 7 — Actually using the machine

This is the GeForce NOW part, and it splits cleanly in two.

### For games and anything GPU-shaped: Sunshine + Moonlight

**Sunshine** is the host (open-source successor to NVIDIA GameStream), **Moonlight** is the client, and they're free
on both ends. Sunshine encodes with the GPU's hardware encoder (NVENC / AMF / QuickSync) and Moonlight decodes in
hardware too, which is why the latency is in a different class from generic remote-desktop tools.

Realistic numbers, from the 2026 comparisons and consistent with what people measure:

| Path                              | Typical added latency | Notes                                     |
|-----------------------------------|-----------------------|-------------------------------------------|
| Moonlight, wired LAN              | ~8–16 ms              | Indistinguishable from local for most     |
| Moonlight over Tailscale, direct  | ~15–30 ms             | Depends entirely on your uplink and RTT   |
| Moonlight over Tailscale, relayed | unusable              | Fix the direct connection first           |
| Parsec                            | comparable            | Easier setup, closed, free tier limits    |
| RDP with AVC444                   | ~30–100 ms            | Fine for text, bad for a 3D viewport      |

Setup notes worth having in advance:

- Sunshine's web UI is `https://localhost:47990`; pairing is a PIN you type there. It installs as a **Windows service**
  so it survives reboots.
- **The login screen problem:** after a wake the PC may sit at the lock screen with no user session, and a service
  can't capture a desktop that doesn't exist. Options: enable auto-login (convenient, weakens physical security),
  keep the session logged in and only ever *sleep* (recommended — sleep preserves the session, which is another point
  for sleep over shutdown), or run Sunshine as a service configured to capture the login screen.
- **No monitor attached?** Windows' Desktop Duplication API captures whatever the GPU is driving. Headless, you'll
  want an **HDMI dummy plug** (~$8) or a virtual display driver, otherwise you get a 640×480 phantom desktop.
- Your **upload** bandwidth is the ceiling. 1080p60 wants ~20–30 Mbps, 4K60 more like 50–80. Home uplinks are the
  usual bottleneck, not the encoder.

### For work: RDP over Tailscale

For a terminal, an editor, a browser, and a compile — RDP is the better tool. It's dramatically lighter on bandwidth,
renders text properly instead of smearing it through a video codec, survives a dropped link, and needs no extra
software on Windows Pro. Over Tailscale it's just `mstsc` to `100.x.y.z`, with nothing exposed publicly.

Run both. Use RDP by default; launch Moonlight when you want the GPU. **Never expose RDP (3389) to the internet** —
it is one of the most-attacked ports there is. On a tailnet that's a non-issue.

Honourable mentions: **Parsec** (excellent, easiest setup, closed-source with a paid tier), **RustDesk**
(self-hostable, better as a support tool than a gaming one), **Steam Link** (trivial if you only want Steam games).

---

## Part 8 — The design, end to end

```
   laptop / phone (anywhere)
        │
        │  Tailscale (WireGuard, no open ports)
        ▼
   ┌──────────────────────────────┐
   │  Pi Zero 2 W   ~1 W, always on│
   │                              │
   │  pcctl serve                 │   GET  /wake       → magic packet
   │   ├─ HTTP API + token        │   GET  /status     → TCP knock
   │   └─ /  control page         │   POST /sleep      → ssh forced command
   │  clapper (optional)          │   POST /shutdown   → ssh forced command
   └───────┬──────────────┬───────┘
           │              │
  UDP broadcast :9,:7     │  ssh (LAN only, key with command="…")
  ×3 bursts               │
           ▼              ▼
   ┌──────────────────────────────┐
   │  Gaming PC (wired)           │
   │   NIC armed for magic packet │
   │   Fast Startup OFF           │
   │   sshd → pcpower.ps1         │
   │   Sunshine (service)         │
   └──────────────────────────────┘
           ▲
           │  Moonlight / RDP, device-to-device over Tailscale
           │  (the Pi is not in this path)
```

A session, in order:

1. Open the `pcctl` page (bookmark on the phone home screen) → **Wake**.
2. The Pi sprays magic packets; `--wait` polls TCP 22 until the PC answers — typically 3–8 s from S3.
3. Moonlight or RDP straight to the PC's tailnet address. The Pi is out of the loop.
4. Done → **Sleep** on the same page, or let the 30-minute idle timeout do it.

Nice touch: **Moonlight can do step 1 for you.** Its HTTP-wake feature (added for the v7.0 milestone,
[moonlight-qt#1770](https://github.com/moonlight-stream/moonlight-qt/pull/1770)) issues a plain GET to a URL you
configure. Point it at `http://<pi-tailnet-ip>:8080/wake?token=…&wait=1` and pressing "start streaming" wakes the PC
by itself — which is exactly why `pcctl` serves `/wake` over GET as well as POST.

### What this repo now ships

| Piece                                  | Where                                                    |
|----------------------------------------|-----------------------------------------------------------|
| Magic packet: multi-address, retries   | [`crates/net/src/wol.rs`](../crates/net/src/wol.rs)       |
| "Is it up?" TCP probe                  | [`crates/net/src/probe.rs`](../crates/net/src/probe.rs)   |
| CLI + HTTP control API                 | [`apps/pcctl`](../apps/pcctl/README.md)                   |
| Clap → wake, from the sofa             | [`apps/clapper`](../apps/clapper/README.md)               |
| PC-side setup + power dispatcher       | [`provision/pc/windows`](../provision/pc/windows/)        |
| Service + installer wiring             | `provision/systemd/pcctl.service`, `INSTALL_PCCTL=yes`    |

---

## Part 9 — When it doesn't work

A triage order, cheapest test first:

1. **Is the link light on when the PC is off?** Dark = the NIC has no standby power. It's ErP/EuP in the BIOS, or the
   PSU switch, or a USB NIC. No amount of software fixes this.
2. **`pcctl config`** — is the MAC the *wired* NIC's, and the broadcast address your actual subnet?
3. **Does it work from the Pi's shell but not the API?** Then it's `LISTEN_ADDR`/token/firewall, not WoL.
4. **Does it work from a wired laptop but not the Pi?** Wi-Fi broadcast bridging — Part 4's caveat. Try
   `WOL_BROADCASTS=192.168.1.255` only, raise `WOL_REPEAT`, check AP isolation.
5. **Does it wake from sleep but not from shutdown?** Expected. Fast Startup (Part 2). Sleep instead, or explicitly
   hibernate.
6. **Did it work yesterday and not today?** A power cut or BIOS update resets the WoL toggle on many boards.
7. **Watch the wire.** On the Pi: `sudo tcpdump -i wlan0 -n 'udp port 9 or udp port 7'` while sending, to confirm the
   packet actually leaves. On another wired machine, the same filter confirms it arrives.

### The fallback that always works: press the button

If the NIC is dead, the OS is hung, or the board simply refuses to be woken, there's a mechanism that doesn't care:
**short the PWR_SW header for 200 ms**, exactly like the case button, and hold it 5 s for a hard power-off.

Wire a Pi GPIO through an **optocoupler** (PC817 and friends) or a small relay to the header's two pins. The
optocoupler is the better choice — it keeps the Pi's ground and the PC's ground galvanically separate, which is what
you want between two devices with their own PSUs. Drive it high for 200 ms to press, 5 s to force off.

This is the honest escape hatch for Modern Standby laptops and stubborn boards, and it doubles as remote *reset* when
something hangs. It's the natural next app in this repo — `devices` already has the GPIO output layer that `led.rs`
uses.

---

## Part 10 — Security review of this design

What an attacker gets at each step, assuming they've got what they need for the step before:

| If they have…                        | They can…                                       | Because                                        |
|--------------------------------------|-------------------------------------------------|------------------------------------------------|
| A packet on your LAN                 | Boot your PC                                    | WoL is unauthenticated by design                |
| The `pcctl` URL, no token            | Nothing                                         | 401; and `serve` refuses non-loopback w/o token |
| The `pcctl` token                    | Wake/sleep/shut down your PC                    | That's the whole API — no shell, no files       |
| Root on the Pi                       | Wake/sleep/shut down your PC                    | The SSH key is pinned to a forced command       |
| Your Tailscale account               | Everything on the tailnet                       | ← **this is the real crown jewel**              |

Which gives a short and unglamorous list of what actually matters:

1. **Protect the Tailscale account.** MFA on it. It is a bigger key than anything on the Pi.
2. **Keep the token out of git.** `.env` is gitignored and baked at compile time; the same pattern the rest of the
   repo uses. Generate with `openssl rand -hex 32`.
3. **Bind `pcctl` to the tailnet address**, not `0.0.0.0` — `LISTEN_ADDR=100.x.y.z:8080`. It refuses to serve a
   non-loopback address without a token, but binding narrowly is still the right habit.
4. **Keep the forced command.** It's what makes "the Pi is compromised" a bad afternoon instead of a bad month.
5. **Never port-forward** UDP 9, 3389, or 22. There is no version of this design that needs an open port.
6. The HTTP API is plain HTTP — fine *inside* WireGuard, which is already encrypted end to end. Don't move it outside
   the tunnel without TLS.

---

## Part 11 — What it costs to leave things on

Rough numbers; measure your own with a plug meter if it matters.

| State                        | Draw          | A month, continuous |
|------------------------------|---------------|---------------------|
| Gaming PC, idle at desktop   | 50–90 W       | ~36–65 kWh          |
| Gaming PC, **sleep (S3)**    | 2–5 W         | ~1.5–3.6 kWh        |
| Gaming PC, shut down (S5)    | 0.5–2 W       | ~0.4–1.5 kWh        |
| Pi Zero 2 W, idle            | ~0.7–1.2 W    | ~0.5–0.9 kWh        |

The gap that matters is **idle vs sleep** — leaving the PC running costs roughly 20× what sleeping does. Sleep vs
shutdown is a couple of kWh a month: at typical Czech household rates that's small change, and you're buying a
2-second wake and a preserved session with it. The Pi's own consumption is a rounding error, and it's already on for
the departure board.

Conclusion: **sleep aggressively, shut down rarely, and don't feel bad about the Pi.**

---

## Part 12 — Build order

Each step is independently verifiable, so you always know which one broke.

1. **PC, physical.** Wired Ethernet. BIOS: WoL on, ErP off. Confirm the link light stays lit with the PC off.
2. **PC, Windows.** Run `provision/pc/windows/Setup-RemotePower.ps1 -Report` first to see the current state, then for
   real. Note the MAC it prints.
3. **Router.** DHCP reservation for the PC, so `PC_HOST` never moves.
4. **Pi, wake only.** Fill in `apps/pcctl/.env`, `make ship BIN=pcctl`, then `./pcctl wake --wait` with the PC asleep.
   *Stop here until this works* — everything downstream assumes it.
5. **Pi, power-down.** `INSTALL_PCCTL="yes"` and re-run `install.sh` to generate the SSH key; feed its public half to
   `Setup-RemotePower.ps1 -PublicKey`. Test `./pcctl sleep`, then step 4 again.
6. **Tailscale** on Pi, laptop, phone, PC. Set `LISTEN_ADDR` to the Pi's `100.x.y.z:8080` and a real `API_TOKEN`;
   rebuild, redeploy, `systemctl restart pcctl`.
7. **Sunshine** on the PC, **Moonlight** on the laptop. Pair on the LAN first, then retry over the tailnet and confirm
   `tailscale status` says `direct`.
8. **Polish.** Bookmark the control page on your phone. Point Moonlight's HTTP-wake at `/wake?token=…&wait=1`. Set
   `powercfg /change standby-timeout-ac 30`. Optionally teach `clapper` to call the API so a double clap still works.

---

## Sources

Wake-on-LAN and Windows power states:
- [Microsoft Learn — Wake on LAN behavior](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/wake-on-lan-feature)
- [Microsoft Learn — SetSuspendState function](https://learn.microsoft.com/en-us/windows/desktop/api/PowrProf/nf-powrprof-setsuspendstate)
- [Dell — Wake-on-LAN troubleshooting and best practices](https://www.dell.com/support/kbdoc/en-us/000129137/wake-on-lan-wol-troubleshooting-best-practices)
- [ArchWiki — Wake-on-LAN](https://wiki.archlinux.org/title/Wake-on-LAN)
- [Windows 11 Forum — Wake On LAN and the S0 power state](https://www.elevenforum.com/t/wake-on-lan-and-s0-power-state-or-alternative-wake-solution.21596/)
- [Wikipedia — Wake-on-LAN](https://en.wikipedia.org/wiki/Wake-on-LAN)

Packet delivery, ARP and directed broadcast:
- [Cisco Community — WoL, ARP cache, unicast, directed broadcast](https://community.cisco.com/t5/switching/wake-on-lan-not-working-arp-cache-unicast-direct-broadcast/td-p/3407936)
- [SmallNetBuilder — Wake Up Your LAN!](https://www.smallnetbuilder.com/lanwan/lanwan-howto/wake-up-your-lan/)

Remote access:
- [Tailscale — Making a Wake-on-LAN server using Tailscale, UpSnap, and Raspberry Pi](https://tailscale.com/blog/wake-on-lan-tailscale-upsnap)
- [Tailscale vs WireGuard vs Cloudflare Tunnel (2026)](https://www.binarytechlabs.com/tailscale-vs-wireguard-vs-cloudflare-tunnel/)
- [Breaking the 5 Mbps barrier — Moonlight over Tailscale](https://cfreeman.cloud/breaking-the-5-mbps-barrier-streaming-moonlight-over-tailscale-with-full-bandwidth/)

Remote shutdown:
- [Microsoft Learn — OpenSSH Server configuration for Windows](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration)
- [Win32-OpenSSH — public key authentication setup](https://github.com/PowerShell/Win32-OpenSSH/wiki/Setup-public-key-based-authentication-for-windows)
- [OpenSSH for Windows and administrators_authorized_keys](https://journal.jadaptive.com/openssh-windows-administrators-authorized-keys/)
- [4sysops — Sleep a computer remotely from the command line](https://4sysops.com/archives/sleep-computer-remotely-from-the-command-line/)
- [Sysinternals — PsShutdown](https://learn.microsoft.com/sysinternals/downloads/psshutdown)
- [PhotoStructure — Wake-on-LAN with systemd](https://photostructure.com/coding/wake-on-lan/)

Streaming:
- [Sunshine documentation (LizardByte)](https://docs.lizardbyte.dev/projects/sunshine/latest/)
- [moonlight-qt#1770 — HTTP wake support](https://github.com/moonlight-stream/moonlight-qt/pull/1770)
- [Pi Stack — Sunshine vs Parsec vs Moonlight (2026)](https://www.pistack.xyz/posts/sunshine-vs-parsec-vs-moonlight-self-hosted-game-streaming-guide-2026/)
- [Moonlight vs Parsec vs RDP for GPU remote desktop (2026)](https://superrendersfarm.com/article/moonlight-parsec-rdp-remote-desktop-gpu-rendering-2026)

Hardware fallback:
- [Remotely press a power button — Pi + optocoupler](https://medium.com/@larsborn/remotely-press-a-power-button-e03f30347536)
