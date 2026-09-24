//! Wake-on-LAN: build and send magic packets over UDP broadcast.
//!
//! A magic packet is 6 bytes of 0xFF followed by the target MAC repeated 16
//! times (6 + 16×6 = 102 bytes), sent as a UDP broadcast the sleeping NIC
//! listens for. Pure std — no dependencies.
//!
//! The payload is what the NIC matches on; the UDP wrapper is only a carrier,
//! which is why the port (9, sometimes 7) is a convention rather than a rule.
//! Broadcast frames don't route, so the sender must sit on the target's own
//! layer-2 segment — that's the Pi's job here.

use std::io;
use std::net::UdpSocket;
use std::thread::sleep;
use std::time::Duration;

/// Conventional WoL ports: `discard` (9) and `echo` (7). Some NICs/BIOSes only
/// arm one of them, so sending to both costs nothing and removes a variable.
pub const DEFAULT_PORTS: &[u16] = &[9, 7];

/// Gap between repeated bursts. Broadcast frames are unacknowledged on Wi-Fi
/// and get sent at the lowest basic rate, so a lone packet is easy to lose.
const BURST_GAP: Duration = Duration::from_millis(120);

/// Parses `"D5-45-BC-0D-62-D0"` or `"d5:45:bc:0d:62:d0"` into 6 bytes.
pub fn parse_mac(s: &str) -> Result<[u8; 6], String> {
    let parts: Vec<&str> = s.split(['-', ':']).collect();
    if parts.len() != 6 {
        return Err(format!("MAC needs 6 octets, got {} in {s:?}", parts.len()));
    }
    let mut mac = [0u8; 6];
    for (i, p) in parts.iter().enumerate() {
        mac[i] = u8::from_str_radix(p.trim(), 16).map_err(|e| format!("bad octet {p:?}: {e}"))?;
    }
    Ok(mac)
}

/// Builds the 102-byte magic packet for `mac`.
pub fn magic_packet(mac: &[u8; 6]) -> [u8; 102] {
    let mut pkt = [0xFFu8; 102];
    for i in 0..16 {
        let off = 6 + i * 6;
        pkt[off..off + 6].copy_from_slice(mac);
    }
    pkt
}

/// One wake attempt: a MAC, the broadcast addresses and ports to spray it at,
/// and how many bursts to send.
///
/// ```no_run
/// net::wol::Wake::new("D5-45-BC-0D-62-D0")
///     .broadcasts(&["192.168.1.255", "255.255.255.255"])
///     .repeat(3)
///     .send()?;
/// # Ok::<(), std::io::Error>(())
/// ```
pub struct Wake<'a> {
    mac: &'a str,
    broadcasts: &'a [&'a str],
    ports: &'a [u16],
    repeat: u32,
    bind: Option<&'a str>,
}

impl<'a> Wake<'a> {
    /// Defaults: limited broadcast, ports 9 + 7, one burst, kernel-chosen source.
    pub fn new(mac: &'a str) -> Self {
        Self {
            mac,
            broadcasts: &["255.255.255.255"],
            ports: DEFAULT_PORTS,
            repeat: 1,
            bind: None,
        }
    }

