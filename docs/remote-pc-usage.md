# Using the remote PC: day to day

[`remote-pc-setup.md`](remote-pc-setup.md) is the one-time build — BIOS, PC, router, Pi, Tailscale. This one is
what to press once it's all working, and what to do when it isn't.

## What goes on each device

| Device | Install | Why |
|---|---|---|
| **Gaming PC** | Tailscale, Sunshine, OpenSSH (via the setup script) | Joins the tailnet, streams the screen, accepts power commands |
| **Laptop** | Tailscale, Moonlight, an RDP client | Two screens onto the same machine — pick per task |
| **Phone** | Tailscale, Moonlight (optional), Shortcuts / HTTP Shortcuts | The power button in your pocket |
| **Pi Zero 2** | Tailscale, `pcctl` | Wakes the PC; the only device that must stay on |

Tailscale is the one piece all of it needs — it's what makes any of this work without opening a port.

---

## Part 1 — Pick your screen tool

Two good tools, good at different things. Install both.

| What you're doing | Use |
|---|---|
| Terminal, editor, browser, compiling | **RDP** |
| Anything with a 3D viewport, games, video/colour work | **Moonlight** |
| Reading docs on hotel Wi-Fi, checking a long job | **RDP** |

### RDP — for work

Built into Windows 11 **Pro** (`Settings → System → Remote Desktop → On`); Home doesn't have the host side, the
one edition difference that matters here. It's not primarily a video stream — it's a *drawing protocol* that ships
instructions ("draw this string, here") and falls back to video encoding only where the picture genuinely changes
every frame. That's why text stays sharp and bandwidth is a fraction of a stream, and equally why a 3D viewport
falls apart on it. Modern RDP uses the GPU encoder (AVC444) when it decides video is the better fit.

Connect to the PC's **tailnet address** (`100.x.y.z`), not its LAN address, so the same shortcut works at home and
away. Clients: `mstsc` on Windows, **Windows App** on macOS/iOS/Android, FreeRDP or Remmina on Linux.

