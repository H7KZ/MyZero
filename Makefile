PI_HOST = pi@raspberrypi.local
TARGET  = aarch64-unknown-linux-gnu
# Which app to deploy/run. Override: make run BIN=voice-assistant
BIN    ?= departure-board

.PHONY: build deploy ship check run

# Builds the whole workspace (all apps) for the Pi.
build:
	cross build --target $(TARGET) --release

deploy:
	scp target/$(TARGET)/release/$(BIN) $(PI_HOST):~/

ship: build deploy

check:
	cargo clippy
	cargo fmt --check

run:
	ssh $(PI_HOST) "./$(BIN)"
