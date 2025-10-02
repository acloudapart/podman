# Compose → Quadlet: One‑Page Cheat Sheet

*Target: Alma Linux 10 guest running Podman quadlets via `~/.config/containers/systemd/`*

## Golden Rules

* **Absolute paths** (or `%h`) for bind mounts; add **`:Z`** for SELinux relabel.
* Prefer `Volume=` over `Mount=` for simple bind/named volumes.
* Put app config and `.env` **in your repo**; reference with `EnvironmentFile=` and `Volume=`.
* If you need a user-defined network, create a separate `name.network` quadlet and set `Network=name` in the container quadlet.
* Deployment lifecycle is handled by your **Makefile**: build/pull → link → `daemon-reload` → enable/start.

---

## Compose → Quadlet Mapping (most-used)

| Compose key        | Quadlet directive                | Notes                                                                                              |    |                        |
| ------------------ | -------------------------------- | -------------------------------------------------------------------------------------------------- | -- | ---------------------- |
| `image:`           | `Image=`                         | For local builds, set to your tag (e.g., `local/svc:latest`).                                      |    |                        |
| `container_name:`  | `ContainerName=`                 | Optional; otherwise Podman autogenerates.                                                          |    |                        |
| `ports:`           | `PublishPort=host:ctr[/proto]`   | Repeat per port; supports `/tcp` `/udp`.                                                           |    |                        |
| `environment:`     | `Environment=KEY=VAL`            | Repeat per var. Use `EnvironmentFile=` for files.                                                  |    |                        |
| `env_file:`        | `EnvironmentFile=/abs/path/.env` | Multiple allowed.                                                                                  |    |                        |
| `volumes:` (bind)  | `Volume=/host:/ctr[:opts]`       | Add **`:Z`**; add `:ro` if read-only.                                                              |    |                        |
| `volumes:` (named) | `Volume=name:/ctr`               | Podman auto-creates named volume.                                                                  |    |                        |
| `command:`         | `Command=...`                    | Equivalent to Compose `command`.                                                                   |    |                        |
| `entrypoint:`      | `Entrypoint=...`                 | Overrides image entrypoint.                                                                        |    |                        |
| `restart:`         | `[Service] Restart=always        | on-failure                                                                                         | …` | Use systemd semantics. |
| `depends_on:`      | `[Unit] Wants=...` + `After=...` | Name the **.service** units (usually same as container name).                                      |    |                        |
| `networks:`        | `Network=name`                   | Plus a `name.network` quadlet (below).                                                             |    |                        |
| `healthcheck:`     | `HealthCmd=...`                  | Also `HealthInterval=`, `HealthTimeout=`, `HealthStartPeriod=`, `HealthRetries=` in `[Container]`. |    |                        |
| `logging:`         | `LogDriver=` + `LogOpt=`         | Optional; defaults to journald.                                                                    |    |                        |
| `user:`            | `User=`                          | e.g., `1000:1000` or `user:group`.                                                                 |    |                        |
| `work_dir:`        | `Workdir=`                       | Set container working dir.                                                                         |    |                        |

> Tip: Most Compose keys map into the **`[Container]`** section; lifecycle/policy go to **`[Service]`**, and ordering/targets go to **`[Unit]`**.

---

## Minimal Container Quadlet (remote image)

```ini
# ~/podman/mysvc/mysvc.container
[Unit]
Description=mysvc container
After=network-online.target mysvc.network
Wants=network-online.target mysvc.network

[Container]
Image=docker.io/library/nginx:latest
ContainerName=mysvc
PublishPort=18080:80
EnvironmentFile=%h/podman/mysvc/.env
Volume=%h/podman/mysvc/conf.d:/etc/nginx/conf.d:ro,Z
Volume=mysvc_data:/var/lib/nginx
Network=mysvc

[Service]
Restart=always

[Install]
WantedBy=default.target
```

## Optional: Named Network Quadlet

```ini
# ~/podman/mysvc/mysvc.network
[Network]
Name=mysvc
```

---

## Common Translations by Example

**Compose → Quadlet (ports):**

```yaml
# compose
ports:
  - "8080:80"
  - "8443:443/tcp"
  - "5353:5353/udp"
```

```ini
# quadlet
PublishPort=8080:80
PublishPort=8443:443/tcp
PublishPort=5353:5353/udp
```

**Compose → Quadlet (env & env_file):**

```yaml
# compose
env_file: ./.env
environment:
  TZ: America/Chicago
  LOG_LEVEL: info
```

```ini
# quadlet
EnvironmentFile=%h/podman/mysvc/.env
Environment=TZ=America/Chicago
Environment=LOG_LEVEL=info
```

**Compose → Quadlet (volumes):**

```yaml
# compose
volumes:
  - ./config:/app/config:ro
  - data:/var/lib/app
```

```ini
# quadlet
Volume=%h/podman/mysvc/config:/app/config:ro,Z
Volume=mysvc_data:/var/lib/app
```

**Compose → Quadlet (command & entrypoint):**

```yaml
# compose
command: ["-serve", "-port=80"]
entrypoint: ["/usr/local/bin/app"]
```

```ini
# quadlet
Entrypoint=/usr/local/bin/app
Command=-serve -port=80
```

**Compose → Quadlet (depends_on):**

```yaml
# compose
services:
  db:
    image: postgres:16
  api:
    image: local/api
    depends_on: [db]
```

```ini
# ~/podman/db/db.container → ContainerName=db
# ~/podman/api/api.container
[Unit]
Wants=db.service
After=db.service
```

**Compose → Quadlet (healthcheck):**

```yaml
# compose
healthcheck:
  test: ["CMD-SHELL", "wget -qO- http://localhost:8080/health || exit 1"]
  interval: 10s
  timeout: 2s
  start_period: 5s
  retries: 3
```

```ini
# quadlet (in [Container])
HealthCmd=/bin/sh -c "wget -qO- http://localhost:8080/health || exit 1"
HealthInterval=10s
HealthTimeout=2s
HealthStartPeriod=5s
HealthRetries=3
```

---

## Build & Deploy (with host-backed cache)

* If a `Dockerfile` exists in the service folder, set `Image=` to your tag (e.g., `local/mysvc:latest`).
* Your `make deploy` target will: build (with cache mounts), pull, link, reload, enable and start all quadlets.
* Build cache mounts used by the Makefile:

  * `/root/.cache/go-build` and `/go/pkg/mod` → backed by your virtiofs share at `/mnt/build-cache`.

### Quick Commands (guest)

```bash
cd ~/podman && make deploy           # build/pull + (re)start
systemctl --user status mysvc        # service status
podman logs --names --tail=200 mysvc # app logs
```

---

## Troubleshooting Cheats

* **SELinux denials?** Ensure `:Z` on bind mounts (or `:z` when sharing dirs across multiple containers).
* **Port already in use?** `ss -ltnp | egrep ':<hostport>'`
* **Network missing?** Add the `name.network` quadlet or remove `Network=`.
* **Image not found?** Run `make deploy` to pull/build.
* **Persistent data** should be a named volume (`Volume=name:/path`) rather than a host path unless you need to inspect/edit it directly from the host.
