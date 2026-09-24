//! Is the machine up? A TCP knock, because ICMP is unreliable as a liveness test.
//!
//! Ping needs raw sockets (root or `CAP_NET_RAW`) and Windows silently drops
//! ICMP echo by default, so "does something answer on a port" is both cheaper
//! to run unprivileged and a better proxy for "usable": SSH on 22, RDP on 3389,
//! or Sunshine on 47989 all mean the box finished booting, not just that a NIC
//! is powered.

use std::net::{TcpStream, ToSocketAddrs};
use std::thread::sleep;
use std::time::{Duration, Instant};

/// True if a TCP connection to `host:port` completes within `timeout`.
///
/// A refused connection counts as *down* here: on a machine that is up but not
/// listening you'd want a different port, not a false positive.
pub fn tcp_up(host: &str, port: u16, timeout: Duration) -> bool {
    let Ok(addrs) = (host, port).to_socket_addrs() else {
        return false; // DNS/mDNS miss — treat as down rather than erroring out
    };
    addrs
        .into_iter()
        .any(|addr| TcpStream::connect_timeout(&addr, timeout).is_ok())
}

/// Polls [`tcp_up`] every `interval` until it answers or `deadline` elapses.
///
/// Returns how long the wait took, or `None` on timeout. Waking a PC from S3
/// takes a few seconds; from S4/S5 it can take the better part of a minute, so
/// give this a generous deadline.
pub fn wait_up(
    host: &str,
    port: u16,
    probe_timeout: Duration,
    interval: Duration,
    deadline: Duration,
) -> Option<Duration> {
    let started = Instant::now();
    loop {
        if tcp_up(host, port, probe_timeout) {
            return Some(started.elapsed());
        }
        if started.elapsed() + interval >= deadline {
            return None;
        }
        sleep(interval);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::TcpListener;

    #[test]
    fn detects_a_listening_port() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        assert!(tcp_up("127.0.0.1", port, Duration::from_secs(1)));
    }

    #[test]
    fn closed_port_and_bad_host_are_down() {
        // Bind then drop: nothing is listening on that port any more.
        let port = {
            let l = TcpListener::bind("127.0.0.1:0").unwrap();
            l.local_addr().unwrap().port()
        };
        assert!(!tcp_up("127.0.0.1", port, Duration::from_millis(200)));
        assert!(!tcp_up(
            "host.invalid.example",
            22,
            Duration::from_millis(200)
        ));
    }

    #[test]
    fn wait_up_returns_immediately_when_already_up() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        let took = wait_up(
            "127.0.0.1",
            port,
            Duration::from_secs(1),
            Duration::from_millis(50),
            Duration::from_secs(2),
        );
        assert!(took.is_some());
    }

    #[test]
    fn wait_up_gives_up_at_the_deadline() {
        let port = {
            let l = TcpListener::bind("127.0.0.1:0").unwrap();
            l.local_addr().unwrap().port()
        };
        let started = Instant::now();
        let took = wait_up(
            "127.0.0.1",
            port,
            Duration::from_millis(50),
            Duration::from_millis(50),
            Duration::from_millis(400),
        );
        assert!(took.is_none());
        assert!(started.elapsed() < Duration::from_secs(3));
    }
}
