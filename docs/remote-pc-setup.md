# Remote PC control: one-time setup

The desktop at home is the fast machine, the laptop is the one you carry, and the Pi is the always-on scrap of
hardware that bridges them. GeForce NOW, but the datacentre is your living room.

This is the *setup* doc — every step, once, in order, each independently verifiable. Day-to-day use and
troubleshooting are in [`remote-pc-usage.md`](remote-pc-usage.md).

## The mental model: three independent layers

```
REACH   how packets get to your flat at all          → Tailscale
POWER   turning the PC on and off                    → pcctl + OpenSSH (+ GPIO)
SCREEN  seeing and using the desktop                  → Sunshine/Moonlight, or RDP
```

Nothing here depends on anything else here. REACH can be tested alone. POWER works on the LAN before Tailscale
exists. SCREEN comes last. That independence is the point: when something breaks you immediately know which layer
to look at, instead of debugging three unfamiliar systems at once.

```
laptop ──Tailscale──▶ Pi ──magic packet──▶ PC ◀──Moonlight / RDP── laptop
                       └──ssh forced command──▶ sleep
```

When the network can't help — a board that won't arm its NIC, a hung OS — `pcctl press` closes a contact across the
motherboard's power-switch header through an optocoupler, exactly like the case button.

---

## Part 1 — Wake-on-LAN, briefly

A **magic packet** is 102 bytes: six `0xFF` bytes, then the target's 6-byte MAC repeated 16 times. That's the whole
protocol — no header, no checksum, no reply.

1. **It's layer 2.** The NIC has no IP while the machine is off; the frame has to physically arrive on its wire.
   This is the single most important fact in this document — it's why the Pi has to live on the PC's LAN segment
   and why a VPN alone can't do this job.
2. **The UDP wrapper is a costume.** Ports 9 and 7 are conventions, not requirements — the payload is what
   matches. `crates/net` sends both.
3. **It's unauthenticated.** Anyone who can put a frame on your LAN with your MAC in it can boot your PC. Don't
   rely on SecureOn (a NIC password feature) — it's sent in cleartext and support is patchy. The real answer is
   "don't let untrusted parties put frames on your LAN" (Part 6).

### Power states: what can actually be woken

| State | Name | NIC powered? | Resume | WoL? |
|-------|------|---------------|--------|------|
| S0 | Running | yes | — | n/a |
| S0ix | Modern Standby | sometimes | instant | unreliable |
| **S3** | **Sleep** | yes, on standby | ~2 s | **yes — the sweet spot** |
| S4 | Hibernate | usually | ~15 s | yes, if explicitly hibernated |
| S4 | Hybrid shutdown (Fast Startup) | **disarmed** | ~10 s | **no** |
| S5 | Full shutdown | firmware-dependent | ~40 s | only if BIOS keeps NIC armed |

**Fast Startup is the usual culprit.** Windows 10/11 "Shut down" does a hybrid shutdown into S4, and Microsoft's
own docs are blunt: *"WOL from S4 or S5 is unsupported [after a hybrid shutdown]... Network adapters are explicitly
not armed for WOL in these cases."* — [Microsoft Learn, Wake on LAN
behavior](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/wake-on-lan-feature).
An *explicit* hibernate leaves the NIC armed; a hybrid shutdown does not, even though both land in S4. The setup
script disables `HiberbootEnabled` for exactly this reason.

**Modern Standby (S0ix)** has replaced S3 on many recent machines, especially laptops, and WoL from it is hit or
miss — the Ethernet PHY often loses power anyway. Check with `powercfg /a`: "Standby (S3) available" is good; only
"Standby (S0 Low Power Idle)" means you're stuck with Modern Standby. A desktop with a proper ATX board almost
always has real S3.

**Recommendation: sleep, don't shut down.** ~2 s wake instead of ~40, your session survives, and it's the state
Windows reliably keeps the NIC armed for. Shut down when you're away for a week; sleep the rest of the time. The
power difference is real but small — roughly 2–5 W sleeping vs 50–90 W idle-at-desktop, i.e. leaving the PC running
costs about 20× what sleeping does. Sleep vs. full shutdown is only a couple of kWh a month.

---

## Part 2 — The PC

### In the UEFI/BIOS (manual — no script reaches these)

- Enable **wake from PCI-E/network device** (labelled `Wake on LAN`, `Resume by PCI-E Device`, `Power On By
  PCIE/PCI`, or `PME Event Wake` depending on the board).
