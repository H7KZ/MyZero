# net

Small networking helpers shared across apps. Pure std — no dependencies — so its
unit tests run on any host, not just the Pi.

## `wol` — Wake-on-LAN

```rust
net::wol::send("D8-43-AE-5A-89-A6", "255.255.255.255", 9)?;
```

Builds the 102-byte magic packet (6×`0xFF` + the MAC ×16) and sends it as a UDP
broadcast the sleeping NIC listens for. Accepts `-` or `:` separated MACs.

- `parse_mac`, `magic_packet`, and `send` are unit-tested (`cargo test -p net`).
- The target PC needs Wake-on-LAN enabled (BIOS + NIC "magic packet"); sender and
  target must share the LAN subnet (broadcast doesn't route).