> On Windows 11 Home, skip RDP and use Moonlight for everything, or add [RustDesk](https://rustdesk.com/)
> (self-hostable) — don't buy a Pro upgrade just for this until you've confirmed Moonlight alone isn't enough.

### Sunshine + Moonlight — for anything with pixels that move

**Sunshine** (open-source successor to NVIDIA GameStream) runs on the PC, captures the screen, and hands frames
straight to the GPU's hardware encoder (NVENC/AMF/QuickSync) — dedicated silicon, so encoding costs almost no
frame rate. **Moonlight** runs on whatever you're sitting at and decodes in hardware too. Nothing touches a
general-purpose software codec, which is why the latency lands around 15–30 ms instead of 100+.

Install the Sunshine `.msi` on the PC — it registers as a Windows service, up before login and surviving reboots.
Install Moonlight from [moonlight-stream.org](https://moonlight-stream.org/) everywhere else. **Pair on the LAN
first**, then move to the tailnet — debugging pairing and NAT traversal at the same time is twice the work. Web
UI is `https://localhost:47990` on the PC; pairing is a PIN typed there.

Worth changing from the defaults, in order of impact:

| Setting | Set to | Why |
|---|---|---|
| Bitrate | ~20–30 Mbps for 1080p60 | Your home *upload* is the ceiling — test it first |
| Resolution/FPS | Match the client's screen | Streaming 4K to a 1080p laptop wastes the uplink |
| Codec | HEVC (or AV1 on recent GPUs) | Same quality, less bandwidth than H.264 |
| V-Sync | Off, in Moonlight | Adds a frame of latency for no benefit on a stream |

**Ports, for information only — you forward none of these on a tailnet:** web UI 47990; streaming TCP 47984,
47989, 48010, UDP 47998–48000, 48002, 48010, mDNS 5353.

**What not to bother with:** TeamViewer/AnyDesk/Chrome Remote Desktop feel like remote *support* tools, wrong for
a daily driver. Parsec is genuinely good and easier to set up than Sunshine, but closed-source with a paid tier.

---

## Part 2 — Game controllers

Plug the controller into the **client** (the laptop you're sitting at), never the gaming PC. Moonlight captures
the pad locally and sends inputs upstream; Sunshine recreates it on the PC as a virtual Xbox controller.

- Up to 4 controllers at once, mappings for most common pads built in.
- Windows needs the **ViGEmBus** driver. Sunshine bundled it with its installer until May 2026; if a controller
  that used to work stops being recognised after an update, grab it from Sunshine's Troubleshooting page.
- Bluetooth pads add client-side latency. For twitchy games, a cable is free responsiveness.

---

## Part 3 — Every way to trigger a wake

`pcctl serve` is one HTTP endpoint, so anything that can make an HTTP request is a power button.

| Trigger | Hardware | Effort | Notes |
|---|---|---|---|
| Phone home-screen shortcut | none | 5 min | **Start here.** Feels like a native app. |
| Browser bookmark to `/?token=…` | none | 1 min | The full control page, any device |
| Moonlight's built-in HTTP wake | none | 2 min | Wake happens *inside* "start streaming" |
| Clap | KY-038 (already in this repo) | done | [`apps/clapper`](../apps/clapper/README.md) |
| A real button on the Pi | button + 2 wires | 10 min | `devices::button` — a desk button, wired |
| ESP32 / ESPHome button | ESP32 + button | 1 h | Battery, wireless, put it anywhere |
| Shelly / Zigbee button | Shelly BLU, hub | 1 h | If you already run Home Assistant |
| Stream Deck key | Stream Deck | 5 min | Its "Website"/HTTP action hits the URL |

### The phone shortcut (do this one)

**iPhone** — Shortcuts app → new shortcut → *Get Contents of URL*:

```
URL:     http://100.x.y.z:8080/wake?wait=1
Method:  GET
Headers: Authorization: Bearer <your API_TOKEN>
```

*Add to Home Screen*. Make a second one for `/sleep` (method **POST**) and you have the pair.

**Android** — [HTTP Shortcuts](https://http-shortcuts.rmy.ch/) does the same and adds home-screen widgets and
quick-settings tiles.

Both need Tailscale connected on the phone for the `100.x` address to resolve — it stays connected in the
background with negligible battery cost.

### Moonlight's own wake

"Configure Wake" on the host tile → point it at `http://100.x.y.z:8080/wake?token=<API_TOKEN>&wait=1`. Press
*start streaming*; Moonlight wakes the PC, waits, and connects — no separate step. The nicest version of the whole
system, and the reason `pcctl` serves `/wake` over GET as well as POST.

### And when the network can't help at all

The [front-panel switch](../crates/devices/README.md#the-front-panel-switch--read-this-before-wiring-it) is the
bottom of the stack: `pcctl press` closes the `PWR_SW` contact through an optocoupler, exactly as if you'd walked
over and pressed the case button. Works when the NIC is dead, WoL was never supported, or Windows is hung.
`pcctl force-off --yes` is the 6-second hard cut.

---

## Part 4 — A day in the life

**Morning, working from a café.** Phone shortcut → wake. By the time the laptop lid is up, the PC is on. RDP to
`100.x.y.z`. Everything is where you left it — asleep, not off. Close the lid; the idle timeout sleeps the PC by
itself.

**Evening, games on the sofa.** Moonlight → *start streaming*. It wakes the PC itself via the HTTP-wake URL,
waits, connects. Controller plugged into the laptop. Quit; press *Sleep* on the control page, or let the timeout
handle it.

**Away for a week.** `pcctl shutdown` before leaving — a real S5 shutdown saves a few kWh over a week of sleeping.
To wake it again you'll need wake-from-S5 working (BIOS ErP disabled), or the front-panel switch, which doesn't
care either way.

**Something's wrong.** `pcctl status` says down but the power LED is lit → it's hung, not off. `pcctl press` asks
Windows politely; `pcctl force-off --yes` if it's not listening. Then `pcctl wake`.

Closing the loop so you rarely send a manual sleep at all — set a Windows sleep timeout on AC:

```powershell
powercfg /change standby-timeout-ac 30
```

One wrinkle: on Windows 11 the idle timer follows **console** input, and activity inside an RDP-only session
doesn't always reset it, so an RDP-only session can put the machine to sleep out from under you. Streaming with
Sunshine (which drives the real console session) doesn't have this problem; PowerToys **Awake** holds the machine
up for an RDP session without touching the power plan.

---

## Part 5 — Details you'll hit in week one

**Audio** — Sunshine streams the PC's audio to the client and mutes the host speakers while streaming. RDP
redirects audio too. Microphone-in isn't Sunshine's strong suit; use a local app for calls.

**Files** — the honest answer is *don't move files, work on the PC*. When you must: a plain Windows share
(`\\100.x.y.z\...`) over the tailnet, or [Syncthing](https://syncthing.net/) for a folder on both machines. Both
beat dragging files through a remote-desktop clipboard.

**Multi-monitor** — Moonlight streams one display at a time. Set a single-display profile for streaming, or add a
virtual display driver so the stream gets its own correctly-sized screen.

**No monitor attached** — Windows' screen capture needs something for the GPU to drive. Buy an HDMI dummy plug
(~$8) or use a virtual display driver; without one you get a 640×480 phantom desktop.

**Clipboard** — RDP shares it by default; Moonlight doesn't. A real papercut, and the main reason to keep RDP
around for text work.

**HDR** — Sunshine supports it; more trouble than it's worth over a stream until everything else is solid.

---

## Part 6 — Making it feel fast

In order of how much each one matters:

1. **`tailscale status` must say `direct`, not `relay`.** A DERP relay caps you around 5 Mbps and no setting fixes
   that. Forward **UDP 41641** to the PC if stuck relayed.
2. **Know your home upload.** It's the hard ceiling — 1080p60 wants ~20–30 Mbps; on a 10 Mbps uplink, 1080p30 or
   720p60 feels better than a stuttering 1080p60.
3. **Wire what you can.** The PC on Ethernet is non-negotiable anyway (WoL needs it). The laptop on 5 GHz Wi-Fi or
   Ethernet — 2.4 GHz adds jitter you can feel.
4. Match resolution to the client screen; prefer HEVC/AV1 over H.264; turn off Moonlight's V-Sync and cap the
   game's frame rate to the stream's so the encoder isn't fighting a 300 fps game.

What "good" feels like: on a LAN, indistinguishable from sitting at the machine. Over a decent home uplink with a
direct connection: obviously remote for twitch shooters, fine for everything else.

---

## Troubleshooting

A triage order, cheapest test first:

1. **Is the link light on when the PC is off?** Dark = the NIC has no standby power — ErP/EuP in the BIOS, the
   PSU switch, or a USB NIC. No software fixes this.
2. **`pcctl config`** — is the MAC the *wired* NIC's, and the broadcast address your actual subnet?
3. **Works from the Pi's shell but not the API?** It's `LISTEN_ADDR`/token/firewall, not WoL.
4. **Works from a wired laptop but not the Pi?** Wi-Fi broadcast bridging — see the Wi-Fi Pi caveat in the setup
   doc. Try `WOL_BROADCASTS=192.168.1.255` only, raise `WOL_REPEAT`, check AP isolation.
5. **Wakes from sleep but not shutdown?** Expected — Fast Startup. Sleep instead, or explicitly hibernate.
6. **Worked yesterday, not today?** A power cut or BIOS update resets the WoL toggle on many boards.
7. **Watch the wire.** On the Pi: `sudo tcpdump -i wlan0 -n 'udp port 9 or udp port 7'` while sending, to confirm
   the packet leaves. The same filter on another wired machine confirms it arrives.

| Symptom | Cause and fix |
|---|---|
| Wake works, but the stream shows a lock screen | A service can't capture a desktop with no session — sleep instead of shutting down, or enable auto-login |
| Desktop resolution is tiny / icons rearranged | No monitor attached — HDMI dummy plug or a virtual display driver |
| PC falls asleep while you're using RDP | Windows 11's idle timer follows the console, not the RDP session — PowerToys Awake, or raise the timeout |
| Sunshine won't stream while RDP is connected | Expected — RDP takes over the console session; sign out of RDP first |
| Controller stopped working after a Sunshine update | ViGEmBus is no longer bundled — install it from Sunshine's Troubleshooting page |
| Stream collapses to a slideshow | Almost always a fall back to a DERP relay — check `tailscale status` |
| Everything works at home, nothing away | Tailscale isn't connected on the client, or you used the LAN IP instead of `100.x` |

The fallback that always works, when nothing above helps:

```sh
pcctl press               # ~250 ms — the ACPI power event
pcctl force-off --yes     # ~6 s — the ATX hard cut
pcctl reset --yes         # the reset header
```

---

## The shortest path that actually works

1. **BIOS**: Wake-on-LAN on, ErP off. Confirm the Ethernet LED stays lit with the PC off.
2. **PC**: run `Setup-RemotePower.ps1 -PublicKey …`, then install Tailscale and Sunshine.
3. **Pi**: `pcctl` with a real `.env`, Tailscale, `LISTEN_ADDR` on the tailnet address, a real token.
4. **Verify on the LAN first**: `pcctl status` → `pcctl sleep` → `pcctl wake --wait`. Don't move on until boring.
5. **Laptop**: Tailscale + Moonlight, paired on the LAN, then confirmed over the tailnet with `direct` in
   `tailscale status`.
6. **Phone**: one home-screen shortcut for `/wake?wait=1`. Point Moonlight's HTTP-wake at the same URL.

Then set `powercfg /change standby-timeout-ac 30` and stop thinking about it — the machine sleeps when you walk
away and wakes when you ask, and the only thing running around the clock is a Pi drawing about a watt.

**"Do I need to forward ports?"** No — not for Sunshine, RDP, SSH, or Wake-on-LAN. The one exception: Tailscale
stuck on `relay` — forward UDP 41641. That's an optimisation, not a requirement.

**"Which IP do I use?"** Always the `100.x.y.z` tailnet one, even at home — one bookmark, one shortcut, nothing to
change when you leave the flat.
