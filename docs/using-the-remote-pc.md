# Using the machine: screens, controllers and buttons

[`remote-pc-control.md`](remote-pc-control.md) is the *why* — power states, packet delivery, security. This one is the
*how*: what to install, what to press, and what it feels like day to day.

---

## What goes where

| Device            | Install                                     | Why                                                       |
|-------------------|---------------------------------------------|-----------------------------------------------------------|
| **Gaming PC**     | Tailscale, Sunshine, OpenSSH (via the setup script) | Joins the tailnet, streams the screen, accepts power commands |
| **Laptop**        | Tailscale, Moonlight, an RDP client         | Two screens onto the same machine — pick per task          |
| **Phone**         | Tailscale, Moonlight (optional), Shortcuts / HTTP Shortcuts | The power button in your pocket            |
| **Pi Zero 2**     | Tailscale, `pcctl`                          | Wakes the PC; the only device that must stay on            |

Everything except Tailscale is optional depending on which half you want. Tailscale is the one piece that makes all of
it work without opening a single port.

---

## Part 1 — Pick your screen

There are two good tools and they are good at different things. Install both; the choice takes a second.

| What you're doing                        | Use          |
|------------------------------------------|--------------|
| Terminal, editor, browser, compiling      | **RDP**      |
| Anything with a 3D viewport               | **Moonlight**|
| Games                                     | **Moonlight**|
| Video editing / colour work               | **Moonlight**|
| Reading docs on hotel Wi-Fi               | **RDP**      |
| A long-running job you just want to check | **RDP**      |

### RDP — for work

