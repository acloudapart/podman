# ~/podman/Makefile
SHELL := /bin/bash
.ONESHELL:
.SHELLFLAGS := -eu -o pipefail -c
MAKEFLAGS += --no-builtin-rules
.DEFAULT_GOAL := deploy
BUILD_CACHE ?= /mnt/build-cache


# Tools/paths
PODMAN     ?= podman
SYSTEMCTL  ?= systemctl --user
SYSTEMD_DIR?= $(HOME)/.config/containers/systemd
ROOT       := $(abspath $(CURDIR))

# Services = first-level subfolders of ~/podman (excluding dot dirs)
SERVICES := $(shell find "$(ROOT)" -mindepth 1 -maxdepth 1 -type d -not -name '.*' -printf "%f\n" | sort)

# Quadlets = any *.container/*.network/*.volume/*.kube one level down
QUADLETS := $(shell find "$(ROOT)" -mindepth 2 -maxdepth 2 -type f \
  \( -name '*.container' -o -name '*.network' -o -name '*.volume' -o -name '*.kube' \) \
  -print | sort)

.PHONY: list link unlink reload enable disable start stop restart status logs build pull clean-links deploy check

.PHONY: prune-images
prune-images:
	$(PODMAN) image prune -f || true

list:
	@echo "Services:"; printf "  - %s\n" $(SERVICES) || true
	@echo "Quadlets:"; printf "  - %s\n" $(QUADLETS) || true

# Symlink all quadlets into ~/.config/containers/systemd (no renaming!)
link:
	mkdir -p "$(SYSTEMD_DIR)"
	@echo "Linking quadlets into $(SYSTEMD_DIR)"
	@conflicts=0
	for src in $(QUADLETS); do
		base="$$(basename "$$src")"
		dest="$(SYSTEMD_DIR)/$$base"
		abs="$$(realpath "$$src")"
		if [ -e "$$dest" ] && [ ! -L "$$dest" ]; then
			echo "SKIP (exists, not symlink): $$dest"
			conflicts=$$((conflicts+1))
			continue
		fi
		ln -sf "$$abs" "$$dest"
		echo "  -> $$dest"
	done
	if [ $$conflicts -gt 0 ]; then
		echo "$$conflicts existing non-symlink files in $(SYSTEMD_DIR). Consider moving/renaming." 1>&2
	fi

unlink:
	@echo "Removing quadlet symlinks from $(SYSTEMD_DIR)"
	for src in $(QUADLETS); do
		base="$$(basename "$$src")"
		dest="$(SYSTEMD_DIR)/$$base"
		if [ -L "$$dest" ]; then
			rm -f "$$dest"
			echo "  x $$dest"
		fi
	done

reload:
	$(SYSTEMCTL) daemon-reload

# Build images for services that have a Dockerfile in the service folder.
# Tags come from the first Image= in a *.container; fallback to local/<svc>:latest.
build:
	@echo "Building images for services with a Dockerfile..."
	for svc in $(SERVICES); do \
		dir="$(ROOT)/$$svc"; \
		if [ -f "$$dir/Dockerfile" ]; then \
			img="$$(grep -h -m1 '^Image=' "$$dir"/*.container 2>/dev/null | head -n1 | cut -d= -f2- || true)"; \
			[ -z "$$img" ] && img="local/$$svc:latest"; \
			mkdir -p "$(BUILD_CACHE)/gomod" "$(BUILD_CACHE)/gobuild" "$(BUILD_CACHE)/npm" "$(BUILD_CACHE)/pip" "$(BUILD_CACHE)/cargo"; \
			echo "  [$${svc}] podman build -t '$$img' with caches..."; \
			$(PODMAN) build -t "$$img" \
				--volume "$(BUILD_CACHE)/gobuild":/root/.cache/go-build:Z \
				--volume "$(BUILD_CACHE)/gomod":/go/pkg/mod:Z \
				--volume "$(BUILD_CACHE)/npm":/root/.npm:Z \
				--volume "$(BUILD_CACHE)/pip":/root/.cache/pip:Z \
				--volume "$(BUILD_CACHE)/cargo-reg":/usr/local/cargo/registry:Z \
				--volume "$(BUILD_CACHE)/cargo-tgt":/usr/local/cargo/target:Z \
				"$$dir"; \
		fi; \
	done


