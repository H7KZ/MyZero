# AGENTS.md

Personal Raspberry Pi Zero 2 WH playground: a Cargo workspace of embedded apps (departure board, clap-to-wake,
remote PC control) sharing one hardware layer, plus the OS provisioning that sets the Pi up.

## Layout

- `crates/devices` — GPIO/OLED drivers (Linux-only, `rppal`/`sh1106`).
- `crates/net` — Wake-on-LAN + TCP probe, pure std.
- `crates/config` (`appconfig`) — runtime `.env` loader shared by all three apps.
- `apps/departure-board`, `apps/clapper`, `apps/pcctl` — the binaries. Each has its own README with its `.env` key
  reference.
- `docs/remote-pc-setup.md` / `docs/remote-pc-usage.md` — the remote-PC-control system, human docs.
- `provision/` — Pi OS setup/hardening; `provision/pc/windows/` runs on the PC, not the Pi.

## Build / check / test

```sh
make build       # cross-compile the whole workspace for the Pi (needs `cross` + Docker/Podman)
make check        # cargo clippy + fmt --check
cargo test -p net -p appconfig # pure-std crates test anywhere
```

On a **Windows host**, `rppal` (hence `devices`, `departure-board`, `clapper`) won't build — only this works:

```sh
cargo check -p pcctl -p net -p appconfig --no-default-features
```

## Config model

Every app reads config **at runtime**, not compile time (`crates/config`). Lookup order: process env > `.env`
file, and the file is found via `--config <path>` → `ENV_FILE` env var → `.env` next to the binary → `.env` in the
CWD. systemd units set `ENV_FILE=/home/pi/<app>.env`; `install.sh` deploys `provision/bin/<app>.env` there. Never
edit an app's key list in more than one place — it lives in that app's `.env.example` / README, nowhere else.

## Invariants and gotchas

- `[profile.release]` is size-optimized (`opt-level = "z"`, `lto`, `strip`) for the Zero 2's flash/RAM — don't
  "fix" this for compile speed.
- `pcctl serve` refuses to bind a non-loopback address without `API_TOKEN` set. Don't remove that check.
- Only one `pcctl` power operation runs at a time, process-wide — preserve that when touching `control.rs`.
- GPIO safety: the front-panel switch pins (`POWER_SW_GPIO_PIN`, `RESET_SW_GPIO_PIN`) must be BCM 9–27, never
  0–8 (those boot with a pull-up and would hold the PC's power button down at Pi boot). This is enforced in
  `PowerSwitch::new` — don't bypass it.
- `crates/devices` and anything depending on `rppal`/`sh1106` is Linux-only; keep `pcctl`'s hardware verbs behind
  its `gpio` feature so the rest still builds off-Pi.

## Docs map

Root `README.md` is the human entry point. `docs/remote-pc-setup.md` is one-time setup end to end;
`docs/remote-pc-usage.md` is day-to-day use and troubleshooting. Each crate/app README documents only itself —
link, don't copy.

## Commit style

Conventional commits, scoped to the crate/app: `feat(pcctl): ...`, `fix(pc): ...`, `docs: ...`,
`refactor!: ...` for breaking changes. Check `git log` before writing one.
