//! The verbs: status, wake, sleep, shutdown, and the hardware fallbacks.
//!
//! Waking is a layer-2 broadcast the Pi emits itself. Powering *down* is the
//! opposite problem — a sleeping NIC can't be talked to, but a running PC can,
//! so it's a command executed on the PC over SSH. When neither works there's
//! the front-panel switch. All of them are rendered through the same
//! [`Outcome`] so the CLI and the HTTP API agree.
//!
//! Every verb that changes power state passes through one process-wide [`Gate`]:
//! two clients pressing "sleep" and "wake" at the same moment would otherwise
//! race, and a wake that overlaps a shutdown leaves the PC in a state neither
//! caller asked for.

use crate::config;
use crate::hardware::{self, Actuation};
use net::{probe, wol};
use std::io::Read;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
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
    /// Whether the front-panel power LED is lit, if one is wired.
    pub led: Option<bool>,
}

impl Outcome {
    fn ok(message: impl Into<String>) -> Self {
        Self {
            ok: true,
            message: message.into(),
            up: None,
            led: None,
        }
    }

    fn err(message: impl Into<String>) -> Self {
        Self {
            ok: false,
            message: message.into(),
            up: None,
            led: None,
        }
    }

    fn from_result(result: Result<String, String>) -> Self {
        match result {
            Ok(message) => Self::ok(message),
            Err(message) => Self::err(message),
        }
    }

    fn with_up(mut self, up: bool) -> Self {
        self.up = Some(up);
        self
    }
}

// ── Serialising power operations ──────────────────────────────────────────

static POWER_BUSY: AtomicBool = AtomicBool::new(false);
/// Process-wide record of the last front-panel actuation. The driver's own
/// cooldown can't see across actuations, because each one builds a fresh
/// `PowerSwitch` so the pin is only an output while it's actually pressed.
static LAST_ACTUATION: Mutex<Option<Instant>> = Mutex::new(None);

/// Held for the duration of one power operation. Released on drop, so an
/// early return or a panic can't wedge the gate shut.
struct Gate;

impl Gate {
    fn acquire() -> Option<Self> {
        POWER_BUSY
            .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
            .ok()
            .map(|_| Gate)
    }
}

impl Drop for Gate {
    fn drop(&mut self) {
        POWER_BUSY.store(false, Ordering::Release);
    }
}

/// Runs `f` unless another power operation is already in flight.
fn gated(verb: &str, f: impl FnOnce() -> Outcome) -> Outcome {
    match Gate::acquire() {
        Some(_gate) => f(),
        None => Outcome::err(format!(
            "{verb}: another power operation is already running — try again in a moment"
        )),
    }
}

// ── Status ────────────────────────────────────────────────────────────────

/// Does the PC answer on its probe port?
pub fn is_up() -> bool {
    probe::tcp_up(config::PC_HOST, config::PC_PROBE_PORT, PROBE_TIMEOUT)
}

/// Current state, as a one-liner plus the raw flags.
///
/// Not gated: reading state should always work, including while a wake is
/// still waiting for the PC to come up.
pub fn status() -> Outcome {
    let up = is_up();
    let led = hardware::power_led();
    let where_ = format!("{}:{}", config::PC_HOST, config::PC_PROBE_PORT);

    let mut message = if up {
        format!("up — {where_} answering")
    } else {
        format!("down — no answer on {where_}")
    };
    // The LED and the probe disagreeing is informative, not contradictory: it's
    // how "powered but still in POST" and "hung after boot" look from here.
    match led {
        Some(true) if !up => message.push_str(", but the power LED is lit (booting, or hung)"),
        Some(false) if up => {
            message.push_str(", though the power LED reads dark (check the wiring)")
        }
        Some(true) => message.push_str(", power LED lit"),
        Some(false) => message.push_str(", power LED dark"),
        None => {}
    }

    let mut outcome = Outcome::ok(message).with_up(up);
    outcome.led = led;
    outcome
}

