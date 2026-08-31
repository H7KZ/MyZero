//! Wake-on-LAN: build and send a magic packet over UDP broadcast.
//!
//! A magic packet is 6 bytes of 0xFF followed by the target MAC repeated 16
//! times (6 + 16×6 = 102 bytes), sent as a UDP broadcast the sleeping NIC
//! listens for. Pure std — no dependencies.

use std::io;
use std::net::UdpSocket;

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

/// Sends a magic packet for `mac_str` to `broadcast:port`.
pub fn send(mac_str: &str, broadcast: &str, port: u16) -> io::Result<()> {
    let mac = parse_mac(mac_str).map_err(|e| io::Error::new(io::ErrorKind::InvalidInput, e))?;
    let pkt = magic_packet(&mac);

    let socket = UdpSocket::bind("0.0.0.0:0")?;
    socket.set_broadcast(true)?;
    let sent = socket.send_to(&pkt, (broadcast, port))?;
    if sent != pkt.len() {
        return Err(io::Error::new(
            io::ErrorKind::Other,
            format!("short send: {sent}/{} bytes", pkt.len()),
        ));
    }
    Ok(())
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
}