    /// Where to send. Prefer the *subnet-directed* broadcast (`192.168.1.255`)
    /// first: the limited broadcast `255.255.255.255` leaves by whichever
    /// interface the routing table picks, which on a Pi that also runs the
    /// fallback hotspot may be the wrong one.
    pub fn broadcasts(mut self, addrs: &'a [&'a str]) -> Self {
        self.broadcasts = addrs;
        self
    }

    /// Override the UDP ports (default 9 and 7).
    pub fn ports(mut self, ports: &'a [u16]) -> Self {
        self.ports = ports;
        self
    }

    /// How many bursts to send (each burst = every address × every port).
    pub fn repeat(mut self, n: u32) -> Self {
        self.repeat = n;
        self
    }

    /// Pin the source interface by binding to one of its local IPs. `None`
    /// binds `0.0.0.0` and lets the route table decide.
    pub fn bind(mut self, local_ip: Option<&'a str>) -> Self {
        self.bind = local_ip;
        self
    }

    /// Sends the packets. Returns how many datagrams left the socket.
    ///
    /// Succeeds if *any* datagram went out — a home LAN commonly rejects one
    /// of the broadcast addresses while happily accepting the other.
    pub fn send(&self) -> io::Result<usize> {
        let mac =
            parse_mac(self.mac).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
        let pkt = magic_packet(&mac);

        let socket = UdpSocket::bind((self.bind.unwrap_or("0.0.0.0"), 0))?;
        socket.set_broadcast(true)?;

        let bursts = self.repeat.max(1);
        let mut sent = 0usize;
        let mut last_err: Option<io::Error> = None;

        for burst in 0..bursts {
            if burst > 0 {
                sleep(BURST_GAP);
            }
            for addr in self.broadcasts {
                for port in self.ports {
                    match socket.send_to(&pkt, (*addr, *port)) {
                        Ok(n) if n == pkt.len() => sent += 1,
                        Ok(n) => {
                            last_err = Some(io::Error::other(format!(
                                "short send to {addr}:{port}: {n}/{} bytes",
                                pkt.len()
                            )))
                        }
                        Err(e) => last_err = Some(e),
                    }
                }
            }
        }

        match (sent, last_err) {
            (0, Some(e)) => Err(e),
            (0, None) => Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "no broadcast address / port to send to",
            )),
            _ => Ok(sent),
        }
    }
}

/// Sends one magic packet for `mac_str` to `broadcast:port`.
///
/// Shorthand for the common single-target case; use [`Wake`] for retries,
/// multiple broadcast addresses, or a pinned source interface.
pub fn send(mac_str: &str, broadcast: &str, port: u16) -> io::Result<()> {
    Wake::new(mac_str)
        .broadcasts(&[broadcast])
        .ports(std::slice::from_ref(&port))
        .send()
        .map(|_| ())
}

#[cfg(test)]
mod tests {
    use super::*;

    // Neutral test vector — not any real/example MAC, so editing example MACs
    // elsewhere can't desync these assertions.
    const TEST_MAC: [u8; 6] = [0x01, 0x23, 0x45, 0x67, 0x89, 0xAB];

    #[test]
    fn parses_dash_and_colon() {
        let a = parse_mac("01-23-45-67-89-AB").unwrap();
        let b = parse_mac("01:23:45:67:89:ab").unwrap();
        assert_eq!(a, TEST_MAC);
        assert_eq!(a, b);
    }

    #[test]
    fn rejects_bad_mac() {
        assert!(parse_mac("01-23-45-67-89").is_err()); // 5 octets
        assert!(parse_mac("ZZ-23-45-67-89-AB").is_err()); // non-hex
    }

    #[test]
    fn packet_shape() {
        let mac = TEST_MAC;
        let pkt = magic_packet(&mac);
        assert_eq!(pkt.len(), 102);
        assert_eq!(&pkt[0..6], &[0xFF; 6]); // 6-byte header
        assert_eq!(&pkt[6..12], &mac); // first MAC copy
        assert_eq!(&pkt[96..102], &mac); // 16th MAC copy
    }

    #[test]
    fn bad_mac_never_touches_the_socket() {
        let err = Wake::new("nope").send().unwrap_err();
        assert_eq!(err.kind(), io::ErrorKind::InvalidInput);
    }

    #[test]
    fn sends_one_datagram_per_address_port_burst() {
        // Loopback broadcast goes nowhere, but the send() calls still succeed,
        // so this pins the fan-out arithmetic: 2 addrs × 2 ports × 2 bursts.
        let n = Wake::new("01-23-45-67-89-AB")
            .broadcasts(&["127.0.0.1", "127.0.0.1"])
            .ports(&[9, 7])
            .repeat(2)
            .bind(Some("127.0.0.1"))
            .send()
            .unwrap();
        assert_eq!(n, 8);
    }
}