- **Disable ErP/EuP standby-power compliance mode.** ErP cuts the standby rail and kills WoL from S5 outright — if
  the Ethernet port's LED is dark with the PC off, this is almost always why.
- Use the motherboard's own Ethernet port, wired. WoWLAN (Wi-Fi WoL) is unreliable, and a **USB NIC loses bus power
  at S5** and can never wake the machine.

### Run the setup script

```powershell
# elevated PowerShell, from provision/pc/windows/
.\Setup-RemotePower.ps1 -Report                     # what's the state now?
.\Setup-RemotePower.ps1 -PublicKey .\id_pcctl.pub   # apply
```

It's idempotent — re-running is the update path. What it changes, and why each piece matters, is in
[`provision/pc/windows/README.md`](../provision/pc/windows/README.md); the short version:

- Arms the NIC for magic-packet wake, turns off pattern-wake (which would fire on ordinary broadcast traffic) and
  Energy-Efficient/Green Ethernet.
- Disables Fast Startup's NIC-disarming behaviour (`HiberbootEnabled`).
- Installs OpenSSH Server with a standard local account whose key is pinned to a **forced command** — so whatever
  the Pi asks for, `sshd` discards it and runs one dispatcher script instead, which accepts exactly `sleep` /
  `hibernate` / `shutdown` / `status`. A compromised Pi buys an attacker the ability to turn the PC off, nothing
  more. Verify it:

  ```sh
  ssh -i ~/.ssh/id_pcctl pcpower@<pc-ip> status   # should print uptime
  ssh -i ~/.ssh/id_pcctl pcpower@<pc-ip> whoami   # must be REFUSED
  ```

Confirm the result:

```powershell
powercfg /a                        # is "Standby (S3)" available, or only Modern Standby?
powercfg /devicequery wake_armed   # your NIC should be listed
```

### Sleep vs. hibernate: a trap worth knowing about

The command everyone copies off the internet, `rundll32.exe powrprof.dll,SetSuspendState 0,1,0`, ignores its
arguments — the machine **hibernates whenever hibernation is enabled**, so a requested 2-second sleep becomes a
15-second hibernate. The PC-side dispatcher calls `SetSuspendState` through P/Invoke instead, which is
unambiguous. `Setup-RemotePower.ps1 -DisableHibernation` (`powercfg /hibernate off`) removes the ambiguity
entirely by disabling hibernation and Fast Startup together, at the cost of losing S4 as a fallback.

### If the PC runs Linux instead

```sh
sudo ethtool -s enp5s0 wol g          # arm it (not persistent!)
sudo ethtool enp5s0 | grep Wake-on    # "Wake-on: g" = armed
```

Most distros reset this on boot — make it persistent with a small `oneshot` systemd unit that runs `ethtool -s
<iface> wol g` on `network-online.target`. Point `SLEEP_COMMAND` at `ssh … systemctl suspend` (a narrow sudoers
rule or a polkit-permitted user) and `SHUTDOWN_COMMAND` at `systemctl poweroff`.

---

## Part 3 — The router

Set a **DHCP reservation** for the PC so its LAN IP never moves — `PC_HOST` in `pcctl`'s config depends on this
staying stable.

Broadcasts don't route, which is the entire reason the Pi exists instead of a port-forwarding rule: a magic packet
sent from outside the LAN has to be turned back into a local broadcast by something already on the wire.
Port-forwarding UDP 9 to the PC's IP looks like it works, then silently stops once the router's ARP cache entry for
a sleeping PC expires (5–10 minutes) — nothing is logged, nothing looks broken. A Pi already on the LAN removes the
category entirely: it broadcasts locally, no router or ARP lookup in the path.

If the Pi reaches the LAN over Wi-Fi, also check for **AP isolation / client isolation** and turn it off, and keep
the Pi off any guest SSID (usually a separate broadcast domain by design).

---

## Part 4 — The Pi

```sh
cp apps/pcctl/.env.example apps/pcctl/.env      # fill in PC_MAC, PC_HOST, WOL_BROADCASTS, API_TOKEN, ...
make ship BIN=pcctl                             # from repo root
```

