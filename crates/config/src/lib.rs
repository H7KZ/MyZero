//! Minimal runtime configuration loader shared by clapper, departure-board and
//! pcctl.
//!
//! All three apps used to bake their `.env` into the binary at compile time
//! (`build.rs` + `env!()`). That meant every config change needed a rebuild,
//! and the Pi never saw the plaintext file. This crate reads config at
//! startup instead: process environment variables, optionally filled in from
//! an `.env`-style file. No external crates — this is the whole loader.

use std::collections::HashMap;
use std::env;
use std::fmt;
use std::path::{Path, PathBuf};

/// Env vars, with the process environment taking precedence over an optional
/// `.env` file. Built once at startup via [`Env::load`].
pub struct Env {
    file: HashMap<String, String>,
    /// Path the `.env` file was actually loaded from, if any — useful for a
    /// `config`/status printout.
    pub source: Option<PathBuf>,
}

/// A required key was missing, or a value couldn't be parsed.
#[derive(Debug)]
pub struct ConfigError(pub String);

impl fmt::Display for ConfigError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{}", self.0)
    }
}

impl std::error::Error for ConfigError {}

impl Env {
    /// Locates and loads the `.env` file, then wraps the process environment.
    ///
    /// Lookup order for the file path:
    ///   1. `--config <path>` among `args` (pass `std::env::args()`)
    ///   2. the `ENV_FILE` environment variable
    ///   3. `.env` next to the running binary
    ///   4. `.env` in the current working directory
    ///
    /// A missing file is not an error by itself — required keys are validated
    /// by the caller via [`Env::require`] / [`Env::require_parse`].
    pub fn load(args: impl IntoIterator<Item = String>) -> Self {
        let source = Self::resolve_path(args);
        let file = source
            .as_deref()
            .and_then(|p| std::fs::read_to_string(p).ok())
            .map(|content| Self::parse(&content))
            .unwrap_or_default();
        Self { file, source }
    }

    fn resolve_path(args: impl IntoIterator<Item = String>) -> Option<PathBuf> {
        let args: Vec<String> = args.into_iter().collect();
        if let Some(idx) = args.iter().position(|a| a == "--config") {
            if let Some(p) = args.get(idx + 1) {
                return Some(PathBuf::from(p));
            }
        }
        if let Ok(p) = env::var("ENV_FILE") {
            if !p.trim().is_empty() {
                return Some(PathBuf::from(p));
            }
        }
        if let Ok(exe) = env::current_exe() {
            if let Some(dir) = exe.parent() {
                let candidate = dir.join(".env");
                if candidate.is_file() {
                    return Some(candidate);
                }
            }
        }
        let cwd_candidate = Path::new(".env");
        if cwd_candidate.is_file() {
            return Some(cwd_candidate.to_path_buf());
        }
        None
    }

    fn parse(content: &str) -> HashMap<String, String> {
        let mut map = HashMap::new();
        for line in content.lines() {
            let line = line.trim();
            if line.is_empty() || line.starts_with('#') {
                continue;
            }
            // split_once takes the *first* '=', so values may contain '='
            // freely (ssh command lines do).
            if let Some((key, value)) = line.split_once('=') {
                map.insert(key.trim().to_string(), value.trim().to_string());
            }
        }
        map
    }

    /// Process env wins over the file — `FOO=x ./pcctl serve` should beat
    /// whatever `.env` says.
    pub fn get(&self, key: &str) -> Option<String> {
        env::var(key)
            .ok()
            .filter(|v| !v.is_empty())
            .or_else(|| self.file.get(key).cloned())
    }

    /// Fetches `key`, erroring with a clear message if it is missing or empty.
    pub fn require(&self, key: &str) -> Result<String, ConfigError> {
        self.get(key)
            .filter(|v| !v.is_empty())
            .ok_or_else(|| ConfigError(format!("missing required config key: {key}")))
    }

    /// Fetches and parses a required key.
    pub fn require_parse<T>(&self, key: &str) -> Result<T, ConfigError>
    where
        T: std::str::FromStr,
    {
        let raw = self.require(key)?;
        raw.parse()
            .map_err(|_| ConfigError(format!("invalid value for {key}: {raw:?}")))
    }

    /// Parses `key`, or returns `default` if it is missing/empty.
    pub fn parse_or<T>(&self, key: &str, default: T) -> Result<T, ConfigError>
    where
        T: std::str::FromStr,
    {
        match self.get(key) {
            Some(raw) if !raw.trim().is_empty() => raw
                .parse()
                .map_err(|_| ConfigError(format!("invalid value for {key}: {raw:?}"))),
            _ => Ok(default),
        }
    }

    /// `0` (or missing/empty) means "disabled" across all three apps' pin
    /// config, so it maps to `None`.
    pub fn optional_pin(&self, key: &str) -> Result<Option<u8>, ConfigError> {
        let v: u16 = self.parse_or(key, 0)?;
        Ok((v != 0).then_some(v as u8))
    }

    /// `true` / `1` / `yes` (case-sensitive, matching the existing `.env`
    /// files) — anything else, including unset, is `false`.
    pub fn bool_flag(&self, key: &str) -> bool {
        matches!(self.get(key).as_deref(), Some("true" | "1" | "yes"))
    }

    /// A string value, falling back to `default` when missing/empty. For
    /// values that are legitimately optional (e.g. an empty command disables
    /// a verb), use [`Env::get`] directly instead.
    pub fn get_or(&self, key: &str, default: &str) -> String {
        self.get(key).unwrap_or_else(|| default.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parses_env_style_lines() {
        let map = Env::parse("FOO=bar\n# comment\n\nBAZ=a=b=c\n  QUX = spaced  \n");
        assert_eq!(map.get("FOO").map(String::as_str), Some("bar"));
        assert_eq!(map.get("BAZ").map(String::as_str), Some("a=b=c"));
        assert_eq!(map.get("QUX").map(String::as_str), Some("spaced"));
        assert_eq!(map.len(), 3);
    }

    #[test]
    fn optional_pin_treats_zero_as_disabled() {
        let env = Env {
            file: HashMap::from([("PIN".to_string(), "0".to_string())]),
            source: None,
        };
        assert_eq!(env.optional_pin("PIN").unwrap(), None);
        assert_eq!(env.optional_pin("MISSING").unwrap(), None);

        let env = Env {
            file: HashMap::from([("PIN".to_string(), "17".to_string())]),
            source: None,
        };
        assert_eq!(env.optional_pin("PIN").unwrap(), Some(17));
    }

    #[test]
    fn bool_flag_matches_known_truthy_spellings() {
        let env = Env {
            file: HashMap::from([
                ("A".to_string(), "true".to_string()),
                ("B".to_string(), "1".to_string()),
                ("C".to_string(), "yes".to_string()),
                ("D".to_string(), "nope".to_string()),
            ]),
            source: None,
        };
        assert!(env.bool_flag("A"));
        assert!(env.bool_flag("B"));
        assert!(env.bool_flag("C"));
        assert!(!env.bool_flag("D"));
        assert!(!env.bool_flag("MISSING"));
    }
}
