PI_HOST = zero@raspberrypi.local
TARGET  = aarch64-unknown-linux-gnu
# Which app to build/deploy/run. Override: make deploy BIN=clapper
BIN    ?= departure-board

.PHONY: build build-all deploy ship check logs status env new-env run bootstrap

# Provisions a fresh Pi from Windows: SSH key setup, copy provision/, run
# install.sh, offer reboot. Extra args: e.g. `make bootstrap ARGS="-DryRun"`.
bootstrap:
	powershell -ExecutionPolicy Bypass -File provision/bootstrap.ps1 $(ARGS)

# Cross-compiles just $(BIN) for the Pi.
build:
	cross build -p $(BIN) --target $(TARGET) --release

# Cross-compiles the whole workspace for the Pi.
build-all:
	cross build --target $(TARGET) --release

# Ships the built binary and restarts its systemd service on the Pi.
# Requires the unit to already be installed (see provision/systemd/*.service).
deploy:
	scp target/$(TARGET)/release/$(BIN) $(PI_HOST):~/
	ssh $(PI_HOST) "sudo systemctl restart $(BIN)"

ship: build deploy

check:
	cargo clippy
	cargo fmt --check

# Tails the systemd journal for $(BIN) on the Pi.
logs:
	ssh $(PI_HOST) "journalctl -u $(BIN) -f -n 100"

# Shows systemd status for $(BIN) on the Pi.
status:
	ssh $(PI_HOST) "systemctl status $(BIN) --no-pager"

# Copies apps/$(BIN)/.env (gitignored, must already exist locally) to the Pi
# as ~/$(BIN).env, matching ENV_FILE in provision/systemd/$(BIN).service.
env:
	scp apps/$(BIN)/.env $(PI_HOST):~/$(BIN).env

# Creates a local apps/$(BIN)/.env from its .env.example, if one doesn't
# already exist. Edit it, then `make env BIN=$(BIN)` to ship it.
new-env:
	@if [ -f apps/$(BIN)/.env ]; then \
		echo "apps/$(BIN)/.env already exists — not overwriting"; \
	else \
		cp apps/$(BIN)/.env.example apps/$(BIN)/.env; \
		echo "created apps/$(BIN)/.env — edit it, then: make env BIN=$(BIN)"; \
	fi

run:
	ssh $(PI_HOST) "./$(BIN)"
