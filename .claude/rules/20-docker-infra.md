# Rule 20 — Docker and host infrastructure

## The ARM64 constraint

This host is **aarch64**. Before adding any image, verify an `arm64` manifest
exists:

```bash
docker manifest inspect <image>:<tag> | jq -r '.manifests[].platform | "\(.os)/\(.architecture)"'
```

Known risk areas to check during planning, not during deployment:
`guacamole/guacd`, `guacamole/guacamole`, exporters, and anything published as
a single-arch amd64 build. An amd64-only image will either fail to start or run
under emulation and burn the CPU budget. Record findings in `DECISIONS.md`.

## The service contract

No container is added without all ten of these decided and written down:

1. CPU limit (`deploy.resources.limits.cpus`)
2. Memory limit + reservation
3. `restart:` policy
4. Healthcheck that proves the service *serves*, not that a PID exists
5. Logging limits (Rule 10)
6. Network membership
7. Port exposure decision — `expose:` unless it is nginx
8. Backup requirement (or an explicit "rebuildable, no backup")
9. Monitoring requirement (scrape target or blackbox check)
10. Security posture: user, capabilities, read-only rootfs, `no-new-privileges`

Missing any one of these is a blocker, not a follow-up.

## Networking

Two networks, created as **external** so projects can be brought up and down
independently without Compose destroying a network another project is using:

- `proxy-net` — nginx plus anything nginx must reach.
- `backend-net` — `internal: true`. Service-to-service only, no egress.

Nginx is the only member of both. A service joins `proxy-net` **only** if nginx
proxies to it directly. Postgres, guacd, node_exporter, and Alertmanager never
join `proxy-net`.

Service discovery is Docker's embedded DNS on the container name. Do not
hardcode container IPs.

## Ports — the UFW trap

Docker writes its own `iptables` rules into the `DOCKER` chain, which is
evaluated **before** UFW's `ufw-user-input` chain. Consequences:

- `ports: "9090:9090"` is reachable from the internet even with UFW default-deny
  and no allow rule. UFW will report it as blocked. It is not.
- The mitigations, in order of preference:
  1. **Do not publish the port at all.** Use `expose:`. This is the rule here.
  2. If a port must be published for host-local use, bind it explicitly:
     `127.0.0.1:9090:9090`.
  3. Only as a last resort, `DOCKER-USER` chain rules or
     `"iptables": false` in `daemon.json` (which then requires managing all
     container networking by hand — usually not worth it).

Audit after every deployment phase — belief is not evidence:

```bash
ss -tulpn | grep -v '127.0.0.1\|::1'
docker ps --format '{{.Names}}\t{{.Ports}}'
sudo nmap -Pn -p- <public-ip>   # from a machine that is not this one
```

## node_exporter on the host

Runs as a systemd unit, not a container, because containerising it means
bind-mounting `/proc`, `/sys`, and `/` and it still misreports some host
metrics. Bind it to the Docker bridge gateway or `127.0.0.1` and let Prometheus
reach it via `host.docker.internal` / the gateway IP — never `0.0.0.0`.

## Images

- Pin to an explicit version tag, and prefer pinning the digest for anything
  internet-facing. Never `latest` in a deployed file.
- Prefer official and minimal (`-alpine`, `-slim`) images where an arm64 build
  exists.
- Record the current pinned version of every image in `docs/context/STATE.md`
  so a rebuild is reproducible.

## Storage layout

`/` is 48 G and holds the OS and `/var/lib/docker`. `/mnt/data` is 147 G
and empty. Persistent volumes (Postgres, Prometheus TSDB, Grafana, backups)
belong on `/mnt/data` — a full root disk takes down the whole box,
including sshd. Decide the exact bind-mount vs named-volume-with-custom-root
approach in planning and record it.

## Compose conventions

- One `compose.yml` per project directory; projects are independently
  deployable.
- `.env` per project, gitignored; `.env.example` committed with every key
  present and every value blank or fake.
- Pin the compose file to explicit service `container_name`s so logs, audits,
  and nginx upstreams all agree on one name.
- `docker compose config` must be clean before any `up`.
