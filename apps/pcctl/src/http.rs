//! A small HTTP/1.1 control API — pure std, one thread per connection.
//!
//! Deliberately not a framework: the whole surface is eight routes and a bearer
//! token, and keeping it dependency-free means `pcctl` cross-compiles to the
//! Zero 2 with nothing but a linker.
//!
//! `GET /wake` exists (rather than POST-only) because Moonlight's HTTP-wake
//! feature issues a plain GET to a user-supplied URL — point it here and the
//! "start streaming" button wakes the PC on its own. Everything that could
//! *cost* you something is POST, and the two destructive ones additionally
//! demand `confirm=`.
//!
//! There are no cookies anywhere, which is what makes the missing CSRF defence
//! a non-issue: the token has to be presented explicitly on every request, so a
//! hostile page in another tab has no ambient authority to borrow.

use crate::hardware::Actuation;
use crate::{config, control};
use std::io::{BufRead, BufReader, Read, Write};
use std::net::{TcpListener, TcpStream};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::thread;
use std::time::Duration;

/// Cap on the request head — nobody legitimately sends more at these routes.
const MAX_HEAD: usize = 8 * 1024;
const IO_TIMEOUT: Duration = Duration::from_secs(20);
/// Ceiling on connection threads. The Zero 2 has 512 MB and each thread costs
/// a stack; without this, a client that opens sockets and never speaks would
/// walk the Pi into swap. Well above any real usage of a personal power switch.
const MAX_CONNECTIONS: usize = 16;

static LIVE_CONNECTIONS: AtomicUsize = AtomicUsize::new(0);

/// Decrements the live-connection count however the thread leaves.
struct ConnectionSlot;

impl Drop for ConnectionSlot {
    fn drop(&mut self) {
        LIVE_CONNECTIONS.fetch_sub(1, Ordering::Release);
    }
}

/// Binds `LISTEN_ADDR` and serves until killed.
pub fn serve() -> std::io::Result<()> {
    let addr = config::LISTEN_ADDR;
    let token = config::API_TOKEN.trim();

    // An unauthenticated wake/shutdown endpoint reachable off-box is a remote
    // power switch for anyone who can route to it. Loopback is the only place
    // it's defensible.
    if token.is_empty() && !is_loopback(addr) {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("refusing to serve on {addr} without an API_TOKEN — set one in .env (openssl rand -hex 32)"),
        ));
    }

    // Before accepting anything: let go of any front-panel switch a previous
    // crash left pressed.
    control::release_switches();

    let listener = TcpListener::bind(addr)?;
    println!("[pcctl] listening on http://{addr}");
    println!(
        "[pcctl] auth: {}",
        if token.is_empty() {
            "none (loopback only)"
        } else {
            "bearer token required"
        }
    );
    println!(
        "[pcctl] front-panel switch: {}",
        if control::hardware_available() {
            "wired"
        } else {
            "not configured"
        }
    );

    for stream in listener.incoming() {
        let stream = match stream {
            Ok(stream) => stream,
            Err(e) => {
                eprintln!("[pcctl] accept failed: {e}");
                continue;
            }
        };

        if LIVE_CONNECTIONS.fetch_add(1, Ordering::AcqRel) >= MAX_CONNECTIONS {
            LIVE_CONNECTIONS.fetch_sub(1, Ordering::Release);
            // Answered inline rather than from a thread — that's the whole
            // point of the cap.
            let _ = refuse(stream);
            continue;
        }

        thread::spawn(move || {
            let _slot = ConnectionSlot;
            if let Err(e) = handle(stream) {
                eprintln!("[pcctl] connection error: {e}");
            }
        });
    }
    Ok(())
}

fn refuse(mut stream: TcpStream) -> std::io::Result<()> {
    let _ = stream.set_write_timeout(Some(Duration::from_secs(2)));
    write_response(
        &mut stream,
        Response::json(
            503,
            r#"{"ok":false,"error":"too many connections"}"#.into(),
            &[("Retry-After", "1")],
        ),
    )
}

fn handle(stream: TcpStream) -> std::io::Result<()> {
    stream.set_read_timeout(Some(IO_TIMEOUT))?;
    stream.set_write_timeout(Some(IO_TIMEOUT))?;

    let peer = stream
        .peer_addr()
        .map(|a| a.to_string())
        .unwrap_or_else(|_| "?".into());
    let mut reader = BufReader::new(stream.try_clone()?);

    let Some(request) = read_head(&mut reader)? else {
        return Ok(()); // empty or oversized request — drop it
    };
    let (path, query) = split_once_or(&request.target, '?');

    let response = if !authorized(&request, query) {
        println!("[pcctl] {peer} {} {path} → 401", request.method);
        Response::json(
            401,
            r#"{"ok":false,"error":"unauthorized"}"#.into(),
            &[("WWW-Authenticate", "Bearer")],
        )
    } else {
        let response = route(&request.method, path, query);
        println!(
            "[pcctl] {peer} {} {path} → {}",
            request.method, response.status
        );
        response
    };

    write_response(&mut stream.try_clone()?, response)
}

