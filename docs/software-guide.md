# The software, explained

What each piece of the stack actually is, how it works, and what it's for. The companion docs answer *why the design
is shaped this way* ([`remote-pc-control.md`](remote-pc-control.md)) and *how to drive it day to day*
([`using-the-remote-pc.md`](using-the-remote-pc.md)). This one is for when you want to understand what you're
installing before you install it.

---

## The mental model: three independent layers

```
REACH   how packets get to your flat at all          → Tailscale
POWER   turning the PC on and off                    → pcctl + OpenSSH (+ GPIO)
SCREEN  seeing and using the desktop                 → Sunshine/Moonlight, or RDP
```

Nothing here depends on anything else here. REACH can be tested alone. POWER works on the LAN before Tailscale exists.
SCREEN comes last. That independence is the point: when something breaks you immediately know which layer to look at,
instead of debugging three unfamiliar systems at once.

---

# Layer 1 — REACH

## Tailscale

**What it is.** A private network that makes your devices behave as though they're all plugged into the same switch,
wherever they physically are.

**How it works.** Underneath it's [WireGuard](https://www.wireguard.com/) — a small, fast VPN protocol built into the
Linux kernel — with the painful parts automated away. Plain WireGuard means hand-writing key pairs and IP assignments
on both ends of every link. Tailscale adds a *coordination server*: devices log in with an existing identity
(Google, GitHub, …), the server tells each device about the others' public keys, and from then on **the devices talk
directly to each other**. Your traffic does not flow through Tailscale's infrastructure.

The clever part is NAT traversal. Your PC and your laptop both sit behind routers that drop inbound connections. The
coordination server gets both sides to punch outward at the same moment so a direct path forms between them. When that
fails — symmetric NAT, a hostile corporate firewall — it falls back to a **DERP relay**, a Tailscale-run server that
forwards the (still end-to-end encrypted) packets. Secure, but slow, and the single most common cause of a stream that
mysteriously collapses.

**Vocabulary you'll meet:**

| Term            | Meaning                                                                                         |
|-----------------|-------------------------------------------------------------------------------------------------|
| **tailnet**     | Your private network — all your devices under one login                                          |
| **`100.x.y.z`** | Each device's stable address, from the `100.64.0.0/10` range reserved for carrier NAT. Never changes |
| **MagicDNS**    | Lets you type `gaming-pc` instead of `100.101.102.103`                                           |
| **DERP**        | The relay fallback. `direct` good, `relay` bad                                                    |
| **exit node**   | Route *all* your internet through one device. Not needed here                                     |
| **subnet router** | Expose a whole LAN to the tailnet. Also not needed — see the note at the bottom of this page     |

**Install.**

```sh
curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up   # the Pi
```

App-store version on phone and laptop, the MSI on the PC. Same account on all four.

**The one command to remember.** `tailscale status` — lists every device and says `direct` or `relay` for each.

**Gotcha.** The free tier covers 100 devices, far more than you need. But this account is now the master key to
everything below it: put MFA on it and treat it accordingly.

---

# Layer 2 — POWER

## `pcctl` — [this repo](../apps/pcctl/README.md)

**What it is.** A small Rust binary on the Pi. The only thing in the system that can turn your PC *on*.

**How it works.** It does the one job a VPN physically cannot: put a Wake-on-LAN magic packet onto your LAN's wire. It
also knocks on a TCP port to tell whether the PC is genuinely up, and shells out over SSH to put it back to sleep.
`pcctl serve` wraps all of that behind a small token-authenticated HTTP API, which turns anything capable of an HTTP
request — a phone shortcut, Moonlight, an ESP32, a browser bookmark — into a power button.

**What you'll type.**

```sh
pcctl config          # what's baked in — always start here when confused
pcctl status          # is it up?
pcctl wake --wait     # wake, and block until it answers
pcctl sleep
```

