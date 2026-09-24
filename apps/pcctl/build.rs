// Bakes apps/pcctl/.env into the binary at compile time.
// .env is gitignored (holds the real MAC, host and API token); .env.example is
// the template and doubles as the fallback so a fresh clone still builds.
fn main() {
    println!("cargo:rerun-if-changed=.env");
    println!("cargo:rerun-if-changed=.env.example");

    let (source, content) = match std::fs::read_to_string(".env") {
        Ok(c) => (".env", c),
        Err(_) => {
            println!(
                "cargo:warning=apps/pcctl/.env not found — building with the \
                 placeholder values from .env.example. Copy it to .env and fill \
                 in your MAC/host before deploying."
            );
            (
                ".env.example",
                std::fs::read_to_string(".env.example").unwrap_or_default(),
            )
        }
    };

    for line in content.lines() {
        let line = line.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        // split_once takes the *first* '=', so values may contain '=' freely
        // (ssh command lines do).
        if let Some((key, value)) = line.split_once('=') {
            println!("cargo:rustc-env={}={}", key.trim(), value.trim());
        }
    }
    println!("cargo:rustc-env=PCCTL_CONFIG_SOURCE={source}");
}
