//! The four verbs: status, wake, sleep, shutdown.
//!
//! Waking is a layer-2 broadcast the Pi emits itself. Powering *down* is the
//! opposite problem — a sleeping NIC can't be talked to, but a running PC can,
//! so it's just a command executed on the PC over SSH. Both directions are
//! rendered through the same [`Outcome`] so the CLI and the HTTP API agree.

use crate::config;
use net::{probe, wol};
use std::io::Read;
use std::process::{Command, Stdio};
use std::thread;
use std::time::{Duration, Instant};

/// How long a single TCP knock may take before it counts as "down".
const PROBE_TIMEOUT: Duration = Duration::from_millis(700);
/// Gap between knocks while waiting for a booting PC.
const PROBE_INTERVAL: Duration = Duration::from_secs(2);

/// Result of a verb, shaped so both the CLI and the JSON API can render it.
pub struct Outcome {
    pub ok: bool,
    pub message: String,
    /// Whether the PC answered on `PC_PROBE_PORT` after the verb ran.
    pub up: Option<bool>,
}

impl Outcome {
    fn ok(message: impl Into<String>) -> Self {
        Self {
            ok: true,
            message: message.into(),
            up: None,
        }
    }

    fn err(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
            up: None,
        }
    }

    fn with_up(mut self, up: bool) -> Self {
        self.up = Some(up);
        self
    }
}

/// Does the PC answer on its probe port?
pub fn is_up() -> bool {
    probe::tcp_up(config::PC_HOST, config::PC_PROBE_PORT, PROBE_TIMEOUT)
}

/// Current state, as a one-liner plus the raw flag.
pub fn status() -> Outcome {
    let up = is_up();
    let where_ = format!("{}:{}", config::PC_HOST, config::PC_PROBE_PORT);
    Outcome::ok(if up {
        format!("up — {where_} answering")
    } else {
        format!("down — no answer on {where_}")
    })
    .with_up(up)
}

/// Sends the magic packet. With `wait`, polls until the PC answers or
/// `WAKE_TIMEOUT_SECS` elapses.
///
/// Sending is not idempotent-checked on purpose: a magic packet aimed at an
/// already-running PC is a no-op, so there's no need to probe first.
pub fn wake(wait: bool) -> Outcome {
    let broadcasts = config::wol_broadcasts();
    let ports = config::wol_ports();

    let sent = match wol::Wake::new(config::PC_MAC)
        .broadcasts(&broadcasts)
        .ports(&ports)
        .repeat(config::WOL_REPEAT)
        .bind(config::wol_bind())
        .send()
    {
        Ok(n) => n,
        Err(e) => return Outcome::err(format!("wake failed: {e}")),
    };

    let sprayed = format!(
        "{sent} magic packets for {} → {}",
        config::PC_MAC,
        broadcasts.join(", ")
    );

    if !wait {
        return Outcome::ok(format!("sent {sprayed}"));
    }

    let deadline = Duration::from_secs(config::WAKE_TIMEOUT_SECS);
    match probe::wait_up(
        config::PC_HOST,
        config::PC_PROBE_PORT,
        PROBE_TIMEOUT,
        PROBE_INTERVAL,
        deadline,
    ) {
        Some(took) => {
            Outcome::ok(format!("sent {sprayed}; up after {}s", took.as_secs())).with_up(true)
        }
        None => Outcome::err(format!(
            "sent {sprayed}, but {}:{} stayed silent for {}s",
            config::PC_HOST,
            config::PC_PROBE_PORT,
            deadline.as_secs()
        ))
        .with_up(false),
    }
}

/// Runs `SLEEP_COMMAND` on the PC.
pub fn sleep() -> Outcome {
    power_down("sleep", config::SLEEP_COMMAND)
}

/// Runs `SHUTDOWN_COMMAND` on the PC.
pub fn shutdown() -> Outcome {
    power_down("shutdown", config::SHUTDOWN_COMMAND)
}

fn power_down(verb: &str, command: &str) -> Outcome {
    if command.trim().is_empty() {
        return Outcome::err(format!(
            "{verb} is not configured ({}_COMMAND is empty in .env)",
            verb.to_uppercase()
        ));
    }
    if !is_up() {
        // Not an error: the PC is already off, which is what was asked for.
        return Outcome::ok(format!("{verb}: PC already down")).with_up(false);
    }
    match run(command, Duration::from_secs(config::COMMAND_TIMEOUT_SECS)) {
        Ok(out) if out.status_ok => Outcome::ok(format!("{verb} sent{}", tail(&out.text))),
        Ok(out) => Outcome::err(format!("{verb} command failed{}", tail(&out.text))),
        Err(e) => Outcome::err(format!("{verb} command could not run: {e}")),
    }
}

struct Output {
    status_ok: bool,
    text: String,
}

/// Runs a shell command line, killing it if it outruns `timeout`.
///
/// stdout/stderr are drained by reader threads rather than after the wait, so a
/// chatty command can't deadlock on a full pipe buffer.
fn run(command: &str, timeout: Duration) -> std::io::Result<Output> {
    let mut child = Command::new("sh")
        .arg("-c")
        .arg(command)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;

    let mut out = child.stdout.take().expect("piped");
    let mut err = child.stderr.take().expect("piped");
    let readers = (
        thread::spawn(move || drain(&mut out)),
        thread::spawn(move || drain(&mut err)),
    );

    let started = Instant::now();
    let status = loop {
        match child.try_wait()? {
            Some(status) => break Some(status),
            None if started.elapsed() >= timeout => {
                let _ = child.kill();
                let _ = child.wait();
                break None;
            }
            None => thread::sleep(Duration::from_millis(50)),
        }
    };

    let mut text = readers.0.join().unwrap_or_default();
    text.push_str(&readers.1.join().unwrap_or_default());

    match status {
        Some(status) => Ok(Output {
            status_ok: status.success(),
            text,
        }),
        None => Ok(Output {
            status_ok: false,
            text: format!("timed out after {}s\n{text}", timeout.as_secs()),
        }),
    }
}

fn drain(pipe: &mut impl Read) -> String {
    let mut buf = String::new();
    let _ = pipe.read_to_string(&mut buf);
    buf
}

/// Command output as a short suffix, so a one-line status stays one line.
fn tail(text: &str) -> String {
    let text = text.trim();
    if text.is_empty() {
        String::new()
    } else {
        format!(": {}", text.replace('\n', " · "))
    }
}
