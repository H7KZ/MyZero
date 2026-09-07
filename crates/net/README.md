# net

Small networking helpers shared across apps. Pure std — no dependencies — so its unit tests run on any host, not just
the Pi.

## `wol` — Wake-on-LAN

```rust
// One packet, one address — the simple case.
net::wol::send("D5-45-BC-0D-62-D0", "255.255.255.255", 9)?;

// Or the full form, for a Pi that talks to the LAN over Wi-Fi.
net::wol::Wake::new("D5-45-BC-0D-62-D0")
    .broadcasts(&["192.168.1.255", "255.255.255.255"])
    .repeat(3)
    .bind(Some("192.168.1.42"))
    .send()?;
```

Builds the 102-byte magic packet (6×`0xFF` + the MAC ×16) and sends it as a UDP broadcast the sleeping NIC listens
for. Accepts `-` or `:` separated MACs.

The extra knobs on `Wake` all exist for the same reason — the packet has to physically reach the target's wire:

- **`broadcasts`** — put the *subnet-directed* address (`192.168.1.255`) first. Some access points drop the limited
  broadcast `255.255.255.255`, and on a multi-homed host it leaves by whichever interface the route table picks.
- **`repeat`** — Wi-Fi broadcast frames are unacknowledged and sent at the lowest basic rate, so a single packet is
  easy to lose. Three bursts costs nothing.
- **`bind`** — pins the source interface. Matters on a Pi that also runs the fallback hotspot (`wlan0` + `uap0`).
- **ports** — 9 and 7 by default (`DEFAULT_PORTS`). The UDP wrapper is only a carrier; the NIC matches the payload,
  so the port is convention rather than protocol, and some BIOSes only arm one.

## `probe` — is it up?

```rust
net::probe::tcp_up("192.168.1.50", 22, Duration::from_millis(700));
net::probe::wait_up("192.168.1.50", 22, timeout, interval, Duration::from_secs(120));
```

A TCP knock, not a ping: ICMP needs raw sockets and Windows drops echo by default, while "something answers on 22"
also proves the machine finished booting rather than merely powering a NIC.

## Notes

- Everything here is unit-tested (`cargo test -p net`).
- The target PC needs Wake-on-LAN enabled (BIOS + NIC "magic packet"), and sender and target must share the LAN
  subnet — broadcasts don't route. The full checklist is in
  [`docs/remote-pc-control.md`](../../docs/remote-pc-control.md).
