# Podman Quadlet Workflow — Kubuntu (no VM, no cache)

Here’s a **repeatable checklist** for adding a new Podman service on your **Kubuntu desktop directly** (no KVM guest, no virtiofs build cache), using your Makefile to build, link quadlets, reload user systemd, enable, and start.

---

## Summary (what you’re doing)

1. Create a new `~/podman/<service>` folder with quadlet(s) and (optionally) a `Dockerfile`.
2. Keep paths **absolute** (or use `%h`) in quadlets; no SELinux relabel flags needed on Kubuntu.
3. Use the **Makefile** to build/pull images, link quadlets into `~/.config/containers/systemd/`, reload, enable, and start.
4. Verify with systemd and container logs.

---

## Prereqs (one-time on Kubuntu)

- **Install Podman** and friends:
  ```bash
  sudo apt update
  sudo apt install -y podman buildah skopeo uidmap slirp4netns
  ```
- (Recommended) Keep user services running after logout:
  ```bash
  loginctl enable-linger "$USER"
  ```
- Confirm user systemd is available:
  ```bash
  systemctl --user status
  ```

> **Makefile gotcha:** Your `SYSTEMCTL` var is `systemctl --user`. In recipes, call it **without quotes** like `$(SYSTEMCTL) daemon-reload` (quotes would turn it into a single un-runnable token).

---

## 1) Scaffold a new service

```bash
cd ~/podman
mkdir mysvc
cd mysvc
```

**Files to create (minimum):**

- `mysvc.container`
- (optional) `mysvc.network` if you want a named network
- (optional) `Dockerfile` if you build your own image
- (optional) `.env` in your repo

**Standard quadlet template (remote image):**

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

# Config (ABS paths or %h)
EnvironmentFile=%h/podman/mysvc/.env
Volume=%h/podman/mysvc/conf.d:/etc/nginx/conf.d:ro

# App state (named volumes are fine)
Volume=mysvc_data:/var/lib/nginx

# Network (optional)
Network=mysvc

[Service]
Restart=always

[Install]
WantedBy=default.target
```

**Named network (optional, only if you used `Network=mysvc`):**

```ini
# ~/podman/mysvc/mysvc.network
[Network]
Name=mysvc
```

> Notes
>
> - Prefer `Volume=/host:/ctr:ro` (bind) or `Volume=name:/ctr` (named). No `:Z` on Kubuntu.
> - Keep `.env` and configs **in your repo**; reference them with absolute paths or `%h`.
> - Use `Wants=`/`After=` for simple dependency ordering between services.

---

## 2) If you build locally (Dockerfile present)

Set `Image=` in your `.container` to the tag you intend to build, e.g.:

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

## 3) Makefile behavior (Kubuntu-local, no cache)

Your updated Makefile:

- **Builds** every service that contains a `Dockerfile`.
- Resolves the image name from `Image=` in the `.container` (fallback `local/<svc>:latest`).
- Uses a clean rebuild via `podman build --pull=always --no-cache -t <img> <dir>`.
- **Links** quadlets (`*.container`, `*.network`) into `~/.config/containers/systemd/`.
- **Reloads** user systemd, then **enables** and **starts** networks before services.

Relevant vars (typical):

```make
ROOT := $(CURDIR)
SERVICES := $(notdir $(wildcard $(ROOT)/*))
PODMAN ?= podman
SYSTEMCTL ?= systemctl --user
```

> **Reminder:** In rules, use `$(SYSTEMCTL)` without quotes.

---

## 4) Deploy everything (link, reload, enable, start)

From the repo root (e.g., `~/podman`):

```bash
make deploy
```

This will:

- Build services with a `Dockerfile` (locally; no external cache)
- Pull remote-only images
- Symlink quadlets into `~/.config/containers/systemd/`
- `systemctl --user daemon-reload`
- Enable + start networks, then services

---

## 5) Verify & troubleshoot

**Status & logs:**

```bash
systemctl --user status -l --no-pager mysvc.service
podman logs --names --tail=200 mysvc
```

**Common gotchas:**

- **Ports busy:** `ss -ltnp | egrep ':18080'`
- **Image missing:** `podman image exists <tag>` or just `make deploy` again
- **Unit not starting at login:** ran `loginctl enable-linger $USER`?
- **Quadlets not found:** ensure files are linked into `~/.config/containers/systemd/` (run `make link` or `make deploy`)
- **Wrong paths in `Volume=`/`EnvironmentFile=`:** use absolute paths or `%h`.

---

## 6) Day-2 operations (handy targets)

- Rebuild/pull + restart everything: `make deploy`
- Restart all containers: `make restart`
- Logs for one service: `make logs S=mysvc`
- Prune old images: `make prune-images`

*(Targets may vary slightly depending on your current Makefile — the above are supported in your updated version.)*

---

## 7) Quick “compose → quadlet” mapping (mental model)

- `image:` → `Image=...`
- `ports:` → `PublishPort=host:ctr`
- `env_file:` / `environment:` → `EnvironmentFile=/abs/path/.env` and/or `Environment=KEY=VAL`
- `volumes:` → `Volume=/host:/ctr:ro` (bind) or `Volume=name:/ctr` (named)
- `networks:` → `Network=name` **and** a `name.network` quadlet
- `depends_on:` → `Wants=`/`After=` in `[Unit]`

---

## 8) Ready-to-paste skeletons

**`mysvc.container` (edit Image/ports/paths):**

```ini
[Unit]
Description=mysvc container
After=network-online.target mysvc.network
Wants=network-online.target mysvc.network

[Container]
Image=local/mysvc:latest
ContainerName=mysvc
PublishPort=18080:80
EnvironmentFile=%h/podman/mysvc/.env
Volume=%h/podman/mysvc/conf.d:/etc/nginx/conf.d:ro
Volume=mysvc_data:/var/lib/nginx
Network=mysvc

[Service]
Restart=always

[Install]
WantedBy=default.target
```

**`mysvc.network` (optional):**

```ini
[Network]
Name=mysvc
```

---

If you paste a compose snippet for any app, I can convert it to quadlets that drop straight into `~/podman/<service>/` and work with this Makefile.