**Gotcha.** Configuration is baked in at *compile* time from `.env`, the same pattern the rest of this repo uses. Edit
`.env` → rebuild → redeploy. Deliberate (no secrets sitting on the Pi's disk at runtime), but it surprises everyone
exactly once.

## OpenSSH Server on Windows

**What it is.** The same SSH you already know, shipped by Microsoft as an optional Windows feature. It's how the Pi
says "go to sleep."

**How it works.** Ordinary SSH; the interesting part is what
[`Setup-RemotePower.ps1`](../provision/pc/windows/README.md) does with it. The Pi's key is installed with a **forced
command**, so whatever the Pi asks for, `sshd` discards it and runs one script instead — a dispatcher that accepts
exactly four words: `sleep`, `hibernate`, `shutdown`, `status`. The key gets a shell for nothing, so a compromised Pi
buys an attacker the ability to turn your PC off and nothing more.

**Verify it's actually locked down:**

```sh
ssh -i ~/.ssh/id_pcctl pcpower@<pc-ip> status   # prints uptime
ssh -i ~/.ssh/id_pcctl pcpower@<pc-ip> whoami   # must be REFUSED
```

That second command failing is the security model working.

## The GPIO switch — optional, hardware

Only needed if Wake-on-LAN can't work on your board at all. `pcctl press` closes a contact across the motherboard's
`PWR_SW` header through an optocoupler, exactly like the case button. Nothing to install — it's wiring plus code
already in the repo. Rules and wiring:
[`devices`](../crates/devices/README.md#the-front-panel-switch--read-this-before-wiring-it).

---

# Layer 3 — SCREEN

You want **both** of the following. They are good at opposite things, and choosing between them takes a second.

## Sunshine (host) + Moonlight (client)

**What they are.** A matched pair. **Sunshine** runs on the gaming PC and captures + encodes the screen. **Moonlight**
runs on whatever you're sitting at, decodes it, and sends your keyboard, mouse and gamepad back. Sunshine is the
open-source successor to NVIDIA's GameStream after NVIDIA discontinued it; Moonlight began life as GameStream's
third-party client and the project adopted it.

**How it works, and why it's fast.** Sunshine takes frames straight off the GPU and hands them to the GPU's **hardware
video encoder** — NVENC on NVIDIA, AMF on AMD, QuickSync on Intel. That's dedicated silicon built for exactly this,
sitting alongside the cores running your game, so encoding costs you almost no frame rate. Moonlight decodes in
hardware too. Nothing touches a general-purpose software codec, which is why the result lands around 15–30 ms rather
than 100+. It is the same technique GeForce NOW uses; you're just supplying the datacentre.

**Install.** The Sunshine `.msi` on the PC — it registers as a Windows service, so it's running before you log in and
survives reboots. Moonlight from the app store or [moonlight-stream.org](https://moonlight-stream.org/) everywhere
else.

**Pairing.** Moonlight finds the PC and shows a PIN; type it into Sunshine's web UI at `https://localhost:47990`.
Once, forever.

**Ports, for information — not to forward.** Web UI `47990`; streaming TCP `47984`, `47989`, `48010`, UDP
`47998–48000`, `48002`, `48010`, plus mDNS on `5353`. **On a tailnet you forward none of these.** Guides that tell you
to port-forward them are written for people without a VPN; you have one.

**Gotchas.** It needs a display attached — headless you'll want an HDMI dummy plug (~$8) or a virtual display driver,
otherwise you get a 640×480 phantom desktop. And it can't stream while an RDP session is connected, because RDP takes
over the console session.

## Remote Desktop (RDP)

**What it is.** Microsoft's own remote desktop, built into Windows 11 **Pro**. Home doesn't have the host side — that
is the one edition difference that matters here.

**How it works, and why it's different.** RDP is not primarily a video stream. It's a *drawing protocol*: it ships
instructions ("draw this string, in this font, here") rather than pixels, and falls back to video encoding only for
regions that genuinely need it. That's why text stays razor-sharp and bandwidth is a fraction of a video stream — and
equally why a 3D viewport, where every pixel changes every frame, falls apart. Modern RDP will use the GPU encoder
(AVC444) when it decides video is the better representation.

**Install.** Nothing on the PC: `Settings → System → Remote Desktop → On`. Clients: `mstsc` on Windows, **Windows App**
(Microsoft's rename of Remote Desktop) on macOS/iOS/Android, FreeRDP or Remmina on Linux.

**Connect to the tailnet address**, `100.x.y.z` — then one shortcut works both at home and away.

## Choosing between them

| What you're doing                        | Use           |
|------------------------------------------|---------------|
| Terminal, editor, browser, compiling      | **RDP**       |
| Anything with a 3D viewport               | **Moonlight** |
| Games                                     | **Moonlight** |
| Video / colour work                       | **Moonlight** |
| Reading docs on hotel Wi-Fi               | **RDP**       |
| Checking on a long-running job            | **RDP**       |

---

# The supporting cast

| Software                              | When you need it                                                                                   |
|---------------------------------------|-----------------------------------------------------------------------------------------------------|
| **Apple Shortcuts** (iOS, built in)   | The home-screen wake button. *Get Contents of URL* → your `/wake` URL                                |
| **HTTP Shortcuts** (Android)          | The same, plus home-screen widgets and quick-settings tiles                                          |
| **ViGEmBus** (PC)                     | Makes a streamed gamepad look like a real Xbox controller. Sunshine stopped bundling it in May 2026 — get it from Sunshine's Troubleshooting page if a pad stops working |
| **A virtual display driver** (PC)     | Gives the stream its own correctly-sized screen when no monitor is attached, or when you'd rather not mirror one of three |
| **PowerToys Awake** (PC)              | Stops Windows sleeping mid-RDP-session — its idle timer watches the console, not the RDP session      |
| **Syncthing**                         | Only if you genuinely need the same files on both machines. Mostly you don't: work *on* the PC        |
| **ESPHome / Home Assistant**          | Only for a physical wireless button somewhere in the flat                                             |

---

# Install order, with a gate after each step

Don't skip the gates. Each one tells you which layer just broke.

| # | Step                                                        | Gate — don't continue until…                                            |
|---|-------------------------------------------------------------|--------------------------------------------------------------------------|
| 1 | **BIOS**: Wake-on-LAN on, ErP/EuP off                        | the Ethernet LED is still lit with the PC off                            |
| 2 | **PC**: `Setup-RemotePower.ps1 -Report`, then with `-PublicKey` | `powercfg /devicequery wake_armed` lists your NIC                      |
| 3 | **Pi**: `pcctl`, on the LAN only                             | `status` → `sleep` → `wake --wait` all work. **This step is the one that matters** |
| 4 | **Tailscale** on all four devices                            | `tailscale status` shows them all, and `/status` answers from your phone |
| 5 | **Sunshine + Moonlight**, paired **on the LAN first**        | it works locally, *then* over the tailnet with `direct` in `tailscale status` |
| 6 | **RDP + the phone shortcut**                                 | you stop thinking about any of this                                      |

Step 5 pairs locally first on purpose: debugging pairing and NAT traversal simultaneously is twice the work of doing
them one at a time.

---

# What talks to what

```
   phone / laptop ──────── Tailscale ────────┐
        │                                     │
        │ HTTP + bearer token                 │  Moonlight / RDP
        ▼                                     │  device-to-device —
   ┌──────────┐                               │  the Pi is NOT in this path
   │    Pi    │  pcctl serve                  │
   │          │                               ▼
   │  ┌───────┴──── UDP broadcast :9,:7 ──▶ ┌──────────┐
   │  │                                     │    PC    │
   │  ├───────────── ssh (LAN) ───────────▶ │ sshd     │
   │  └───────────── GPIO ────────────────▶ │ PWR_SW   │
   └──────────┘                             │ Sunshine │
                                            └──────────┘
```

The Pi is only ever in the *power* path. Video goes straight from the PC to your laptop — a Zero 2 could never carry
30 Mbps of stream, and nothing asks it to.

---

# Three things that confuse everyone

**"Do I need to forward ports?"** No. Not for Sunshine, not for RDP, not for SSH, and definitely not for Wake-on-LAN.
The single exception: if Tailscale is stuck on `relay`, forwarding **UDP 41641** to the PC gives NAT traversal
something to work with. That's an optimisation, not a requirement.

**"Which IP do I use?"** Always the `100.x.y.z` tailnet one, even when you're sitting at home. One address everywhere
means one bookmark, one shortcut, one Moonlight entry, and nothing to change when you leave the flat.

**"If Tailscale already reaches my flat, why does the Pi exist?"** Because a magic packet is a layer-2 Ethernet frame
and Tailscale is a layer-3 network. Tailscale can reach a *running* machine anywhere on earth. Only something already
on the same wire can wake a *sleeping* one. That's the Pi's entire job — about a watt, to do the one thing nothing
else in the stack can.