Key reference for every value is in [`apps/pcctl/README.md`](../apps/pcctl/README.md#env-reference) — don't
duplicate it here, that's the one place it's kept current.

Test on the LAN before anything else — **stop here until this works**, everything downstream assumes it:

```sh
./pcctl status
./pcctl sleep
./pcctl wake --wait
```

**Autostart:** set `INSTALL_PCCTL=yes` in `provision/pizero.conf` and re-run `install.sh` — this also generates
`~/.ssh/id_pcctl` on the Pi and prints the public half to feed into `Setup-RemotePower.ps1 -PublicKey` on the PC
(Part 2).

### The Wi-Fi Pi caveat

If the Pi reaches the LAN over Wi-Fi rather than Ethernet, three things can drop the packet, and `pcctl`'s config
routes around all three:

| Problem | Mitigation |
|---|---|
| Wi-Fi broadcast frames are unacknowledged; a lone packet is lost | `WOL_REPEAT=3` — send several bursts |
| Some access points drop `255.255.255.255` but pass the subnet-directed broadcast | `WOL_BROADCASTS` is a list; put the subnet-directed address first |
| The Pi is multi-homed (`wlan0` + the fallback hotspot's `uap0`) | `WOL_BIND` pins the source interface |

If Wi-Fi turns out flaky in practice, a USB-Ethernet adapter on the Pi's OTG port removes the last variable — test
first, you probably won't need it.

---

## Part 5 — Tailscale (reach)

A WireGuard mesh with identity-based auth and NAT traversal, installed on the Pi, laptop, phone, and PC:

```sh
curl -fsSL https://tailscale.com/install.sh | sh && sudo tailscale up
```

**Why it's the right default here:** zero open ports — nothing listens on your public IP; works behind CGNAT;
devices get stable `100.x.y.z` addresses, so `pcctl`'s `LISTEN_ADDR` can bind the Pi's tailnet address and be
reachable from your phone and nowhere else; and the **PC joins the tailnet too**, so Moonlight/RDP go
device-to-device rather than through the Pi — the Pi's only job stays "put a frame on the wire".

Underneath it's plain [WireGuard](https://www.wireguard.com/) with the painful parts (key exchange, NAT traversal)
automated by a coordination server; your traffic does not flow through Tailscale's infrastructure except as a
fallback. `tailscale status` is the one command to remember — it lists every device and says `direct` (good) or
`relay` (bad, caps a stream around a few Mbps) for each. If you're stuck on relay, forward **UDP 41641** to the PC.

Set `LISTEN_ADDR` to the Pi's `100.x.y.z:8080` and a real `API_TOKEN`, then redeploy and restart the service.

**Gotcha:** this account is now the master key to everything below it. Put MFA on it.

Alternatives: plain WireGuard (same crypto, no NAT-traversal help), Headscale (self-hosted coordination server), or
a Cloudflare Tunnel in front of `pcctl serve` if you also want the control page reachable from a borrowed browser
with no client installed — not useful for the streaming half, which is UDP.

---

## Part 6 — Security review

What an attacker gets at each step, assuming they've got what they need for the step before:

| If they have… | They can… | Because |
|---|---|---|
| A packet on your LAN | Boot your PC | WoL is unauthenticated by design |
| The `pcctl` URL, no token | Nothing | 401; `serve` refuses non-loopback without a token |
| The `pcctl` token | Wake/sleep/shut down your PC | That's the whole API — no shell, no files |
| Root on the Pi | Wake/sleep/shut down your PC | The SSH key is pinned to a forced command |
| Your Tailscale account | Everything on the tailnet | **the real crown jewel** |

What actually matters: MFA on the Tailscale account; keep `.env` files off git (gitignored, deployed separately —
see [`apps/pcctl/README.md`](../apps/pcctl/README.md)); bind `pcctl` to the tailnet address, not `0.0.0.0`; never
port-forward UDP 9, 3389, or 22 — there is no version of this design that needs an open port; and remember the
control API is plain HTTP, fine inside the already-encrypted Tailscale tunnel, not outside it without TLS.

---

## Part 7 — Optional: the front-panel switch (hardware fallback)

Only needed if Wake-on-LAN can't work on the board at all — Modern Standby with no S3 toggle, a hung OS, a BIOS
that forgets its settings after a power cut. `pcctl press` closes a contact across the motherboard's `PWR_SW`
header through an **optocoupler** (never a direct wire — it keeps the two PSUs' grounds separate), in parallel
with the case button.

Wiring, the BCM 9–27 pin rule (pins 0–8 boot with a pull-up that would hold the button down for ~20 s), and the
rest of the safety rules are in
[`crates/devices/README.md`](../crates/devices/README.md#the-front-panel-switch--read-this-before-wiring-it) —
this is where the invariants live, not duplicated here. Optionally wire the power-LED header back through a second
optocoupler (`POWER_LED_GPIO_PIN`) for ground-truth "does it have power" that a network probe can't give you.

---

## Build order, start to finish

Each step is independently verifiable, so you always know which one broke.

1. **PC, physical.** Wired Ethernet. BIOS: WoL on, ErP off. Confirm the link light stays lit with the PC off.
2. **PC, Windows.** `Setup-RemotePower.ps1 -Report` first, then for real. Note the MAC it prints.
3. **Router.** DHCP reservation for the PC.
4. **Pi, wake only.** Fill in `apps/pcctl/.env`, `make ship BIN=pcctl`, then `./pcctl wake --wait` with the PC
   asleep. Stop here until this works.
5. **Pi, power-down.** `INSTALL_PCCTL=yes` + re-run `install.sh` to generate the SSH key; feed its public half to
   `Setup-RemotePower.ps1 -PublicKey`. Test `./pcctl sleep`, then step 4 again.
6. **Tailscale** on Pi, laptop, phone, PC. Real `LISTEN_ADDR` and `API_TOKEN`; redeploy, `systemctl restart
   pcctl`.
7. **Sunshine + Moonlight**, paired on the LAN first, then confirmed over the tailnet with `direct` in `tailscale
   status`. See [`remote-pc-usage.md`](remote-pc-usage.md) for the screen-tool setup.
8. **Polish.** Bookmark the control page on your phone, point Moonlight's HTTP-wake at `/wake?token=…&wait=1`, set
   `powercfg /change standby-timeout-ac 30`.

---

## Sources

Wake-on-LAN and Windows power states:
- [Microsoft Learn — Wake on LAN behavior](https://learn.microsoft.com/en-us/troubleshoot/windows-client/setup-upgrade-and-drivers/wake-on-lan-feature)
- [Microsoft Learn — SetSuspendState function](https://learn.microsoft.com/en-us/windows/desktop/api/PowrProf/nf-powrprof-setsuspendstate)
- [Dell — Wake-on-LAN troubleshooting and best practices](https://www.dell.com/support/kbdoc/en-us/000129137/wake-on-lan-wol-troubleshooting-best-practices)
- [ArchWiki — Wake-on-LAN](https://wiki.archlinux.org/title/Wake-on-LAN)
- [Wikipedia — Wake-on-LAN](https://en.wikipedia.org/wiki/Wake-on-LAN)

Packet delivery, ARP and directed broadcast:
- [Cisco Community — WoL, ARP cache, unicast, directed broadcast](https://community.cisco.com/t5/switching/wake-on-lan-not-working-arp-cache-unicast-direct-broadcast/td-p/3407936)
- [SmallNetBuilder — Wake Up Your LAN!](https://www.smallnetbuilder.com/lanwan/lanwan-howto/wake-up-your-lan/)

Remote access:
- [Tailscale — Making a Wake-on-LAN server using Tailscale, UpSnap, and Raspberry Pi](https://tailscale.com/blog/wake-on-lan-tailscale-upsnap)
- [Tailscale vs WireGuard vs Cloudflare Tunnel (2026)](https://www.binarytechlabs.com/tailscale-vs-wireguard-vs-cloudflare-tunnel/)

Remote shutdown:
- [Microsoft Learn — OpenSSH Server configuration for Windows](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh-server-configuration)
- [Win32-OpenSSH — public key authentication setup](https://github.com/PowerShell/Win32-OpenSSH/wiki/Setup-public-key-based-authentication-for-windows)
- [OpenSSH for Windows and administrators_authorized_keys](https://journal.jadaptive.com/openssh-windows-administrators-authorized-keys/)
- [Sysinternals — PsShutdown](https://learn.microsoft.com/sysinternals/downloads/psshutdown)
- [PhotoStructure — Wake-on-LAN with systemd](https://photostructure.com/coding/wake-on-lan/)

Hardware fallback:
- [Remotely press a power button — Pi + optocoupler](https://medium.com/@larsborn/remotely-press-a-power-button-e03f30347536)
- [Raspberry Pi forums — default GPIO pull state at boot](https://forums.raspberrypi.com/viewtopic.php?t=123427)
- [rppal — `OutputPin` and reset-on-drop](https://docs.rs/rppal/latest/rppal/gpio/struct.OutputPin.html)

> **Caveat on the list above:** an earlier draft of this document also cited Microsoft's PnPCapabilities support
> article as the mechanism `Setup-RemotePower.ps1` uses to keep the NIC powered. That's wrong — the script
> deliberately avoids `PnPCapabilities` (its bit meanings are unreliable across drivers) and uses the
> `MSPower_DeviceEnable` WMI class instead. See `provision/pc/windows/Setup-RemotePower.ps1` for the actual
> mechanism.