Windows 11 **Pro** has it built in (Home does not — that's the one feature difference that matters here).

```
Settings → System → Remote Desktop → On
```

Then from the laptop connect to the PC's **tailnet** address (`100.x.y.z`), not its LAN address — that way the same
shortcut works at home and away. Clients: `mstsc` on Windows, **Windows App** (formerly Microsoft Remote Desktop) on
macOS/iOS/Android, **FreeRDP** or **Remmina** on Linux.

What makes it good here: text is rendered as text rather than smeared through a video codec, it uses a fraction of the
bandwidth, it survives a dropped link and reconnects where you were, and it needs nothing installed on the PC. Modern
RDP will use the GPU encoder (AVC444) when it's worth it.

What makes it bad for games: 30–100 ms end-to-end, and it takes over the console session — which also means Sunshine
can't stream while you're in an RDP session.

> **If you're on Windows 11 Home**, skip RDP and use Moonlight for everything, or add
> [RustDesk](https://rustdesk.com/) (self-hostable) as the light-weight option. Don't buy a Pro upgrade just for this
> until you've confirmed Moonlight alone isn't enough.

### Sunshine + Moonlight — for everything with pixels that move

**On the PC:** install [Sunshine](https://github.com/LizardByte/Sunshine/releases) with the MSI. It registers as a
Windows service, so it's up before you log in and survives reboots. Open `https://localhost:47990`, set a username and
password for the web UI, and that's the host done.

**On the laptop/phone/TV:** install [Moonlight](https://moonlight-stream.org/). It should discover the PC on the LAN;
away from home it finds it at the tailnet address. Pair once with the PIN from Sunshine's web UI.

Settings worth changing from the defaults, in order of impact:

| Setting        | Set to                            | Why                                                        |
|----------------|-----------------------------------|-------------------------------------------------------------|
| Bitrate        | ~20–30 Mbps for 1080p60           | Your home *upload* is the ceiling — test it first           |
| Resolution/FPS | Match the client's screen         | Streaming 4K to a 1080p laptop wastes the whole uplink      |
| Codec          | HEVC (or AV1 on recent GPUs)      | Same quality for noticeably less bandwidth than H.264       |
| V-Sync         | Off, in Moonlight                 | Adds a frame of latency for no benefit on a stream          |

**Do the first pairing on the LAN**, then move to the tailnet. Debugging pairing and NAT traversal at the same time is
twice the work.

### What not to bother with

TeamViewer, AnyDesk and Chrome Remote Desktop all work and all feel like remote *support* tools: fine for fixing
someone's printer, wrong for using a machine as your daily driver. Parsec is genuinely good and easier to set up than
Sunshine — reach for it if Sunshine fights you — but it's closed-source with a paid tier for some features, and you
already have the self-hosted path working.

---

## Part 2 — Game controllers

The one thing everybody gets wrong: **plug the controller into the client** (the laptop you're sitting at), never into
the gaming PC. Moonlight captures the pad locally and sends the inputs upstream; Sunshine then recreates it on the PC
as a virtual Xbox controller, so games see a normal gamepad.

- Up to **4 controllers** at once, with mappings for most common pads built in.
- On Windows the virtualisation needs the **ViGEmBus** driver. Sunshine bundled it with its installer until the May
  2026 release; newer versions don't, so if a controller that used to work stops being recognised after an update,
  grab ViGEmBus from Sunshine's web UI → Troubleshooting.
- Bluetooth pads add their own latency on the client side. For twitchy games, a cable to the laptop is free
  responsiveness.

---

## Part 3 — Buttons: every way to trigger the wake

`pcctl serve` is one HTTP endpoint, so anything that can make an HTTP request is a power button. Ranked by effort:

| Trigger                          | Hardware needed        | Effort | Notes                                     |
|----------------------------------|------------------------|--------|-------------------------------------------|
| Phone home-screen shortcut       | none                   | 5 min  | **Start here.** Feels like a native app.  |
| Browser bookmark to `/?token=…`  | none                   | 1 min  | The full control page, any device         |
| Moonlight's built-in HTTP wake   | none                   | 2 min  | Wake happens *inside* "start streaming"   |
| Clap                             | KY-038 (you have one)  | done   | `clapper`, already in this repo           |
| A real button on the Pi          | button + 2 wires       | 10 min | `devices::button` — a desk button, wired  |
| ESP32 / ESPHome button           | ESP32 + button         | 1 h    | Battery, wireless, put it anywhere        |
| Shelly / Zigbee button           | Shelly BLU, hub        | 1 h    | If you already run Home Assistant         |
| Stream Deck key                  | Stream Deck            | 5 min  | Its "Website"/HTTP action hits the URL    |

### The phone shortcut (do this one)

**iPhone** — Shortcuts app → new shortcut → *Get Contents of URL*:

```
URL:    http://100.x.y.z:8080/wake?wait=1
Method: GET
Headers: Authorization: Bearer <your API_TOKEN>
```

Then *Add to Home Screen*. Give it an icon. It's now a button that boots your PC. Make a second one for `/sleep`
(method **POST**) and you have the pair.

**Android** — [HTTP Shortcuts](https://http-shortcuts.rmy.ch/) does exactly this and adds home-screen widgets and
quick-settings tiles, so the wake button can live in your pull-down shade.

Both need Tailscale connected on the phone for the `100.x` address to resolve. Tailscale on iOS/Android stays connected
in the background with negligible battery cost.

### Moonlight's own wake

Moonlight can issue an HTTP GET before it starts streaming ("Configure Wake" on the host tile). Point it at:

```
http://100.x.y.z:8080/wake?token=<API_TOKEN>&wait=1
```

Now there is no separate step at all: press *start streaming*, Moonlight wakes the PC, waits for it, and connects.
This is the nicest version of the whole system.

### A physical button, wired properly

If you want something to actually *press*, two shapes:

**On the Pi** — a momentary button on a GPIO, read with `devices::button`, calling `pcctl wake` (or toggling on the
current status). No network involved, nothing to pair, works when your phone is dead. This is a ~20-line app and the
natural sibling of `clapper`.

**Anywhere in the flat** — an ESP32 running [ESPHome](https://esphome.io/) with a button and a `http_request` action
posting to the same URL. Battery-powered, wireless, and you can put it next to the sofa. A Shelly device's webhook
does the same thing with no firmware work if you already have one.

Either way the button hits the same endpoint the phone does — there is one control surface, not several.

### And when the network can't help at all

The [front-panel switch](../crates/devices/README.md#the-front-panel-switch--read-this-before-wiring-it) is the bottom
of the stack: `pcctl press` closes a contact across the motherboard's `PWR_SW` header through an optocoupler, exactly
as if you'd walked over and pressed the case button. It works when the NIC is dead, when Wake-on-LAN was never
supported, and when Windows is hung. `pcctl force-off --yes` is the 6-second hold.

---

## Part 4 — A day in the life

**Morning, working from a café.** Open the phone shortcut → wake. By the time the laptop lid is up, the PC is on. RDP
to `100.x.y.z`. Everything is where you left it because the machine was asleep, not off. Work. Close the lid; the
30-minute idle timeout sleeps the PC by itself.

**Evening, games on the sofa.** Open Moonlight on the laptop or the TV box, press *start streaming*. It wakes the PC
itself via the HTTP-wake URL, waits, connects. Controller plugged into the laptop. Quit when done; press *Sleep* on the
control page, or let the timeout handle it.

**Away for a week.** `pcctl shutdown` before leaving — a real S5 shutdown saves a few kWh over a week of sleeping. To
wake it again you'll need Wake-from-S5 working (BIOS `ErP` disabled), or the front-panel switch, which doesn't care.

**Something's wrong.** `pcctl status` says down but the power LED is lit → it's hung, not off. `pcctl press` asks
Windows politely; `pcctl force-off --yes` if it's not listening. Then `pcctl wake`.

---

## Part 5 — The details you'll hit in week one

**Audio** — Sunshine streams the PC's audio to the client and mutes the host's speakers while streaming, so a sleeping
flat stays quiet. RDP redirects audio too. Microphone in the other direction is not Sunshine's strong suit; use a
local app for calls.

**Files** — the honest answer is *don't move files, work on the PC*. When you do need them: with everything on the
tailnet, a plain Windows share (`\\100.x.y.z\...`) works, or run [Syncthing](https://syncthing.net/) for a folder that
lives on both machines. Both are far better than dragging files through a remote-desktop clipboard.

**Multi-monitor** — Moonlight streams one display at a time. If the PC has three monitors, you'll be switching between
them, which is worse than it sounds. Options: set a single-display profile for streaming, or add a **virtual display
driver** so the stream gets its own correctly-sized screen.

**No monitor attached** — Windows' screen capture needs something for the GPU to drive. Headless, buy an **HDMI dummy
plug** (~$8) or use a virtual display driver; without one you get a 640×480 phantom desktop.

**Clipboard** — RDP shares it by default. Moonlight doesn't; that's a real papercut and the main reason to keep RDP
around for text work.

**HDR** — Sunshine supports it, and it's more trouble than it's worth over a stream. Leave it off until everything
else is solid.

---

## Part 6 — Making it feel fast

In order of how much each one matters:

1. **`tailscale status` must say `direct`, not `relay`.** A DERP relay caps you around 5 Mbps and no amount of setting
   changes fixes that. Forward **UDP 41641** to the PC if you're stuck relayed.
2. **Know your home upload.** It is the hard ceiling. 1080p60 wants ~20–30 Mbps; if your uplink is 10, stream 1080p30
   or 720p60 and it will feel better than a stuttering 1080p60.
3. **Wire what you can.** The PC on Ethernet is non-negotiable (WoL needs it anyway). The laptop on Wi-Fi 5 GHz or
   Ethernet; 2.4 GHz will add jitter you can feel.
4. **Match the resolution to the client screen.** Free quality, every time.
5. **HEVC or AV1** over H.264.
6. **Turn off Moonlight's V-Sync**, and cap the game's frame rate to the stream's frame rate so the encoder isn't
   fighting a game running at 300 fps.

What "good" feels like: on a LAN, indistinguishable from sitting at the machine. Over a decent home uplink with a
direct connection, obviously remote for twitch shooters and completely fine for everything else.

---

## Part 7 — Things that will annoy you

| Symptom                                              | Cause and fix                                                                 |
|------------------------------------------------------|-------------------------------------------------------------------------------|
| Wake works, but the stream shows a lock screen        | A service can't capture a desktop with no session. Sleep instead of shutting down (sleep preserves the session), or enable auto-login |
| Desktop resolution is tiny / icons rearranged         | No monitor attached. HDMI dummy plug or a virtual display driver               |
| PC falls asleep while you're using RDP                | Windows 11's idle timer follows the *console*, not the RDP session. PowerToys Awake, or raise the timeout |
| Sunshine won't stream while RDP is connected          | Expected — RDP takes over the console session. Sign out of RDP first           |
| Controller stopped working after a Sunshine update    | ViGEmBus is no longer bundled. Install it from Sunshine's Troubleshooting page |
| Stream is fine, then collapses to a slideshow         | Almost always a fall back to a DERP relay. Check `tailscale status`            |
| Everything works at home, nothing works away          | Tailscale isn't connected on the client, or you used the LAN IP not the `100.x` one |

---

## Part 8 — The shortest path that actually works

If you do nothing else in this document, do these six things in this order:

1. **BIOS**: Wake-on-LAN on, ErP off. Confirm the Ethernet LED stays lit with the PC off.
2. **PC**: run `Setup-RemotePower.ps1 -PublicKey …`, then install **Tailscale** and **Sunshine**.
3. **Pi**: `pcctl` with a real `.env`, Tailscale, `LISTEN_ADDR` on the tailnet address, a real token.
4. **Verify the loop on the LAN first**: `pcctl status` → `pcctl sleep` → `pcctl wake --wait`. Don't move on until
   this is boring.
5. **Laptop**: Tailscale + Moonlight, paired on the LAN, then confirmed over the tailnet with `direct` in
   `tailscale status`.
6. **Phone**: one home-screen shortcut for `/wake?wait=1`. Point Moonlight's HTTP-wake at the same URL.

Then set `powercfg /change standby-timeout-ac 30` on the PC and stop thinking about it. The machine sleeps when you
walk away and wakes when you ask, and the only thing running around the clock is a Pi drawing about a watt.
