Here’s a **repeatable checklist** for adding a new Podman service to your Alma guest, using everything you’ve set up (quadlets, Makefile deploys, and the host→guest build cache).

---

# Summary (what you’re doing)

1. Create a new `~/podman/<service>` folder with quadlet(s) and (optionally) a `Dockerfile`.
2. Point quadlets at **absolute paths** in your repo; use `Volume=host:ctr:opts` with `:Z` for SELinux.
3. Use the **Makefile** to build/pull images, link quadlets into `~/.config/containers/systemd/`, reload, enable, and start.
4. If the image is built (e.g., xcaddy), **mount the host-backed build cache** into the `podman build` so the transient Go cache never fills `/`.
5. Verify with systemd and container logs.

---

# Prereqs (one-time)

* On **host (Kubuntu)**: `~/podman-build-cache/` shared via **virtiofs** to the guest.

* On **guest (Alma)**: virtiofs mounted at `/mnt/build-cache`:

  ```bash
  sudo mkdir -p /mnt/build-cache
  sudo mount -t virtiofs buildcache /mnt/build-cache
  ```

  (Optional in `/etc/fstab`: `buildcache  /mnt/build-cache  virtiofs  defaults  0  0`)

* Set editor for libvirt:
  `echo 'export EDITOR="kate -b"' >> ~/.bashrc && source ~/.bashrc`

---

# 1) Scaffold a new service

```bash
cd ~/podman
mkdir mysvc
cd mysvc
```

**Files to create (minimum):**

* `mysvc.container`
* (optional) `mysvc.network` if you want a named network
* (optional) `Dockerfile` if you build your own image
* (optional) `.env` in your repo

**Standardized quadlet template (remote image):**

```ini
# ~/podman/mysvc/mysvc.container
[Unit]
Description=mysvc container
After=network-online.target mysvc.network
Wants=network-online.target mysvc.network

[Container]
# Use remote if you don't build locally:
Image=docker.io/library/nginx:latest
ContainerName=mysvc

# Ports
PublishPort=18080:80

# Config (ABS paths or %h), SELinux relabel with :Z
EnvironmentFile=%h/podman/mysvc/.env
Volume=%h/podman/mysvc/conf.d:/etc/nginx/conf.d:ro,Z

# App state (named volumes are fine)
Volume=mysvc_data:/var/lib/nginx

# Network (optional)
Network=mysvc

[Service]
Restart=always

[Install]
WantedBy=default.target
```

**Named network (optional, if you used `Network=mysvc`):**

```ini
# ~/podman/mysvc/mysvc.network
[Network]
Name=mysvc
```

> Notes
>
> * Prefer `Volume=/host:/ctr:ro,Z` (not `Mount=`), for consistency and SELinux.
> * Keep `.env` and configs **in your repo**; reference them with absolute paths or `%h`.

---

# 2) If you build locally (Dockerfile present)

**Set `Image=` in your `.container`** to the tag you intend to build, e.g.:

```
Image=local/mysvc:latest
```

**Example `Dockerfile` (multi-stage, lean final):**

```dockerfile
# builder (only if you need to compile things)
FROM golang:1.25 AS builder
WORKDIR /src
COPY . .
RUN go build -o /out/app ./...

# final
FROM docker.io/library/alpine:3.20
COPY --from=builder /out/app /usr/local/bin/app
ENTRYPOINT ["app"]
```

---

# 3) (Recommended) Makefile tweak to use the build cache in all builds

In your **~/podman/Makefile**, define the cache path and pass it to `podman build`.

At the top (or near other vars):

```make
BUILD_CACHE ?= /mnt/build-cache
```

Replace your `build` rule with this force-rebuild version (as we discussed) **plus** cache mounts:

```make
build:
	@echo "Force-building images for services with Dockerfile..."
	for svc in $(SERVICES); do \
		dir="$(ROOT)/$$svc"; \
		if [ -f "$$dir/Dockerfile" ]; then \
			img="$$(grep -h -m1 '^Image=' "$$dir"/*.container 2>/dev/null | head -n1 | cut -d= -f2- || true)"; \
			[ -z "$$img" ] && img="local/$$svc:latest"; \
			# Ensure cache dir exists (guest-side)
			mkdir -p "$(BUILD_CACHE)"; \
			echo "  [$${svc}] podman build --pull=always --no-cache -t '$$img' \"; \
			echo "              --volume $(BUILD_CACHE):/root/.cache/go-build:Z \"; \
			echo "              --volume $(BUILD_CACHE)/gomod:/go/pkg/mod:Z \"; \
			echo "              '$$dir'"; \
			"$(PODMAN)" build --pull=always --no-cache -t "$$img" \
				--volume "$(BUILD_CACHE)":/root/.cache/go-build:Z \
				--volume "$(BUILD_CACHE)"/gomod:/go/pkg/mod:Z \
				"$$dir"; \
		fi; \
	done
```

* `/root/.cache/go-build` → Go compilation cache (big/temporary).
* `/go/pkg/mod` → Go module cache (optional; speeds repeat builds).
  Both now live under `/mnt/build-cache` (host-backed), so `/` inside the guest stays clean.
  Clean anytime:

```bash
rm -rf ~/podman-build-cache/*   # run on the host
```

---

# 4) Deploy everything (link, reload, enable, start)

```bash
cd ~/podman
make deploy
```

This will:

* Build Dockerfile services (using the cache)
* Pull remote-only images
* Symlink quadlets into `~/.config/containers/systemd/`
* `systemctl --user daemon-reload`
* Enable + start networks then services

*(To test from zero: `make nuke deploy`.)*

---

# 5) Verify & troubleshoot

**Status & logs:**

```bash
systemctl --user status -l --no-pager mysvc.service
podman logs --names --tail=200 mysvc
```

**Common gotchas:**

* **SELinux denials:** Ensure `:Z` (or `:z` if sharing dirs across services).
* **Network=mysvc missing:** Add `mysvc.network` or remove `Network=` from the container.
* **Ports busy:** `ss -ltnp | egrep ':18080'`
* **Image missing:** `podman image exists <tag>` or just `make deploy` again.

---

# 6) Day-2 operations (handy targets)

* Restart all containers: `make restart`
* Logs for one service: `make logs S=mysvc`
* Rebuild/pull + restart: `make deploy`
* Prune old images: `make prune-images`
* Clean guest build cache dir: `sudo rm -rf /mnt/build-cache/*`
* Clean host cache dir: `rm -rf ~/podman-build-cache/*`

---

# 7) Quick “from compose to quadlet” mapping (mental model)

* `image:` → `Image=...`
* `ports:` → `PublishPort=host:ctr`
* `env_file:` / `environment:` → `EnvironmentFile=/abs/path/.env` and/or `Environment=KEY=VAL`
* `volumes:` → `Volume=/host:/ctr:ro,Z` (bind) or `Volume=name:/ctr` (named)
* `networks:` → `Network=name` **and** a `name.network` quadlet
* `depends_on:` → Use `Wants=`/`After=` in `[Unit]` if needed

---

If you want, I can drop a **ready-to-paste skeleton** (`mysvc.container` + optional `mysvc.network`) tailored to a specific service you’re about to add; just tell me the image and ports.