fn route(method: &str, path: &str, query: &str) -> Response {
    match (method, path) {
        ("GET", "/") => Response::html(200, index_page(param(query, "token"))),
        ("GET", "/status") => outcome_json(control::status()),
        ("GET" | "POST", "/wake") => {
            let wait = matches!(param(query, "wait").as_deref(), Some("1" | "true" | "yes"));
            outcome_json(control::wake(wait))
        }
        ("POST", "/sleep") => outcome_json(control::sleep()),
        ("POST", "/shutdown") => outcome_json(control::shutdown()),
        ("POST", "/press") => actuation_json(Actuation::Press, query),
        ("POST", "/force-off") => actuation_json(Actuation::ForceOff, query),
        ("POST", "/reset") => actuation_json(Actuation::Reset, query),
        // A GET that changes power state is one browser prefetch away from an
        // accidental shutdown, so only /wake (idempotent) gets that treatment.
        ("GET", "/sleep" | "/shutdown" | "/press" | "/force-off" | "/reset") => Response::json(
            405,
            r#"{"ok":false,"error":"use POST"}"#.into(),
            &[("Allow", "POST")],
        ),
        _ => Response::json(404, r#"{"ok":false,"error":"not found"}"#.into(), &[]),
    }
}

fn actuation_json(what: Actuation, query: &str) -> Response {
    let confirmed = param(query, "confirm").as_deref() == Some(what.name());
    outcome_json(control::actuate(what, confirmed))
}

fn outcome_json(outcome: control::Outcome) -> Response {
    let body = format!(
        r#"{{"ok":{},"message":"{}","up":{},"led":{},"hardware":{},"host":"{}","mac":"{}"}}"#,
        outcome.ok,
        escape(&outcome.message),
        tristate(outcome.up),
        tristate(outcome.led),
        control::hardware_available(),
        escape(config::PC_HOST),
        escape(config::PC_MAC),
    );
    Response::json(if outcome.ok { 200 } else { 502 }, body, &[])
}

/// `null` rather than `false` for "unknown" — the difference between "the LED
/// is dark" and "no LED is wired" matters to whoever reads this.
fn tristate(value: Option<bool>) -> &'static str {
    match value {
        Some(true) => "true",
        Some(false) => "false",
        None => "null",
    }
}

// ── Request parsing ───────────────────────────────────────────────────────

struct Request {
    method: String,
    target: String,
    auth: Option<String>,
}

/// Reads the request line + headers, then discards any declared body.
fn read_head(reader: &mut BufReader<TcpStream>) -> std::io::Result<Option<Request>> {
    let mut head = String::new();
    let mut total = 0;
    loop {
        let mut line = String::new();
        let n = reader.read_line(&mut line)?;
        total += n;
        if n == 0 || total > MAX_HEAD {
            return Ok(None);
        }
        if line == "\r\n" || line == "\n" {
            break;
        }
        head.push_str(&line);
    }

    let mut lines = head.lines();
    let Some(request_line) = lines.next() else {
        return Ok(None);
    };
    let mut parts = request_line.split_whitespace();
    let (Some(method), Some(target)) = (parts.next(), parts.next()) else {
        return Ok(None);
    };

    let mut auth = None;
    let mut content_length = 0usize;
    for line in lines {
        let Some((name, value)) = line.split_once(':') else {
            continue;
        };
        let value = value.trim();
        match name.trim().to_ascii_lowercase().as_str() {
            "authorization" => auth = Some(value.to_string()),
            "content-length" => content_length = value.parse().unwrap_or(0),
            _ => {}
        }
    }

    // Drain the body so the client sees our response instead of a reset.
    if content_length > 0 {
        let mut sink = Vec::new();
        reader
            .take(content_length.min(MAX_HEAD) as u64)
            .read_to_end(&mut sink)?;
    }

    Ok(Some(Request {
        method: method.to_ascii_uppercase(),
        target: target.to_string(),
        auth,
    }))
}