# Pull images for services WITHOUT a Dockerfile (only if missing locally).
pull:
	@echo "Pulling (refreshing) images for services without Dockerfile..."
	for svc in $(SERVICES); do
		dir="$(ROOT)/$$svc"
		if [ ! -f "$$dir/Dockerfile" ]; then
			img="$$(grep -h -m1 '^Image=' "$$dir"/*.container 2>/dev/null | head -n1 | cut -d= -f2- || true)"
			[ -z "$$img" ] && continue
			echo "  [$${svc}] podman pull '$$img'"
			$(PODMAN) pull "$$img"
		fi
	done


# Enable units (networks first to satisfy After/Wants), then containers/volumes/kube.
enable:
	@echo "Enabling quadlet units..."
	net_units="$$(for f in $(QUADLETS); do b="$${f##*/}"; [[ "$${b##*.}" == "network" ]] && echo "$${b%.*}.network"; done)"
	[ -n "$$net_units" ] && $(SYSTEMCTL) enable $$net_units || true
	other_units="$$(for f in $(QUADLETS); do b="$${f##*/}"; ext="$${b##*.}"; name="$${b%.*}"; case "$$ext" in container) echo "$${name}.service";; volume) echo "$${name}.volume";; kube) echo "$${name}.kube";; esac; done)"
	[ -n "$$other_units" ] && $(SYSTEMCTL) enable $$other_units || true

disable:
	@echo "Disabling quadlet units..."
	all_units="$$(for f in $(QUADLETS); do b="$${f##*/}"; ext="$${b##*.}"; name="$${b%.*}"; case "$$ext" in container) echo "$${name}.service";; *) echo "$${name}.$$ext";; esac; done)"
	[ -n "$$all_units" ] && $(SYSTEMCTL) disable $$all_units || true

start:
	@echo "Starting quadlet units (networks first)..."
	net_units="$$(for f in $(QUADLETS); do b="$${f##*/}"; [[ "$${b##*.}" == "network" ]] && echo "$${b%.*}.network"; done)"
	[ -n "$$net_units" ] && $(SYSTEMCTL) start $$net_units || true
	other_units="$$(for f in $(QUADLETS); do b="$${f##*/}"; ext="$${b##*.}"; name="$${b%.*}"; case "$$ext" in container) echo "$${name}.service";; volume) echo "$${name}.volume";; kube) echo "$${name}.kube";; esac; done)"
	[ -n "$$other_units" ] && $(SYSTEMCTL) start $$other_units || true

stop:
	@echo "Stopping quadlet units..."
	all_units="$$(for f in $(QUADLETS); do b="$${f##*/}"; ext="$${b##*.}"; name="$${b%.*}"; case "$$ext" in container) echo "$${name}.service";; *) echo "$${name}.$$ext";; esac; done | tac)"
	[ -n "$$all_units" ] && $(SYSTEMCTL) stop $$all_units || true

restart:
	@echo "Restarting container services..."
	svc_units="$$(for f in $(QUADLETS); do b="$${f##*/}"; [[ "$${b##*.}" == "container" ]] && echo "$${b%.*}.service"; done)"
	[ -n "$$svc_units" ] && $(SYSTEMCTL) restart $$svc_units || true

status:
	@echo "Status of container services:"
	for f in $(QUADLETS); do
		b="$${f##*/}"; ext="$${b##*.}"; name="$${b%.*}"
		if [ "$$ext" = "container" ]; then
			echo "---- $$name.service ----"
			$(SYSTEMCTL) status -l --no-pager "$$name.service" || true
		fi
	done

# Usage: make logs S=caddy
logs:
	@svc="$(S)"; if [ -z "$$svc" ]; then echo "Usage: make logs S=<unit base name, e.g., caddy>"; exit 2; fi
	@echo "Showing logs for $$svc.service (journal) and container (podman) ..."
	$(SYSTEMCTL) status -l --no-pager "$$svc.service" || true
	$(PODMAN) logs --names --tail=200 "$$svc" || true

clean-links: unlink

# Full flow: build (if Dockerfile), pull (if not), link, reload systemd, enable+start
deploy: build pull link reload enable start
	@echo "✅ Deploy complete."

# Guardrail: warn if you accidentally used relative paths in quadlets.
check:
	@echo "Checking for relative paths in EnvironmentFile/Volume directives (should be absolute or use %h)..."
	@issues=0
	for f in $(QUADLETS); do
		if grep -qE '^(EnvironmentFile|Volume)=(\.[^/:]|[^/%h/])' "$$f"; then
			echo "  -> $$f contains relative EnvironmentFile/Volume paths"
			issues=$$((issues+1))
		fi
	done
	if [ $$issues -gt 0 ]; then echo "Found $$issues potential path issues."; else echo "All good."; fi
