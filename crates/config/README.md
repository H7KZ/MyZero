# config (`appconfig`)

Minimal runtime `.env` loader shared by `clapper`, `departure-board` and `pcctl`. No external crates — this is the
whole thing.

## Why

The three apps used to bake their `.env` into the binary at compile time (`build.rs` + `env!()`). Every config
change needed a rebuild, and the Pi never saw the plaintext file. This crate reads config at **startup** instead,
so editing a value only needs a restart.

## Lookup order

1. Process environment variables always win.
2. Otherwise, an `.env`-style file, located by:
   1. `--config <path>` among the process args
   2. the `ENV_FILE` environment variable
   3. `.env` next to the running binary
   4. `.env` in the current working directory

A missing file is not an error by itself — required keys are validated by the caller via `Env::require` /
`Env::require_parse`.

## API

```rust
let env = appconfig::Env::load(std::env::args());
let mac: String = env.require("PC_MAC")?;
let port: u16 = env.require_parse("PC_PROBE_PORT")?;
let timeout: u32 = env.parse_or("WAKE_TIMEOUT_SECS", 120)?;
let pin = env.optional_pin("POWER_SW_GPIO_PIN")?;   // "0" or missing → None
let oled = env.bool_flag("ENABLE_OLED");            // "true"/"1"/"yes" → true
```

Each app's own `.env.example` is the canonical reference for its keys — see
[`apps/clapper`](../../apps/clapper/README.md#env-reference),
[`apps/departure-board`](../../apps/departure-board/README.md#configuration), and
[`apps/pcctl`](../../apps/pcctl/README.md#env-reference).

## Consumers

`apps/clapper`, `apps/departure-board`, `apps/pcctl` — each calls `Env::load` once at startup in `main.rs` and
builds its own typed config struct from it (see each app's `src/config.rs`).