/// Bearer header or `?token=`; the query form is what Moonlight's GET can carry.
fn authorized(request: &Request, query: &str) -> bool {
    let expected = config::API_TOKEN.trim();
    if expected.is_empty() {
        return true; // serve() already refused to bind anything but loopback
    }
    let presented = request
        .auth
        .as_deref()
        .and_then(|a| a.strip_prefix("Bearer "))
        .map(|t| t.trim().to_string())
        .or_else(|| param(query, "token"));
    presented.is_some_and(|t| constant_time_eq(t.as_bytes(), expected.as_bytes()))
}

/// Compares without an early exit, so a wrong token leaks no length/prefix hint.
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    a.iter().zip(b).fold(0u8, |acc, (x, y)| acc | (x ^ y)) == 0
}

/// Reads one query parameter, percent-decoded.
///
/// Decoding matters even though the recommended token is plain hex: a token
/// pasted from a password manager can contain `+` or `/`, and silently
/// comparing the un-decoded form would reject a correct token.
fn param(query: &str, key: &str) -> Option<String> {
    query.split('&').find_map(|pair| {
        let (k, v) = split_once_or(pair, '=');
        (k == key).then(|| percent_decode(v))
    })
}

fn percent_decode(s: &str) -> String {
    let bytes = s.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        match bytes[i] {
            b'+' => {
                out.push(b' ');
                i += 1;
            }
            b'%' if i + 2 < bytes.len() => {
                match u8::from_str_radix(&s[i + 1..i + 3], 16) {
                    Ok(byte) => {
                        out.push(byte);
                        i += 3;
                    }
                    // Not a real escape — pass the '%' through unchanged.
                    Err(_) => {
                        out.push(b'%');
                        i += 1;
                    }
                }
            }
            byte => {
                out.push(byte);
                i += 1;
            }
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

fn split_once_or(s: &str, sep: char) -> (&str, &str) {
    s.split_once(sep).unwrap_or((s, ""))
}

// ── Responses ─────────────────────────────────────────────────────────────

struct Response {
    status: u16,
    content_type: &'static str,
    headers: Vec<(String, String)>,
    body: String,
}

impl Response {
    fn json(status: u16, body: String, extra: &[(&str, &str)]) -> Self {
        Self {
            status,
            content_type: "application/json; charset=utf-8",
            headers: extra
                .iter()
                .map(|(k, v)| (k.to_string(), v.to_string()))
                .collect(),
            body,
        }
    }

    fn html(status: u16, body: String) -> Self {
        Self {
            status,
            content_type: "text/html; charset=utf-8",
            headers: vec![],
            body,
        }
    }
}

fn write_response(stream: &mut TcpStream, response: Response) -> std::io::Result<()> {
    let reason = match response.status {
        200 => "OK",
        401 => "Unauthorized",
        404 => "Not Found",
        405 => "Method Not Allowed",
        502 => "Bad Gateway",
        503 => "Service Unavailable",
        _ => "OK",
    };
    let mut head = format!(
        "HTTP/1.1 {} {reason}\r\nContent-Type: {}\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n",
        response.status,
        response.content_type,
        response.body.len()
    );
    for (name, value) in &response.headers {
        head.push_str(&format!("{name}: {value}\r\n"));
    }
    head.push_str("\r\n");

    stream.write_all(head.as_bytes())?;
    stream.write_all(response.body.as_bytes())?;
    stream.flush()
}

fn escape(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    for c in s.chars() {
        match c {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            c if (c as u32) < 0x20 => out.push_str(&format!("\\u{:04x}", c as u32)),
            c => out.push(c),
        }
    }
    out
}

/// Is this bind address reachable only from the Pi itself?
fn is_loopback(addr: &str) -> bool {
    let host = addr.rsplit_once(':').map_or(addr, |(h, _)| h);
    let host = host.trim_start_matches('[').trim_end_matches(']');
    host == "localhost" || host == "::1" || host.starts_with("127.")
}

/// The phone-sized control page. The token travels in the URL so a bookmark or
/// home-screen shortcut works with no login step.
fn index_page(token: Option<String>) -> String {
    let auth = token.map_or(String::new(), |t| {
        format!("headers.Authorization = 'Bearer ' + {};", js_string(&t))
    });
    // The destructive row only appears when a switch is actually wired, so the
    // page can't offer a button that could only ever return an error.
    let hardware = if control::hardware_available() {
        r#"<hr>
<button onclick="call('POST','/press')">Press power button</button>
<details><summary>Force off / reset</summary>
  <p class="warn">These cut power without asking Windows. Unsaved work is lost.</p>
  <button onclick="danger('/force-off','force-off')">Force off (hold power)</button>
  <button onclick="danger('/reset','reset')">Hard reset</button>
</details>"#
    } else {
        ""
    };

    format!(
        r##"<!doctype html>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>pcctl</title>
<style>
  :root {{ color-scheme: light dark; font-family: system-ui, sans-serif; }}
  body {{ max-width: 26rem; margin: 3rem auto; padding: 0 1rem; }}
  h1 {{ font-size: 1.2rem; letter-spacing: .02em; }}
  p.host {{ opacity: .65; font-size: .85rem; margin-top: -.6rem; }}
  p.warn {{ font-size: .8rem; opacity: .8; }}
  hr {{ border: 0; border-top: 1px solid #8883; margin: 1.4rem 0 .8rem; }}
  summary {{ cursor: pointer; font-size: .9rem; opacity: .8; padding: .4rem 0; }}
  button {{ display: block; width: 100%; padding: 1rem; margin: .5rem 0;
            font-size: 1rem; border-radius: .6rem; border: 1px solid #8884;
            background: #8881; color: inherit; cursor: pointer; }}
  button:active {{ background: #8883; }}
  details button {{ border-color: #d9534f88; }}
  #out {{ margin-top: 1.2rem; padding: .8rem; border-radius: .6rem;
          background: #8881; font: .85rem/1.45 ui-monospace, monospace;
          white-space: pre-wrap; min-height: 2.6rem; }}
</style>
<h1>pcctl</h1>
<p class="host">{host} · {mac}</p>
<button onclick="call('GET','/wake?wait=1')">Wake</button>
<button onclick="call('POST','/sleep')">Sleep</button>
<button onclick="call('POST','/shutdown')">Shut down</button>
<button onclick="call('GET','/status')">Status</button>
{hardware}
<div id="out">…</div>
<script>
const out = document.getElementById('out');
async function call(method, path) {{
  out.textContent = method + ' ' + path + ' …';
  const headers = {{}};
  {auth}
  try {{
    const r = await fetch(path, {{ method, headers }});
    const j = await r.json();
    out.textContent = (j.ok ? '✓ ' : '✗ ') + (j.message || j.error);
  }} catch (e) {{ out.textContent = '✗ ' + e; }}
}}
function danger(path, verb) {{
  if (!confirm('This cuts power without asking Windows. Unsaved work is lost.\n\nContinue?')) return;
  call('POST', path + '?confirm=' + verb);
}}
call('GET', '/status');
</script>
"##,
        host = escape(config::PC_HOST),
        mac = escape(config::PC_MAC),
    )
}

/// Quotes a value for embedding in the page's script.
fn js_string(s: &str) -> String {
    format!(
        "\"{}\"",
        escape(s).replace('<', "\\u003c").replace('/', "\\/")
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_query_params() {
        assert_eq!(param("wait=1&token=abc", "token").as_deref(), Some("abc"));
        assert_eq!(param("wait=1", "token"), None);
        assert_eq!(param("", "token"), None);
        assert_eq!(param("flag", "flag").as_deref(), Some(""));
    }

    #[test]
    fn decodes_percent_escapes_in_params() {
        assert_eq!(param("token=a%2Bb%2Fc", "token").as_deref(), Some("a+b/c"));
        assert_eq!(param("token=a+b", "token").as_deref(), Some("a b"));
        // A stray '%' is data, not a malformed escape to choke on.
        assert_eq!(param("token=100%", "token").as_deref(), Some("100%"));
        assert_eq!(param("token=%zz", "token").as_deref(), Some("%zz"));
    }

    #[test]
    fn constant_time_eq_still_compares_correctly() {
        assert!(constant_time_eq(b"secret", b"secret"));
        assert!(!constant_time_eq(b"secret", b"secreT"));
        assert!(!constant_time_eq(b"secret", b"secret2"));
        assert!(constant_time_eq(b"", b""));
    }

    #[test]
    fn escapes_json_hostile_characters() {
        assert_eq!(escape(r#"a"b\c"#), r#"a\"b\\c"#);
        assert_eq!(escape("line\nbreak"), "line\\nbreak");
        assert_eq!(escape("\u{1}"), "\\u0001");
    }

    #[test]
    fn loopback_detection_covers_the_usual_spellings() {
        assert!(is_loopback("127.0.0.1:8080"));
        assert!(is_loopback("localhost:8080"));
        assert!(is_loopback("[::1]:8080"));
        assert!(!is_loopback("0.0.0.0:8080"));
        assert!(!is_loopback("100.64.0.1:8080"));
    }

    #[test]
    fn destructive_routes_are_post_only() {
        for path in ["/sleep", "/shutdown", "/press", "/force-off", "/reset"] {
            assert_eq!(route("GET", path, "").status, 405, "GET {path}");
        }
    }
}