// ── Wake ──────────────────────────────────────────────────────────────────

/// Sends the magic packet. With `wait`, polls until the PC answers or
/// `WAKE_TIMEOUT_SECS` elapses.
///
/// Sending is not conditional on the PC being down: a magic packet aimed at an
/// already-running machine is a no-op, so there's nothing to guard against.
pub fn wake(wait: bool) -> Outcome {
    gated("wake", || {
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
    })
}

// ── Power down over SSH ───────────────────────────────────────────────────

/// Runs `SLEEP_COMMAND` on the PC.
pub fn sleep() -> Outcome {
    gated("sleep", || power_down("sleep", config::SLEEP_COMMAND))
}

/// Runs `SHUTDOWN_COMMAND` on the PC.
pub fn shutdown() -> Outcome {
    gated("shutdown", || {
        power_down("shutdown", config::SHUTDOWN_COMMAND)
    })
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

// ── Front-panel switch ────────────────────────────────────────────────────

/// Presses a front-panel switch.
///
/// `confirmed` must be true for the destructive actuations — a long press cuts
/// power under the OS's feet, so it is never one stray click away.
pub fn actuate(what: Actuation, confirmed: bool) -> Outcome {
    gated(what.name(), || {
        if what.needs_confirmation() && !confirmed {
            return Outcome::err(format!(
                "{0}: refused — this cuts power without asking the OS and loses unsaved work. \
                 Repeat with --yes (CLI) or confirm={0} (API) if that is what you want.",
                what.name()
            ));
        }

        // Enforced here rather than in the driver: each actuation builds a
        // fresh PowerSwitch, so only the process remembers the previous one.
        let cooldown = Duration::from_secs(config::PRESS_COOLDOWN_SECS);
        let mut last = match LAST_ACTUATION.lock() {
            Ok(guard) => guard,
            // A panic inside a previous actuation poisoned the lock. The
            // timestamp is still sound, and refusing every future press
            // because of one panic is worse than carrying on.
            Err(poisoned) => poisoned.into_inner(),
        };
        if let Some(previous) = *last {
            let since = previous.elapsed();
            if since < cooldown {
                return Outcome::err(format!(
                    "{}: cooling down, {} s left",
                    what.name(),
                    (cooldown - since).as_secs().max(1)
                ));
            }
        }

        let result = hardware::actuate(what);
        if result.is_ok() {
            *last = Some(Instant::now());
        }
        Outcome::from_result(result)
    })
}

/// Releases any switch left asserted by a previous crash. Called at startup.
pub fn release_switches() {
    hardware::release_all();
}

/// Is a front-panel switch wired up in this build?
pub fn hardware_available() -> bool {
    hardware::available()
}

// ── Running a shell command with a timeout ────────────────────────────────

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

#[cfg(test)]
mod tests {
    use super::*;

    /// The gate is process-wide, so these tests must not run concurrently with
    /// each other — cargo runs tests on parallel threads by default.
    static SERIAL: Mutex<()> = Mutex::new(());

    #[test]
    fn the_gate_admits_one_operation_at_a_time() {
        let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let first = Gate::acquire();
        assert!(first.is_some());
        assert!(Gate::acquire().is_none());
        drop(first);
        assert!(Gate::acquire().is_some(), "gate must reopen on drop");
    }

    #[test]
    fn destructive_actuations_demand_confirmation() {
        assert!(!Actuation::Press.needs_confirmation());
        assert!(Actuation::ForceOff.needs_confirmation());
        assert!(Actuation::Reset.needs_confirmation());
    }

    #[test]
    fn unconfirmed_force_off_never_reaches_the_gpio() {
        let _serial = SERIAL.lock().unwrap_or_else(|e| e.into_inner());
        let outcome = actuate(Actuation::ForceOff, false);
        assert!(!outcome.ok);
        assert!(outcome.message.contains("confirm=force-off"));
    }
}
