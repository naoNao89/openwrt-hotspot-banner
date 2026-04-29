# Makefile for building openwrt-hotspot-banner for OpenWrt ARM routers
# Target: armv7-unknown-linux-musleabihf (matches arm_cortex-a7_neon-vfpv4)

TARGET := armv7-unknown-linux-musleabihf
BINARY := openwrt-hotspot-banner
ROUTER_USER ?= root
ROUTER_IP ?=
REMOTE_HOST := $(ROUTER_USER)@$(ROUTER_IP)
REMOTE_PATH := /usr/bin/hotspot-fas
BUILD_DIR := target/$(TARGET)/release

.PHONY: all build clean install-target deploy deploy-package-test ipk run ci ci-docker

all: build

install-target:
	rustup target add $(TARGET)

build: install-target
	cargo build --target $(TARGET) --release
	@echo "Binary size:"
	@ls -lh $(BUILD_DIR)/$(BINARY)

ci:
	cargo fmt --check
	cargo clippy --all-targets -- -D warnings
	cargo test --locked
	./scripts/check-shell.sh

ci-docker:
	docker build -f Dockerfile.ci -t openwrt-hotspot-banner-ci .

clean:
	cargo clean

deploy: build
	./deploy.sh

deploy-package-test: build
	./scripts/deploy-package-test.sh

ipk: build
	SKIP_BUILD=1 ./scripts/build-ipk.sh

run:
	cargo run
