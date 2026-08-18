# Infrastructure Implementation Plan

**Host:** `onebox-prod` · Oracle Cloud · Ubuntu 24.04.4 LTS · aarch64 · 2 vCPU / 11 GiB / 4 GiB swap
**Status:** Proposed — awaiting approval. Nothing in this document has been implemented.
**Written:** 2026-08-16 · Supersedes nothing; `plan.md` is the brief this answers.

Companion documents (read alongside, not instead):
`docs/context/ENVIRONMENT.md` (verified facts) ·
`docs/context/DECISIONS.md` (ADRs + open items) ·
`.claude/rules/` (the constraints this plan obeys)

---

# 1. Executive Summary

## What we are building

A single-node, internet-facing platform where **nginx is the only public
door**. Behind it: a throwaway test site at `/`, Grafana at `/monitoring/`, and
Kasm Workspaces at `/webrdp/`. Everything else lives on internal Docker
networks and is unreachable from outside.

## What discovery changed

The brief was written against assumptions. Five of them were wrong, and each
changes the work:

| Assumption in the brief | Reality | Effect |
|---|---|---|
| Generic x86 Linux VPS | **aarch64 on Oracle Cloud** | Every image needs an arm64 manifest. Kasm workspace images are the risk. |
| UFW manages the firewall | **UFW is inactive**; iptables + `netfilter-persistent` is live | Enabling UFW would flush the rule we are connected through. Manage iptables instead. |
| SSH is a public attack surface | **SSH arrives over Tailscale**; OCI has no ingress rules | The largest attack surface in the brief mostly does not exist. |
| Fail2ban/auditd to be installed | **Already running** | Extend, don't install. And auditd has *zero rules loaded* — it produces nothing. |
| Guacamole for remote access | **Kasm Workspaces CE** (user directive) | Different resource class entirely — see §22. |

## The one thing that can fail

**Kasm's published minimum is 2 cores / 4 GB — the entire machine — and one
default workspace session wants 2768 MB and both vCPUs.** The monitoring stack
must also fit. This is not a tuning problem; it is a "does it fit at all"
problem, and it is why Phase 7 is sub-phased with measurement as the gate
(§30). If it does not fit, the honest outcome is a report with numbers, not a
platform that OOMs on first real use.

The 4 GiB swap added on 2026-08-16 buys a grace period. It does not add
capacity.

## Design posture

Boring, observable, recoverable. No Loki, no OpenTelemetry, no service mesh.
Everything reproducible from a private git repo plus a secrets store. Nine
things get decided per container before it exists (§21), and a backup is not a
backup until a restore has been tested (§25).

## Build order: tailnet first, public last

There is no domain yet, and that turns out to be an advantage rather than a
delay. Tailscale issues **real Let's Encrypt certificates** for this host's
MagicDNS name (`onebox-prod.tailnet-example.ts.net`), so the entire stack — nginx,
TLS, subpath routing, Grafana, Kasm, WebSockets, the full acceptance matrix —
is built and proven on the tailnet with **zero public exposure**. Buying the
domain then becomes Phase 11: one more `server` block and a certbot cert.

The two risks that can kill this plan (Kasm's resource fit, and arm64 workspace
images) surface in Phase 7 — before a domain is bought and before anything is
internet-reachable. See §8a and D-010.

## What we need from you before Phase 1

1. **Enable HTTPS Certificates** in the Tailscale admin console
   (`login.tailscale.com/admin/dns` → HTTPS Certificates). Currently off.
   Needed by Phase 3, not Phase 1.
2. Whether **`your-laptop`** is the intended RDP target (Phase 7).
3. Whether the **`ubuntu`** account is still needed — it is a provisioning
   artefact (§17).
4. Brevo SMTP key, sender, and recipient addresses (Phase 6).

**Resolved:** D-009 confirmed (iptables, never UFW) · the `198.51.100.23` login
was provisioning-era, pre-Tailscale · the 3389 rule was a manual xrdp test and
the NSG is now clean · private repo live at
`git@github.com:yourusername/personal-infrastructure.git`.

---

# 2. Current Environment — Discovery Complete

Phase 0 is **done**. Full detail in `docs/context/ENVIRONMENT.md`; the
decision-relevant summary:

## Confirmed

| | |
|---|---|
| OS / arch | Ubuntu 24.04.4 LTS, `6.17.0-1018-oracle`, **aarch64** |
| CPU / RAM | 2 vCPU / 11 GiB · **4 GiB swap**, `vm.swappiness=10` |
| Disks | `/` 48 G (~38 G free) · `/mnt/data` 147 G (empty) |
| Public IPv4 | `203.0.113.10` · no public IPv6 |
| Private | `10.0.0.10` on `enp0s6` (OCI VNIC, NAT) |
| Tailscale | `100.64.0.10`; peers `your-laptop` (100.64.0.20, active), `oneplus-nord-3-5g` |
| Docker | 29.7.2, Compose **v5.4.0**; `/etc/docker/daemon.json` **absent** |
| Firewall | **UFW inactive.** iptables via `netfilter-persistent`; default-deny by trailing REJECT; `FORWARD` DROP |
| OCI Security List | **Egress `0.0.0.0/0` all ports. No ingress rules configured.** |
| sshd | `passwordauthentication no`, pubkey yes, `allowusers prodadmin ubuntu`, `permitrootlogin without-password`, `x11forwarding yes` |
| auditd | Running, enabled, **zero rules loaded** |
| fail2ban | Running, enabled, **one jail: `sshd`** |
| Pre-existing | `xrdp` (3389), `rpcbind` (111), `iperf3` (5201), `tailscaled`, `unattended-upgrades` |

## Ports — current truth

| Port | Listening | Host firewall | OCI ingress | Reachable from internet |
|---|---|---|---|---|
| 22 | yes | ACCEPT | none configured | **See §17 caveat** |
| 3389 xrdp | yes | **ACCEPT, any source** | none configured | No |
| 111 rpcbind | yes | REJECT | — | No |
| 5201 iperf3 | yes | REJECT | — | No |

O-001 is **closed**: with no OCI ingress rules, nothing is publicly reachable
regardless of what the host firewall permits. Two residual items remain, and
both are hygiene rather than emergency:

- The 3389 ACCEPT rule exists **only in the live kernel table** — it is not in
  `/etc/iptables/rules.v4`. Live and persisted state disagree, so the firewall
  is not currently reproducible. Fixed in §19.
- `rpcbind`, `iperf3`, and `xrdp` are running with no role here. Disabled in
  Phase 1 — defence in depth, since a future OCI rule change should not
  silently expose a service nobody remembered was running.

## Verification command

Re-run before each phase; drift is normal and assumptions rot:

```bash
uname -srm; nproc; free -h; swapon --show; df -h / /mnt/data
ss -tulpn | grep -vE '127\.0\.0\.1|\[::1\]'
sudo iptables -S INPUT; sudo ufw status
tailscale status
sudo sshd -T | grep -Ei '^(port|permitroot|passwordauth|allowusers|x11)'
sudo auditctl -l | head; sudo fail2ban-client status
```

---

# 3. Architecture

```text
                          INTERNET
                             │
              OCI Security List  (ingress: 80, 443 only)
                             │
              Host iptables    (ACCEPT 80, 443; REJECT rest)
                             │
                        ┌────┴────┐
                        │  NGINX  │   ← the only public process
                        │  :80    │      TLS terminated here
                        │  :443   │
                        └────┬────┘
                             │  proxy-net
          ┌──────────────────┼──────────────────┐
          │                  │                  │
     /  and /www       /monitoring/         /webrdp/
          │                  │                  │
    ┌─────┴─────┐      ┌─────┴─────┐      ┌─────┴──────┐
    │   test-   │      │  Grafana  │      │ Kasm proxy │
    │  website  │      └─────┬─────┘      └─────┬──────┘
    └───────────┘            │                  │
                       backend-net         kasm-internal
                             │                  │
                     ┌───────┴───────┐   ┌──────┴───────────┐
                     │  Prometheus   │   │ api · manager    │
                     │  Alertmanager │   │ agent · share    │
                     └───────┬───────┘   │ postgres · redis │
                             │           └──────┬───────────┘
                    node_exporter                │
                   (host systemd,          workspace container
                    127.0.0.1:9100)               │
                             │              ┌─────┴─────┐
                        Brevo API           │           │
                             │             SSH         RDP
                          Email                  via tailscale0
                                                       │
                                                 your-laptop
                                                (100.64.0.20)


        ADMIN PATH (separate, never public):
        you ──► Tailscale ──► sshd on 100.64.0.10:22
```

**Two independent access paths, by design.** Public HTTPS for services;
Tailscale for administration. If Kasm breaks, SSH still works. If Tailscale
breaks, the OCI serial console is the floor. Neither path depends on the other.

---

# 4. Network Architecture

## External connectivity

| Layer | Configuration | Rationale |
|---|---|---|
| OCI Security List | Ingress: **80/tcp, 443/tcp from 0.0.0.0/0**. Egress: unchanged. | The outermost gate. Nothing else is ever added here without a written reason. |
| Host iptables | ACCEPT 80, 443; keep 22; drop the stale 3389 rule | Second gate — defence in depth if an OCI rule is added by accident. |
| Tailscale | `ts-input` chain, already present | Admin path. Not a public surface. |
| IPv6 | **None.** No public IPv6 on this instance. | One fewer surface. If it is ever enabled, every rule in §19 must be mirrored — an IPv6-blind firewall is a classic bypass. |

### Ports to open in OCI — the complete list, and **not yet**

```
Ingress  TCP  80    0.0.0.0/0    HTTP → redirects to HTTPS, and ACME http-01
Ingress  TCP  443   0.0.0.0/0    HTTPS — all application traffic
```

**That is all — and neither is opened until Phase 11.** Phases 1–10 run
entirely on the tailnet with real TLS (§8a), so the server stays completely
unreachable from the internet while Kasm is being wrung out. Port 22 is never
opened at OCI; SSH arrives over Tailscale.

Current NSG state, confirmed by the user: **egress only, no ingress rules.**
The 3389 ingress rule that existed during xrdp testing has been removed.

## Docker networks

Two networks, both created **external** so projects can be stopped and started
independently without Compose destroying a network another project is using:

```bash
docker network create proxy-net
docker network create --internal backend-net
```

| Network | Driver | `internal` | Members |
|---|---|---|---|
| `proxy-net` | bridge | no | nginx, test-website, grafana, kasm-proxy |
| `backend-net` | bridge | **yes** | prometheus, alertmanager, grafana |
| `kasm-internal` | bridge | yes | Kasm's own components (managed by Kasm) |

`internal: true` on `backend-net` means those containers get **no egress at
all** — they cannot reach the internet even if compromised. Grafana sits on
both: `proxy-net` so nginx can reach it, `backend-net` so it can query
Prometheus.

Service discovery is Docker's embedded DNS on container name. No hardcoded IPs.

## Connectivity matrix

| From ↓ To → | nginx | test-site | grafana | prom | alertmgr | kasm-proxy | kasm-internal | node_exp | internet |
|---|---|---|---|---|---|---|---|---|---|
| **nginx** | — | ✅ | ✅ | ❌ | ❌ | ✅ | ❌ | ❌ | ✅ |
| **test-site** | ❌ | — | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |
| **grafana** | ❌ | ❌ | — | ✅ | ✅ | ❌ | ❌ | ❌ | ❌ |
| **prometheus** | ❌ | ❌ | ✅ | — | ✅ | ❌ | ❌ | ✅ | ❌ |
| **alertmanager** | ❌ | ❌ | ❌ | ❌ | — | ❌ | ❌ | ❌ | ✅ ¹ |
| **kasm-proxy** | ❌ | ❌ | ❌ | ❌ | ❌ | — | ✅ | ❌ | ❌ |
| **workspace** | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ | ⚠️ ² | ❌ | ✅ ³ |

¹ Alertmanager needs egress to reach the Brevo API. It is therefore **not** on
`internal: true` — it gets `backend-net` plus a dedicated egress path. This is
the one deliberate hole in the internal network, and it is why Alertmanager
gets no inbound reachability from anything except Prometheus.

² A workspace must reach Kasm's own components for session brokering. It must
**not** reach `backend-net`, the Docker socket, or the host. See §21.

³ Workspaces need internet for their intended use. This is the least-trusted
thing on the box — treat it as hostile (§29).

**Explicitly forbidden:** anything → Prometheus except Grafana; test-website →
anything; workspace → `backend-net`; anything except nginx → `kasm-proxy`.

---

# 5. Docker Architecture

## Daemon configuration

`/etc/docker/daemon.json` does not exist. Create it — the log-rotation default
alone justifies it, because a service that forgets its `logging:` block should
still not be able to fill the disk:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" },
  "data-root": "/mnt/data/docker",
  "live-restore": true,
  "userland-proxy": false,
  "no-new-privileges": true
}
```

| Setting | Why |
|---|---|
| `log-opts` | Bounds container logs at 50 MB each. Without it, one chatty container fills `/` and takes down sshd with it. |
| `data-root` | **O-011.** `/` has ~38 G free; Kasm recommends 50 G and pulls large images. `/mnt/data` has 147 G. Requires a daemon restart and a data migration — do it in Phase 1, while nothing is running, not in Phase 7 when it is painful. |
| `live-restore` | Containers survive a daemon restart. Directly serves the §28 "Docker daemon restarts" scenario. |
| `userland-proxy: false` | Uses iptables DNAT instead of a per-port proxy process. Fewer processes on a 2-vCPU box, and preserves real source IPs. |
| `no-new-privileges` | Daemon-wide default; per-container `security_opt` still declared explicitly so the compose file is self-documenting. |

**Changing `data-root` is destructive to existing images.** Nothing is deployed
yet, so do it first, before anything is pulled.

## Compose conventions

- One `compose.yml` per project; each independently deployable.
- Explicit `container_name` so logs, audit events, and nginx upstreams all
  agree on one identifier.
- `.env` per project, `chmod 600`, gitignored. `.env.example` committed with
  every key present and every value blank.
- Image tags pinned to an explicit version, digest-pinned for anything
  internet-facing. Never `latest`.
- `docker compose config -q` must pass before any `up`.

## The ARM64 gate

Before any image enters a compose file:

```bash
docker manifest inspect <image>:<tag> \
  | jq -r '.manifests[].platform | "\(.os)/\(.architecture)"' | sort -u
```

Must include `linux/arm64`. No emulation — on 2 vCPU the cost is not
affordable, and it adds a failure mode that is miserable to diagnose.

Expected results, to be verified not assumed: nginx, Prometheus, Grafana,
Alertmanager, node_exporter, and Postgres all publish arm64. **Kasm's workspace
images are the open risk** — Kasm's own documentation states not all published
workspace images exist for all architectures.

---

# 6. Project Structure

```text
/opt/server/                        ← deployed tree, git-managed
├── .gitignore
├── README.md
├── proxy-nginx/
│   ├── compose.yml
│   ├── nginx.conf                  ← log_format, worker tuning, gzip
│   ├── conf.d/
│   │   ├── 00-default.conf         ← catch-all: reject unknown Host
│   │   ├── 10-redirect.conf        ← :80 → :443 + ACME http-01
│   │   ├── 20-site.conf            ← / and /www → test-website
│   │   ├── 30-monitoring.conf      ← /monitoring/ → grafana
│   │   └── 40-kasm.conf            ← /webrdp/ → kasm
│   ├── snippets/
│   │   ├── ssl.conf
│   │   ├── security-headers.conf   ← baseline
│   │   ├── headers-grafana.conf    ← per-app override
│   │   ├── headers-kasm.conf       ← per-app override
│   │   ├── proxy-common.conf
│   │   └── rate-limit.conf         ← zone definitions only
│   ├── .env.example
│   └── README.md
├── monitoring/
│   ├── compose.yml
│   ├── prometheus/{prometheus.yml,rules/}
│   ├── alertmanager/alertmanager.yml
│   ├── grafana/{provisioning/,dashboards/}
│   ├── .env.example
│   └── README.md
├── kasm/
│   ├── README.md                   ← install method, pinned version, zone settings
│   ├── compose.pinned.yml          ← installer output, version-pinned by us
│   ├── conf/                       ← our overrides only
│   ├── notes/                      ← MFA + recovery runbook, measurements
│   └── INSTALLER-OWNED.md          ← what we must NOT edit (see §15)
├── test-website/
│   ├── compose.yml
│   ├── Dockerfile
│   ├── src/server.js
│   └── README.md
├── scripts/
│   ├── backup.sh
│   ├── restore-test.sh
│   ├── port-audit.sh
│   └── preflight.sh
└── docs/
    ├── PLAN.md                     ← this document
    ├── RUNBOOK.md
    ├── DISASTER-RECOVERY.md
    └── ADDING-A-SERVICE.md
```

## Numbered nginx conf.d files — why

Nginx loads `conf.d/*.conf` in **lexical order**, and the first matching
`server` block wins for a given `Host`. Numbering makes evaluation order
explicit instead of accidental, and `00-default.conf` guarantees a request with
an unknown or absent `Host` header hits a deliberate reject rather than
whichever site happens to sort first.

## Where persistent data lives

Everything on `/mnt/data`, never `/`:

```text
/mnt/data/
├── docker/            ← Docker data-root (§5)
├── data/
│   ├── prometheus/
│   ├── grafana/
│   └── kasm/
└── backups/
    ├── daily/
    └── weekly/
```

A full root disk takes down sshd, Docker, and the ability to fix it. Keeping
`/` for the OS alone is the cheapest insurance on this box.

## Deployed tree vs this repo

The repo is the source of truth; `/opt/server` is a checkout of it. Config
changes are reviewed as a diff, committed, then pulled — never edited in place
on the server. That is what makes rollback `git checkout <tag> && docker compose up -d`
instead of an archaeology exercise.

---

# 7. Nginx Architecture

## Role

The single public application gateway. TLS terminates here. Every backend is
reachable only through it, on internal Docker networks.

Image: `nginx:1.27-alpine` (arm64 verified before use), pinned by digest.

## `nginx.conf` — global

```nginx
user  nginx;
worker_processes  auto;          # = 2 here
error_log  /var/log/nginx/error.log warn;

events { worker_connections 1024; }

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;

    server_tokens off;           # do not advertise the version

    # --- canonical JSON access log (see .claude/rules/10-logging-audit.md) ---
    map $request_time $request_time_ms { ~^(\d+)\.(\d{3}) "$1$2"; default "0"; }

    log_format json_main escape=json
      '{"ts":"$time_iso8601","level":"info","service":"nginx","env":"vps-prod",'
      '"host":"$hostname","event":"http.request","actor":"$remote_user",'
      '"source_ip":"$remote_addr","request_id":"$request_id",'
      '"target":"$request_uri","method":"$request_method","status":$status,'
      '"outcome":"$upstream_status","duration_ms":$request_time_ms,'
      '"upstream":"$upstream_addr","upstream_ms":"$upstream_response_time",'
      '"bytes_sent":$body_bytes_sent,"referer":"$http_referer",'
      '"user_agent":"$http_user_agent","server_name":"$server_name","msg":""}';

    access_log /var/log/nginx/access.log json_main;

    sendfile on;
    tcp_nopush on;
    keepalive_timeout 65;
    client_body_timeout 15s;     # slow-client protection
    client_header_timeout 15s;
    send_timeout 30s;
    client_max_body_size 1m;     # global floor; per-location overrides raise it

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml;
    gzip_min_length 1024;

    include /etc/nginx/conf.d/*.conf;
}
```

Notes on the log format, because two of these bite people:

- `$time_iso8601` is **second precision and local offset**. The container runs
  with `TZ=UTC` so the offset is `+00:00`. Rule 10 wants milliseconds; nginx
  has no such variable. Accepting second precision on access logs is the
  pragmatic call — record it as a known deviation rather than pretending.
- `duration_ms` comes from a `map` over `$request_time`, which is
  seconds-with-3-decimals. Logging seconds into a field named `_ms` would be a
  quiet lie that survives into every dashboard built on it.

## Request ID propagation

`$request_id` is generated by nginx per request. Passed downstream and returned
to the client so a user-reported problem maps to a log line:

```nginx
add_header  X-Request-Id $request_id always;
proxy_set_header X-Request-Id $request_id;
```

## `snippets/proxy-common.conf`

```nginx
proxy_http_version 1.1;
proxy_set_header Host              $host;
proxy_set_header X-Real-IP         $remote_addr;
proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header X-Forwarded-Host  $host;
proxy_set_header X-Request-Id      $request_id;
proxy_connect_timeout 5s;
proxy_send_timeout    60s;
proxy_read_timeout    60s;
```

Kasm overrides the timeouts to 1800s in its own location (§15) — long-lived
sessions need it, and applying 1800s globally would let a slow-loris tie up a
worker for half an hour.

## `snippets/security-headers.conf` — baseline

```nginx
add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
add_header X-Content-Type-Options    "nosniff" always;
add_header X-Frame-Options           "SAMEORIGIN" always;
add_header Referrer-Policy           "strict-origin-when-cross-origin" always;
add_header Permissions-Policy        "geolocation=(), microphone=(), camera=()" always;
```

**`preload` is deliberately omitted from HSTS.** Submitting to the preload list
is effectively irreversible for months. Add it once the domain has been stable
for a while, not on day one.

**`always` is not optional.** Without it, `add_header` is skipped on 4xx/5xx
responses — so error pages ship without security headers, which is exactly when
they matter.

## Per-application headers

`add_header` does not merge — **a single `add_header` in a `location` block
discards every header inherited from the parent**. This is the most common way
security headers silently vanish. Each app therefore gets a complete snippet,
not a partial one.

| App | Deviation | Reason |
|---|---|---|
| test-website | Baseline + strict CSP | Static content; nothing to break. |
| Grafana | Baseline, `X-Frame-Options: SAMEORIGIN`, CSP allowing `unsafe-inline` styles | Grafana's plugin system needs it; a strict CSP breaks panel rendering. |
| **Kasm** | Baseline **minus** `X-Frame-Options`; CSP permitting `blob:`, `data:`, `wss:`, worker-src | Kasm uses canvas/WebGL, web workers, WebSockets, and the async clipboard API. A generic CSP produces a blank canvas or a session that connects then dies — symptoms that look like a network fault, not a header problem. Possibly `Permissions-Policy: clipboard-read=(self), clipboard-write=(self)`. |

**Every header set is validated against a live Kasm session, not the login
page.** The login page renders fine under headers that break the workspace.

## Rate limiting — zones

```nginx
# snippets/rate-limit.conf — definitions only, applied per location
limit_req_zone  $binary_remote_addr zone=general:10m rate=30r/s;
limit_req_zone  $binary_remote_addr zone=auth:10m    rate=5r/m;
limit_conn_zone $binary_remote_addr zone=perip:10m;
limit_req_status 429;
limit_conn_status 429;
```

| Zone | Rate | Applied to | Reasoning |
|---|---|---|---|
| `general` | 30 r/s, burst 60 nodelay | `/`, `/monitoring/` | A dashboard page load is 20–40 requests. 30 r/s with burst 60 absorbs a normal page load; a scraper does not. |
| `auth` | 5 r/m, burst 5 | Kasm + Grafana login endpoints only | Five login attempts a minute is generous for a human and useless for a brute-forcer. Combined with mandatory MFA this is the real control. |
| `perip` | 20 connections | server-wide | Multi-tab use is normal; 20 is well above a person and well below a flood. |

**The critical rule:** `limit_req` is **never** applied to Kasm's WebSocket or
session paths. A rate limit there terminates live sessions, and it presents as
"the workspace randomly disconnects" — you would not think to look at nginx.
See §15.

## Adding a service later

Drop one `conf.d/NN-<name>.conf` file, join `proxy-net`, reload. No existing
file is edited, which means adding a service cannot break an unrelated one.
The only global check is that the new path does not collide with `/webrdp` or
`/monitoring` (§15 documents why Kasm cares).

---

# 8. DNS and TLS

## 8a. No domain yet — build on Tailscale first (D-010)

The domain will be bought later. Rather than stalling, the entire stack is
built and validated on the tailnet first, then the public domain is added at
the end as one more nginx `server` block.

This host's MagicDNS name is **`onebox-prod.tailnet-example.ts.net`**, and Tailscale
issues **real, publicly-trusted Let's Encrypt certificates** for `*.ts.net`
names via `tailscale cert`. So this is not a self-signed workaround — it is
genuine TLS, with genuine certificate validation, which is what makes it a
valid rehearsal.

```bash
# Prerequisite: enable HTTPS Certificates once, in the Tailscale admin console
#   https://login.tailscale.com/admin/dns  →  HTTPS Certificates → Enable
# (currently OFF — `tailscale status --json` reports CertDomains: null)

tailscale cert \
  --cert-file /opt/server/proxy-nginx/certs/ts.crt \
  --key-file  /opt/server/proxy-nginx/certs/ts.key \
  onebox-prod.tailnet-example.ts.net
```

**Why this is worth doing rather than waiting:**

| Benefit | Detail |
|---|---|
| The two plan-killing risks resolve early | R1 (Kasm resources) and R2 (arm64 workspace images) are found before a domain is bought, not after |
| Real TLS, real subpath behaviour | Kasm's `/webrdp/` proxying, WebSockets, secure cookies, and asset paths all behave as they will in production |
| Zero public exposure during the risky part | Nothing is internet-reachable while Kasm is being wrung out |
| No Let's Encrypt rate-limit burn | Tailscale's issuance is separate from the domain's future quota |
| The domain becomes additive | Adding it is a new `server` block plus a certbot cert — not a redesign |

**What it cannot validate**, and must be re-tested after the domain lands:
public DNS resolution, the `www` → apex redirect, certbot's `http-01` webroot
flow, HSTS behaviour on the real origin, and the external uptime monitor (§H).
These are exactly the items Phase 11 covers.

Renewal is handled by `tailscale cert` re-running on a timer; the cert is valid
90 days like any other Let's Encrypt certificate.

## 8b. Public DNS — once the domain is bought

| Record | Type | Value | TTL |
|---|---|---|---|
| `DOMAIN` | A | `203.0.113.10` | 300 during setup, 3600 after |
| `www.DOMAIN` | A | `203.0.113.10` | 300 → 3600 |

No AAAA records — this instance has no public IPv6. **Do not add AAAA
speculatively:** a published AAAA that does not answer produces a hard-to-debug
partial outage for IPv6-first clients, since browsers prefer AAAA.

No `kasm.DOMAIN`. Path-based routing is the architecture (§15).

Low TTL during setup so a mistake is 5 minutes to fix, not an hour. Raise it
once stable.

## Canonicalisation

`www` → apex, 301. One canonical origin avoids duplicate cookie scopes and
duplicate certificates, and it matters for Kasm: WebAuthn (if ever enabled) is
origin-bound, so two live origins would mean two enrolments.

## TLS

- **Let's Encrypt**, `http-01` via webroot. DNS-01 would avoid opening 80 but
  needs registrar API credentials on the box — more secrets, more blast radius,
  for no gain here.
- **Certbot in a container**, sharing a webroot volume with nginx and a certs
  volume. Keeps the host free of Python dependencies.
- **TLS 1.2 + 1.3 only.** TLS 1.0/1.1 are dead; 1.2 stays for older clients.
- Ciphers: Mozilla **Intermediate**. Modern-only (1.3 exclusively) would be
  cleaner but risks locking out an older client on the one day you need access.
- OCSP stapling on. `ssl_session_cache shared:SSL:10m`.

```nginx
# snippets/ssl.conf
ssl_protocols TLSv1.2 TLSv1.3;
ssl_prefer_server_ciphers off;          # let TLS1.3 clients choose
ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:...;
ssl_session_timeout 1d;
ssl_session_cache shared:SSL:10m;
ssl_session_tickets off;                 # forward secrecy
ssl_stapling on;
ssl_stapling_verify on;
```

## Issuance order — this order matters

1. DNS resolves to the right IP. Verify: `dig +short DOMAIN`.
2. OCI ingress 80/443 open.
3. nginx serving **HTTP only**, with `/.well-known/acme-challenge/` mapped.
4. **Staging certificate first.** Let's Encrypt production limits are 5 failed
   validations per account per hostname per hour, and 50 certs per domain per
   week. A misconfigured webroot burns through those fast and locks you out for
   a week. Staging is free to fail against.
5. Confirm the staging cert issues; only then request production.
6. Enable HTTPS, then the redirect, then HSTS — **in that order**. Enabling
   HSTS before HTTPS works pins browsers to a broken site.

## Renewal

Certbot container runs `renew` twice daily (the standard jittered schedule),
reloading nginx via a deploy hook. Renewal starts at 30 days remaining, so
there are ~30 days of retries before anything expires.

**Renewal failure is monitored, not hoped for** — see §11. A silent renewal
failure that surfaces as a browser error 30 days later is the classic version
of this outage.

---

# 9. Test Website

Purpose: prove `DNS → TLS → nginx → Docker network → application`. It is
scaffolding, deliberately disposable. The real portfolio is out of scope.

- **Node 22 LTS alpine** (arm64 verified), not Bun. Bun is excellent but this
  needs to be boring — its job is to be the component that is definitely not
  the problem when something else breaks.
- Single file, zero dependencies, no framework, no database.
- Two routes: `/` renders a status page; `/healthz` returns JSON.
- Logs in the canonical format (rule 10) — it doubles as the reference
  implementation for future services.

```js
// src/server.js — no dependencies, ~40 lines
const http = require('http');
const START = Date.now();

const log = (event, extra = {}) => console.log(JSON.stringify({
  ts: new Date().toISOString(), level: 'info', service: 'test-website',
  env: 'vps-prod', host: process.env.HOSTNAME, event, outcome: 'success', ...extra,
}));

http.createServer((req, res) => {
  const t0 = process.hrtime.bigint();
  const rid = req.headers['x-request-id'] || '-';
  if (req.url === '/healthz') {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ status: 'ok', uptime_s: Math.floor((Date.now() - START) / 1000) }));
  } else {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(page());
  }
  log('http.request', {
    request_id: rid, target: req.url, status: res.statusCode,
    duration_ms: Number((process.hrtime.bigint() - t0) / 1000000n),
    msg: 'served',
  });
}).listen(3000, () => log('service.start', { msg: 'listening on 3000' }));
```

The page shows: nginx reverse proxy OK, HTTPS OK, Docker networking OK,
container OK, plus hostname, uptime, and the `X-Request-Id` it received — that
last one proves request-ID propagation end to end, which is otherwise annoying
to verify.

**Container:** non-root user, `read_only: true`, `tmpfs: /tmp`, all capabilities
dropped, `no-new-privileges`. Nothing to write means nothing to persist means
nothing to back up.

Healthcheck hits `/healthz` and parses it — not a `pgrep`.

Future direction (**not now**): Astro + TypeScript + Tailwind + MDX, built to
static output and served by this same nginx. Recorded so the decision is not
relitigated; explicitly out of scope for this plan.

---

# 10. Monitoring Architecture

Prometheus + Grafana + Alertmanager + node_exporter. Nothing else on day one.

No Loki, no Tempo, no OTel collector, no Elasticsearch. On 2 vCPU shared with
Kasm, a log-aggregation stack would consume more than it returns. Rule 10's log
format is chosen so that adding a shipper later is a *collection* change, not a
rewrite of every emitter — which is the only reason to standardise this early.

## node_exporter runs on the host, not in a container

Containerising it requires bind-mounting `/proc`, `/sys`, and `/` — and even
then some metrics are wrong, because it sees the container's namespaces. You
end up with a container that has near-host visibility (a security concession)
and still reports host metrics incorrectly (the thing you wanted). A systemd
unit avoids both.

```ini
# /etc/systemd/system/node_exporter.service
[Service]
User=node_exporter
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=127.0.0.1:9100 \
  --collector.systemd \
  --no-collector.wifi --no-collector.infiniband --no-collector.nfs
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
```

**Binding to `127.0.0.1` alone would make it unreachable from Prometheus's
container.** Prometheus reaches it via the Docker bridge gateway
(`172.17.0.1:9100`) — so node_exporter binds to the bridge gateway address as
well, and iptables rejects 9100 from anywhere off-host. It is never on
`0.0.0.0`.

Collectors are trimmed: `wifi`, `infiniband`, and `nfs` produce nothing useful
on a cloud VM and cost scrape time on a small box.

## Retention: 15 days

**Decision: 15 days**, not 30.

Reasoning: at a 15 s scrape interval across ~6 targets this is roughly
100–150 K active series, landing around 1.5–2.5 GB for 15 days. The brief
itself says configuration matters more than historical metrics, and the honest
use for this data is "what happened this week" — a capacity trend over a
quarter is not a question this server will be asked. 15 days halves both disk
and the memory Prometheus uses for its head block, on a box where Kasm is
already contending for RAM.

Revisit if a real need for longer history appears; extending retention is a
config change, and the data starts accumulating from that moment.

## Metrics flow

```text
node_exporter ─┐
prometheus ────┤
grafana ───────┼──► Prometheus ──► rules eval ──► Alertmanager ──► Brevo ──► email
alertmanager ──┤       │
nginx ─────────┘       └──► Grafana (query)
```

---

# 11. Prometheus Design

Image: `prom/prometheus` pinned (arm64 verified).

## Scrape configuration

```yaml
global:
  scrape_interval:     15s
  scrape_timeout:      10s
  evaluation_interval: 15s
  external_labels:
    env:      vps-prod
    instance: onebox-prod

scrape_configs:
  - job_name: prometheus
    static_configs: [{ targets: ['prometheus:9090'], labels: { service: prometheus } }]

  - job_name: node
    static_configs: [{ targets: ['172.17.0.1:9100'], labels: { service: host } }]

  - job_name: grafana
    metrics_path: /metrics
    static_configs: [{ targets: ['grafana:3000'], labels: { service: grafana } }]

  - job_name: alertmanager
    static_configs: [{ targets: ['alertmanager:9093'], labels: { service: alertmanager } }]

  - job_name: nginx
    static_configs: [{ targets: ['nginx:8080'], labels: { service: nginx } }]
```

15 s is kept: it is fine at this target count, and it makes the 10-minute
sustained-condition alerts meaningful (40 samples, not 4).

**Nginx metrics:** the stock image has only `stub_status` (7 numbers). Options:
expose `stub_status` on an internal-only port and add `nginx-prometheus-exporter`,
or skip it. Recommendation: **expose `stub_status` and add the exporter** — it
is ~15 MB and gives connection and request-rate data that makes the Grafana
service panel actually useful. Verify arm64 first.

**Kasm metrics:** determine at Phase 7a whether the release exposes anything
Prometheus-compatible. If not, **do not build a bespoke exporter** — use
container health plus an availability probe (below).

## Availability probing without blackbox_exporter

Rather than adding another container, availability is derived from `up{}` for
scraped targets, plus a lightweight external check (§37). For Kasm's public
path specifically, a small cron-driven curl writing a textfile that
node_exporter's `textfile` collector reads is cheaper than a blackbox_exporter
and adequate at this scale.

## Labels — keeping cardinality flat

| Label | Source | Values |
|---|---|---|
| `job` | scrape config | ~6, fixed |
| `instance` | target | ~6, fixed |
| `service` | static label | fixed set |
| `env` | `external_labels` | one |

**Forbidden as labels:** request paths, user IDs, session IDs, container IDs,
workspace IDs, timestamps, anything unbounded. Each distinct label combination
is a separate time series held in memory; a single unbounded label is how a
1 GB Prometheus becomes a 6 GB Prometheus and gets OOM-killed. On this box that
would also take monitoring down precisely when it is needed.

Relabelling drops noisy Go runtime metrics we will not look at.

## Alert rules

Thresholds are adjusted from the brief where the brief's values would misfire
on this specific host.

```yaml
groups:
- name: host
  rules:
  - alert: HostCPUSaturated
    expr: 100 - (avg by(instance)(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100) > 90
    for: 15m
    labels: { severity: warning }
```

**Changed from the brief's `>95% for 10m`.** On 2 vCPU, a single Kasm workspace
can legitimately sit at 95% for ten minutes — that is the machine working, not
failing. 90% for 15 minutes is a better signal of a genuine runaway, and the
load alert below catches the case that actually hurts.

```yaml
  - alert: HostLoadHigh
    expr: node_load5 / count(count by(cpu)(node_cpu_seconds_total)) > 2
    for: 15m
    labels: { severity: warning }
```

Load per core > 2 sustained means work is queueing, which is what users feel.

```yaml
  - alert: HostMemoryPressure
    expr: (1 - node_memory_MemAvailable_bytes / node_memory_MemTotal_bytes) * 100 > 85
    for: 10m
    labels: { severity: warning }

  - alert: HostSwapInUse
    expr: node_memory_SwapFree_bytes / node_memory_SwapTotal_bytes < 0.5
    for: 10m
    labels: { severity: warning }
```

**New alert, and an important one.** Swap exists as a grace period (D-008). Swap
being *used* means the grace period is being consumed — the early warning that
the §22 budget is wrong. Without this the swap silently absorbs a problem until
it cannot.

`MemAvailable` is used rather than `MemFree` because page cache is reclaimable;
alerting on `MemFree` on a box with 6 GB of cache would fire constantly.

```yaml
  - alert: DiskSpaceLow
    expr: node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes < 0.15
    for: 10m
    labels: { severity: warning }

  - alert: DiskSpaceCritical
    expr: node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"} / node_filesystem_size_bytes < 0.05
    for: 5m
    labels: { severity: critical }

  - alert: DiskWillFillIn24h
    expr: predict_linear(node_filesystem_avail_bytes{fstype!~"tmpfs|overlay"}[6h], 24*3600) < 0
    for: 30m
    labels: { severity: warning }
```

`predict_linear` is worth more than either threshold: it catches a runaway log
at 40% used, while a static 85% alert only fires when you have hours left.

```yaml
  - alert: FilesystemReadOnly
    expr: node_filesystem_readonly{fstype!~"tmpfs"} == 1
    for: 1m
    labels: { severity: critical }

  - alert: HostOOMKill
    expr: increase(node_vmstat_oom_kill[10m]) > 0
    labels: { severity: critical }
```

The OOM alert is the §22 canary. If it fires, the resource budget is wrong —
and the alert must reach you even though the thing that OOM'd might be
Prometheus itself, which is why external monitoring (§37) exists.

```yaml
- name: availability
  rules:
  - alert: TargetDown
    expr: up == 0
    for: 3m
    labels: { severity: critical }

  - alert: CertificateExpiringSoon
    expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 21
    labels: { severity: warning }

  - alert: CertificateExpiringCritical
    expr: (probe_ssl_earliest_cert_expiry - time()) / 86400 < 10
    labels: { severity: critical }
```

**Changed from the brief's 14/7 days to 21/10.** Let's Encrypt begins renewing
at 30 days. A warning at 14 means renewal has already failed silently for 16
days; at 21 you get 9 days of daily nudges before it is urgent. 10 days for
critical still leaves room to fix it by hand and reissue.

```yaml
  - alert: CertificateRenewalStale
    expr: time() - certbot_last_success_timestamp > 86400 * 10
    labels: { severity: warning }
```

Catches the renewal *process* dying rather than the certificate expiring —
detects the failure ~20 days earlier than expiry-based alerting. Fed by the
certbot deploy hook writing a node_exporter textfile.

`promtool check config` and `promtool check rules` must pass before deploy.
Every alert is tested by forcing its condition at least once (§31) — an alert
that has never fired is an untested alert.

---

# 12. Grafana Design

Served at `https://DOMAIN/monitoring/`.

## Subpath configuration

```ini
[server]
root_url = https://DOMAIN/monitoring/
serve_from_sub_path = true
[security]
cookie_secure       = true
cookie_samesite     = lax
disable_gravatar    = true
[users]
allow_sign_up = false
[auth.anonymous]
enabled = false
```

`serve_from_sub_path = true` is the setting people miss — without it Grafana
generates absolute URLs at `/` and the UI half-works in a way that looks like a
proxy bug. `cookie_samesite = lax` rather than `strict` because `strict` breaks
the login redirect flow.

Admin password from `.env` (`GF_SECURITY_ADMIN_PASSWORD`), never in the
compose file. No port published; `proxy-net` + `backend-net` only.

## Dashboard — one, provisioned as code

Provisioned via `provisioning/dashboards/`, JSON in git. No hand-editing in the
UI — an unprovisioned dashboard is lost on container replacement, and this
project's whole premise is reproducibility.

One dashboard, three rows, ~14 panels:

| Row | Panels |
|---|---|
| **Host health** | CPU %, memory (used/available/**swap**), load per core, disk usage per FS, filesystem free trend, network RX/TX, uptime |
| **Service health** | `up{}` status grid — nginx, Prometheus, Grafana, Alertmanager, node, Kasm; container restart counts |
| **Performance** | CPU trend 24 h, memory trend 24 h, nginx request rate + status classes, disk I/O |

Deliberately not a 200-panel import. A dashboard you actually read beats a
dashboard that impresses.

The **Kasm Health** section (§15) is added at Phase 7j, once we know what Kasm
actually exposes.

---

# 13. Alertmanager Design

Central notification router. Applications never send their own alerts —
one place to change routing, one place to silence during maintenance.

```yaml
global:
  resolve_timeout: 5m

route:
  receiver: email-default
  group_by: ['alertname', 'severity']
  group_wait:      30s      # collect related alerts before first send
  group_interval:  5m       # batch new alerts into an existing group
  repeat_interval: 12h      # re-nag on a still-firing alert
  routes:
    - matchers: [ severity="critical" ]
      receiver: email-critical
      group_wait: 10s
      repeat_interval: 4h

inhibit_rules:
  # A dead host should not also page about its disk.
  - source_matchers: [ alertname="TargetDown", severity="critical" ]
    target_matchers: [ severity="warning" ]
    equal: ['instance']
  # Critical disk supersedes the warning for the same filesystem.
  - source_matchers: [ alertname="DiskSpaceCritical" ]
    target_matchers: [ alertname="DiskSpaceLow" ]
    equal: ['instance', 'mountpoint']

receivers:
  - name: email-default
    email_configs: [{ to: '<RECIPIENT>', send_resolved: true, ... }]
  - name: email-critical
    email_configs: [{ to: '<RECIPIENT>', send_resolved: true, ... }]
```

**Timing rationale.** `group_wait: 30s` means a cascade (host down → five
targets down) arrives as one email, not five. `repeat_interval: 12h` for
warnings and `4h` for critical is a deliberate anti-fatigue choice: an alert
that repeats hourly gets filtered by you within a week, and then it is worse
than no alert at all.

`send_resolved: true` throughout — knowing a problem cleared is half the value.

Inhibition matters here more than usual: on a single node, one failure produces
a lot of correlated alerts, and a wall of email during an incident is actively
harmful.

**Silences** are documented in the runbook. Every planned maintenance starts
with `amtool silence add` — otherwise you train yourself to ignore alerts
during exactly the window when something might genuinely break.

---

# 14. Brevo Integration

```text
Prometheus → Alertmanager → Brevo → email
```

## Transport: SMTP relay, not the REST API

Alertmanager speaks SMTP natively. Using Brevo's REST API would require a
webhook receiver — an extra container, an extra failure mode, and custom code
in the alerting path. The alerting path is the last thing that should have
bespoke code in it.

```yaml
global:
  smtp_smarthost:     'smtp-relay.brevo.com:587'
  smtp_from:          '<SENDER>'
  smtp_auth_username: '<BREVO_SMTP_LOGIN>'
  smtp_auth_password_file: '/run/secrets/brevo_smtp_key'
  smtp_require_tls: true
```

`smtp_auth_password_file` rather than an inline value — Alertmanager's config
is world-readable inside the container, and a password in it lands in
`docker inspect` output too.

## Secrets

| Variable | Where |
|---|---|
| `BREVO_SMTP_KEY` | `monitoring/.env`, `chmod 600`, gitignored |
| `BREVO_SMTP_LOGIN` | same |
| `ALERT_SENDER` | same |
| `ALERT_RECIPIENT` | same |

`.env.example` commits every key with blank values. Real values never enter
git — and if one ever does, it gets **rotated**, not deleted (rule 30).

## Deliverability — the part people skip

Alert email that lands in spam is worse than no alert, because you believe you
are covered:

- Verify the sender domain in Brevo (**SPF + DKIM**). An unverified sender is
  the single most likely reason alerts silently vanish.
- Send a test alert and confirm it reaches the inbox, not the spam folder.
- Prefer a recipient on a different provider than the sending domain.
- **The recipient must not be an address only reachable through this server.**

## Failure mode

If Brevo is down or the key is wrong, Alertmanager logs the failure and drops
the notification — Prometheus still shows the alert firing, but nobody is told.
Mitigations: alert on `alertmanager_notifications_failed_total` increasing
(Alertmanager scraped by Prometheus), and the external monitor in §37 as the
independent path. **Test the whole chain quarterly** with a deliberate alert;
a notification path is only known-good on the day you last tested it.

---

# 15. Kasm Architecture

Replaces Apache Guacamole (D-006). Canonical public URL:
**`https://DOMAIN/webrdp/`** — path-based, not `kasm.DOMAIN`.

## 15a. Verified facts

Checked against current Kasm documentation, not assumed:

| Question | Answer | Consequence |
|---|---|---|
| Path-based reverse proxy? | **Supported** — subdomain *or* path | Architecture is viable |
| arm64? | **Yes** for services; **not all workspace images** | The real risk (§35) |
| Ubuntu 24.04? | Supported | Fine |
| Community Edition? | Free non-commercial, **5 concurrent sessions**, community support | Fits the use case; re-verify EULA at 7a |
| Docker Compose ≥ 2.1.1? | We have v5.4.0 | Fine |
| Services minimum | **2 cores / 4 GB / 50 GB SSD** | Entire machine (§22) |
| Default session | **2768 MB + 2 cores** | Must be reduced (§22) |
| Swap | "strongly recommended" | Done — D-008 |

## 15b. Subpath configuration — both halves are required

An nginx `location` block alone is **not sufficient**. Kasm must be told it
lives under a path, or it generates absolute URLs at `/` and the login page
loads without CSS.

**Kasm side** (Zone settings — verify field names against the installed build):

| Setting | Value |
|---|---|
| Proxy Path | `/webrdp` — leading slash, **no** trailing slash |
| Proxy Port | `0` (automatic port detection) |
| Upstream Auth Address | IP/FQDN pointing directly at the upstream server |

**Documented constraint: proxy paths must not overlap.** `/webrdp` coexists
with `/monitoring` fine, but a future `/web` or `/webrdp-test` would collide.
Recorded in §33 so nobody adds a colliding route in six months.

**Nginx side** (`conf.d/40-kasm.conf`):

```nginx
# --- session + websocket traffic: long timeouts, NO rate limit ---
location /webrdp/ {
    proxy_pass https://kasm-proxy:8443/;      # trailing slash strips /webrdp

    proxy_http_version 1.1;
    proxy_set_header Upgrade           $http_upgrade;
    proxy_set_header Connection        "upgrade";
    proxy_set_header Host              $host;
    proxy_set_header X-Real-IP         $remote_addr;
    proxy_set_header X-Forwarded-For   $proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto $scheme;
    proxy_set_header X-Forwarded-Port  443;
    proxy_set_header X-Request-Id      $request_id;

    proxy_read_timeout    1800s;
    proxy_send_timeout    1800s;
    proxy_connect_timeout 60s;
    proxy_buffering       off;
    client_max_body_size  512m;               # file transfer — see below

    proxy_ssl_verify off;                      # Kasm's internal self-signed cert
    include snippets/headers-kasm.conf;
    limit_conn perip 20;
}

# --- authentication endpoints: strict rate limit ---
location ~ ^/webrdp/api/(public/)?(authenticate|login) {
    limit_req zone=auth burst=5 nodelay;
    proxy_pass https://kasm-proxy:8443;
    include snippets/proxy-common-kasm.conf;
}
```

Five things that will bite, in the order they usually do:

1. **The trailing slash on `proxy_pass` is load-bearing.** With it, `/webrdp/x`
   becomes `/x` upstream. Without it, `/webrdp/x` stays `/webrdp/x` and Kasm
   404s every asset. This is the classic subpath failure.
2. **Rate limiting must be split.** A single `limit_req` across `/webrdp/`
   kills live sessions, and it presents as "the workspace randomly
   disconnects". The exact auth path regex must be derived from the installed
   Kasm build, not guessed from this document.
3. **`proxy_buffering off`** — buffering breaks interactive streams.
4. **`client_max_body_size`** must match the intended upload size *and* any
   Kasm-side limit. Mismatched limits produce a 413 that looks like a Kasm bug.
5. **`proxy_ssl_verify off`** is acceptable only because the hop is inside the
   Docker network to a known container. Document it; do not let it spread.

## 15c. Escalation rule

If the pinned Kasm version turns out to have a documented limitation preventing
reliable operation under `/webrdp/`: **stop and report it.** Do not silently
switch to a subdomain, and do not add a second public URL. The path-based
architecture is a requirement, not a preference.

## 15d. Installer ownership (O-009)

Kasm installs via its own script and generates its own compose file and
directory tree under `/opt/kasm`. That sits awkwardly with "rebuildable from
git". Resolution:

- `kasm/INSTALLER-OWNED.md` lists every path Kasm owns. We do not edit those.
- `kasm/compose.pinned.yml` is the installer's output, committed and
  version-pinned, so a rebuild is reproducible.
- `kasm/conf/` holds only our overrides.
- `kasm/notes/` records zone settings, the MFA runbook, and measurements —
  because zone configuration lives in Kasm's **database**, not in a file, and is
  therefore invisible to git. This is the gap; the database backup (§25) is what
  actually protects it.
- Before any Kasm upgrade: dump the database, diff the generated compose
  against ours, and re-verify the zone settings afterwards. Upgrades are the
  most likely way `/webrdp` silently reverts.

## 15e. Networking and exposure

Only **one** Kasm component joins `proxy-net`: its proxy listener (`:8443`).
Everything else stays on Kasm's internal network.

Kasm's installer publishes its proxy on the host by default. **This must be
changed or firewalled.** Verify after install:

```bash
ss -tulpn | grep -vE '127\.0\.0\.1|\[::1\]'
docker ps --format '{{.Names}}\t{{.Ports}}'
```

Any non-loopback Kasm listener is a **defect that blocks the phase**, not a
note for later.

## 15f. Health and monitoring

Container health must prove the service *serves*. But note clearly: **a green
container status does not prove `Kasm → WebSocket → workspace` works through
nginx.** Interactive launch stays a manual test (§31).

At 7a, determine whether the release exposes Prometheus-compatible metrics. If
yes, scrape it. If not, **do not build a bespoke exporter** — use container
health, restart counts, cgroup resource metrics, and the `/webrdp/` availability
probe from §11.

Grafana gains a **Kasm Health** row at 7j: service up/down, container restarts,
CPU/memory per component, active workspace count.

---

# 16. MFA Design

Kasm is remote access to this server. Username + password is not acceptable.

**Required: username + strong password + MFA.**

## Method

**TOTP is the baseline**, if available in the selected CE release. Verify at
7a — including the exact setting name for *mandatory* 2FA. Where Kasm supports
group-level enforcement, enforce on the group containing the administrator.

**WebAuthn / passkeys are a future enhancement, not day one.** A flaky second
factor on the only remote-access path is an outage waiting to happen. Note also
that WebAuthn is origin-bound: under path-based routing the origin is
`https://DOMAIN`, which is another reason §8 canonicalises to a single origin.

## Recovery — designed before enforcement, not after

This is where MFA deployments go wrong. The order below is not negotiable:

1. Create a **second administrator account** with independently enrolled MFA.
2. Verify an **out-of-band reset path** — SSH to the host, reset MFA via
   Kasm's CLI or directly in its database. Verify it works.
3. Store recovery codes **encrypted, off this server**. Codes stored on the box
   are useless in the scenario where you cannot log into the box.
4. **Only then** enforce mandatory MFA.
5. Re-test the recovery path quarterly; record the date in
   `docs/context/DECISIONS.md`.

Recovery must not depend solely on the Kasm web UI (unreachable if MFA is what
broke), a single TOTP device, or a credential stored only on the VPS.

The fallback beneath all of this is Tailscale SSH to the host, and beneath that
the OCI serial console. Both are independent of Kasm — which is the entire
reason §3 keeps the admin path separate from the service path.

---

# 17. SSH and RDP Security

## SSH — better than the brief assumed

Discovery found SSH already substantially hardened, and **reached over
Tailscale** (`100.64.0.20 → 100.64.0.10:22`), not the public IP.

| Setting | Current | Target | Risk |
|---|---|---|---|
| `passwordauthentication` | **no** | no | — already correct |
| `pubkeyauthentication` | yes | yes | — |
| `allowusers` | `prodadmin ubuntu` | `prodadmin` | Low |
| `permitrootlogin` | **`without-password`** | **`no`** | Medium |
| `x11forwarding` | **yes** | **no** | Low |
| `maxauthtries` | 6 | 3 | Low |
| `port` | 22 | 22 | Moving it is theatre; leave it |

The heavy lifting — disabling password auth — is already done. What remains is
tightening, and all of it is lockout-capable, so it follows the migration
procedure below regardless of how small it looks.

### The `198.51.100.23` login — resolved

`last` showed the `ubuntu` account logging in from a public address on
2026-08-15. **Explained by the user:** port 22 was used during initial
provisioning, before Tailscale was set up. The NSG ingress rules have since
been removed, and both SSH and RDP now go over Tailscale from the laptop.

Confirmed by the live sessions: `100.64.0.10:22 ← 100.64.0.20`. T1 (SSH
brute force) is therefore near-eliminated — there is no internet-facing SSH.

The `ubuntu` account is a provisioning artefact and should be dropped from
`allowusers` once you confirm nothing else uses it.

### Migration procedure — every SSH change, without exception

```text
1. Open a SECOND SSH session. Leave it idle and connected.
2. Back up:  sudo cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak-$(date -u +%Y%m%dT%H%M%SZ)
3. Edit.
4. sudo sshd -t          <- MUST pass. A syntax error here plus a restart = lockout.
5. sudo systemctl reload ssh    (reload, NOT restart — reload keeps existing sessions)
6. Open a THIRD session and verify login works.
7. Only now close anything.
```

If step 6 fails, session 1 is still alive to revert. This is why `restart` is
forbidden here — it drops your existing sessions, removing the safety net at
the exact moment you need it.

Recovery floor if all SSH access is lost: the **OCI serial console**. Confirm
you can reach it *before* touching sshd — knowing the recovery path exists is
not the same as knowing it works.

## Tailscale as the admin path (O-002)

Recommendation: **keep SSH on Tailscale only, and never open 22 at OCI.**

Benefits: no internet-facing SSH surface, most of the fail2ban SSH burden
disappears, and device-level auth sits in front of key auth.

Risk: if Tailscale breaks, admin access depends on the OCI console. That is an
acceptable trade given the console exists — but verify the console works first.

Also consider Tailscale ACLs restricting which peers may reach `:22`, so a
compromised phone on the tailnet is not automatically an admin.

## RDP (O-003)

**Never expose 3389.** Required topology:

```text
Internet → 443 → nginx → Kasm → workspace → RDP over tailscale0 → your-laptop
```

If `your-laptop` (`100.64.0.20`) is the intended target, connectivity is
already solved — the workspace reaches it over Tailscale, and RDP stays off the
internet entirely. To confirm and design:

- How the workspace container reaches `tailscale0`. Host networking is
  undesirable (§21); determine the least-privilege option — likely a userspace
  Tailscale sidecar or an explicitly routed bridge.
- Tailscale ACLs limiting which nodes and ports the workspace may reach.
- The target's RDP bound to its Tailscale interface, not `0.0.0.0`.
- What happens to remote access when Tailscale is down.

**This host's own `xrdp`** (port 3389, active + enabled, with a live-only
firewall ACCEPT) has no role in this architecture. Disable it in Phase 1
alongside `rpcbind` and `iperf3`.

---

# 18. Fail2ban Design

Already installed, running, enabled — **one jail: `sshd`**. Extend it; do not
reinstall.

## Jails

| Jail | Status | Notes |
|---|---|---|
| `sshd` | Exists | Keep. Largely redundant once SSH is Tailscale-only, but harmless and free. |
| `nginx-http-auth` | Add, Phase 3 | Standard, reliable. |
| `nginx-botsearch` | Add, Phase 3 | Probes for `/wp-admin` etc. Low false-positive rate. |
| `nginx-limit-req` | Add, Phase 3 | Bans IPs repeatedly tripping `limit_req` — pairs directly with §7. |
| **Kasm** | **Investigate only** | See below. |

Suggested values: `maxretry 5`, `findtime 10m`, `bantime 1h`, escalating to 24 h
for repeat offenders via `recidive`. Deliberately mild — the goal is shedding
noise, not perfect defence. MFA and rate limiting are the actual controls.

**Do not ban on every 401/403.** A mistyped password is a 401. Banning on it
locks out the legitimate user far more often than an attacker.

## The Kasm jail — probably not worth building

Investigate at 7a, and be willing to conclude "no":

1. Where does Kasm log auth failures, and in what format?
2. Are those logs reachable from Fail2ban? They are inside containers.
3. **Can a real client IP be extracted?** This is the blocker. Behind nginx,
   Kasm sees the proxy's IP. If the log does not carry `X-Forwarded-For`, every
   ban targets nginx and **locks out every user**.
4. Does Kasm already have built-in brute-force protection?

**A Fail2ban rule that mis-parses an IP is worse than no rule.** If a reliable
client IP cannot be extracted, ban at the nginx layer instead
(`nginx-limit-req` on the auth location), where the real IP is known for
certain.

## Docker logging interaction

Container logs go to Docker's `json-file` driver, not `/var/log`. Fail2ban
cannot read them directly. Options:

- **Preferred:** jail nginx's log, which is a bind-mounted file on the host and
  contains the real client IP. Covers the attack surface that matters.
- Alternative: switch specific services to the `journald` log driver and use
  Fail2ban's `systemd` backend. Adds moving parts.

Banning is done via iptables — which must be reconciled with §19's ruleset
so a `netfilter-persistent` reload does not wipe live bans (it will; that is
acceptable, bans are ephemeral by design).

## Testing

Every jail is tested by deliberately tripping it from a **Tailscale** address,
confirming the ban, then unbanning:

```bash
sudo fail2ban-client status <jail>
sudo fail2ban-client set <jail> unbanip <ip>
```

Never test from your only access path.

---

# 19. Firewall Design

## Decision: manage iptables directly. Do NOT enable UFW. (D-009 — **CONFIRMED**)

User confirmed 2026-08-16: UFW is not used at all on this host.

UFW is installed but **inactive**. The live filter is iptables restored by
`netfilter-persistent` from `/etc/iptables/rules.v4`, and it already implements
default-deny.

Enabling UFW would **flush and replace** that ruleset. First casualty: the SSH
ACCEPT rule we are connected through. Second: Oracle's `InstanceServices` chain
protecting the 169.254 metadata range, which Oracle's own comment warns against
removing.

Trade-off accepted: hand-edited rules are less friendly than `ufw allow`. But
they are honest about what is running, and they preserve Oracle's chain.

**This needs your confirmation before Phase 1.**

## Three layers

```text
1. OCI Security List   ingress: 80, 443 only        ← outermost
2. Host iptables       ACCEPT 80,443,22; REJECT     ← defence in depth
3. Docker DOCKER-USER  belt and braces              ← see the trap below
```

## Target INPUT chain — Phase 1

```
-P INPUT ACCEPT                                     # trailing REJECT makes this deny
-A INPUT -j ts-input                                # Tailscale
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -p tcp -m state --state NEW --dport 22 -j ACCEPT
                                                    # 3389 rule REMOVED
-A INPUT -j REJECT --reject-with icmp-host-prohibited
```

**Phase 1 only removes the stale 3389 rule.** Ports 80 and 443 are added in
**Phase 11**, at public launch — until then nginx binds to `tailscale0` and
there is nothing to allow.

Port 22 stays at the host level even though OCI blocks it: it is how
Tailscale-originated SSH arrives, and removing it would cut your access.

## Fixing the reproducibility gap

The 3389 ACCEPT rule exists **only in the live kernel table**; it is absent
from `/etc/iptables/rules.v4`. The user added it manually to test xrdp and it
was never persisted, so live and persisted state disagree — the firewall is
not currently reproducible.

```bash
# Phase 1 — with a second session open
sudo iptables-save > /etc/iptables/rules.v4.bak-$(date -u +%Y%m%dT%H%M%SZ)
sudo iptables -D INPUT -p tcp -m tcp --dport 3389 -j ACCEPT
sudo iptables -S INPUT                       # eyeball it
# verify SSH still works in a THIRD session, THEN persist:
sudo netfilter-persistent save
```

Because the rule was never persisted, a reboot alone would clear it — but
deleting it explicitly and re-saving makes live and persisted state agree,
which is the actual goal.

Confirm it does not return on boot (xrdp may re-add it) as part of the §31
reboot test. Disabling xrdp outright removes the question.

## Phase 11 addition

```bash
sudo iptables -I INPUT 5 -p tcp -m state --state NEW --dport 80  -j ACCEPT
sudo iptables -I INPUT 6 -p tcp -m state --state NEW --dport 443 -j ACCEPT
sudo netfilter-persistent save
```

Order matters: rules go in **before** the trailing REJECT, or they never match.
Persist only after verifying.

## The Docker/UFW trap — applies here too

Docker writes into the `DOCKER` chain, evaluated **before** the user chain.
Consequence: `ports: "9090:9090"` is reachable from the internet even with
default-deny, and the firewall will report it as blocked. **It is not.**

Mitigations, in order of preference:

1. **Do not publish the port.** Use `expose:`. This is the rule here — only
   nginx publishes anything.
2. If host-local publishing is genuinely needed: `127.0.0.1:9090:9090`.
3. `DOCKER-USER` rules as a last resort.

On this host OCI provides a second gate, so a mistake is survivable — but that
is luck, not design. `scripts/port-audit.sh` runs after every phase:

```bash
ss -tulpn | grep -vE '127\.0\.0\.1|\[::1\]'
docker ps --format '{{.Names}}\t{{.Ports}}'
sudo iptables -S DOCKER-USER
```

Diff against the previous run. **Any new non-loopback listener that was not
deliberately added is an incident.**

## Host services to disable (Phase 1)

```bash
sudo systemctl disable --now xrdp xrdp-sesman   # no role; §17
sudo systemctl disable --now rpcbind rpcbind.socket
# iperf3: find and stop; it is a leftover test tool
```

None are reachable today. Disabling them means a future OCI rule change cannot
silently expose something nobody remembered was running.

---

# 20. Host Hardening

Much is already done. This is a short list because discovery said so.

| Item | Status | Action |
|---|---|---|
| Automatic security updates | `unattended-upgrades` active | Verify origins; enable email on failure |
| Time sync | NTP active, UTC | None |
| Swap | 4 GiB, swappiness 10 | Done (D-008) |
| journald | Persistent (`/var/log/journal` exists) | **Bound it** — currently unlimited |
| auditd | Running, **zero rules** | **Load rules** (O-013) |
| Firewall | Default-deny | §19 |
| SSH | Mostly hardened | §17 |
| Unnecessary services | xrdp, rpcbind, iperf3 running | §19 |
| Docker daemon | No `daemon.json` | §5 |
| Kernel params | Defaults | Below |

## journald

```ini
# /etc/systemd/journald.conf
[Journal]
Storage=persistent
SystemMaxUse=2G
MaxRetentionSec=30day
Compress=yes
ForwardToSyslog=no
```

Persistent is already effective. Unbounded is the problem — the journal can
grow until `/` fills, which takes down sshd and Docker with it.

## auditd — currently producing nothing (O-013)

The daemon is up, so every naive health check passes, while `auditctl -l`
reports "No rules". There is no audit trail of identity changes, sudo, sshd
config, or unit files.

Narrow, defensible ruleset — broad syscall auditing would eat a 2-vCPU box:

```
# /etc/audit/rules.d/hardening.rules
-w /etc/passwd            -p wa -k identity
-w /etc/shadow            -p wa -k identity
-w /etc/group             -p wa -k identity
-w /etc/sudoers           -p wa -k privilege
-w /etc/sudoers.d/        -p wa -k privilege
-w /etc/ssh/sshd_config   -p wa -k sshd
-w /etc/systemd/system/   -p wa -k systemd
-w /etc/cron.d/           -p wa -k cron
-w /etc/crontab           -p wa -k cron
-w /opt/server/           -p wa -k infra-config
-w /var/run/docker.sock   -p rwxa -k docker-socket
-a always,exit -F arch=b64 -S execve -F euid=0 -F auid>=1000 -F auid!=-1 -k root-exec
-e 2
```

`-e 2` makes the ruleset immutable until reboot — an attacker with root cannot
quietly disable auditing without a reboot, which is itself a signal.

The `docker.sock` watch matters given §21: the socket is root-equivalent, and
any access to it should be attributable.

Retention: `max_log_file_action = keep_logs`, 90 days.

## Kernel parameters

```
# /etc/sysctl.d/99-hardening.conf
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.tcp_syncookies = 1
kernel.dmesg_restrict = 1
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
```

Deliberately not disabling IPv6 at the kernel level — Tailscale uses IPv6
internally. No public IPv6 exists, so there is nothing to protect there.

---

# 21. Docker Security

Practical, not maximal. Hardening that breaks the application gets removed at
3 a.m. and never comes back.

## Per-container baseline

```yaml
security_opt: [ "no-new-privileges:true" ]
cap_drop:     [ ALL ]
cap_add:      [ ]              # add back only what is proven necessary
read_only:    true
tmpfs:        [ /tmp ]
user:         "1000:1000"
```

| Service | Deviation | Why |
|---|---|---|
| nginx | `cap_add: NET_BIND_SERVICE`; writable `/var/cache/nginx`, `/var/run` | Binds 80/443; needs cache dirs. Alpine nginx runs workers as `nginx`. |
| Prometheus | `read_only: false` on its data volume | TSDB writes |
| Grafana | `read_only: false`; `user: "472"` | Grafana's fixed UID |
| Alertmanager | Baseline + egress | Needs Brevo |
| test-website | Full baseline | Nothing to write |
| **Kasm** | **See below** | Cannot take the baseline |

## Kasm — the trust boundary Guacamole did not have (O-010)

Kasm provisions workspace containers, so some component almost certainly needs
`/var/run/docker.sock`. **The Docker socket is root on the host** — anything
holding it can start a privileged container mounting `/`.

Required at 7a/7d:

1. Determine **exactly which** component needs the socket. Only that one gets it.
2. Confirm the socket is **never reachable from a workspace container**. A
   workspace is attacker-reachable by design; the socket inside one is game over.
3. Consider a socket proxy (`tecnativa/docker-socket-proxy` or similar)
   restricting the API surface to container create/start/stop, rather than
   handing over the raw socket. Verify arm64.
4. Audit the socket (§20 auditd rule) so access is attributable.
5. Document the residual risk explicitly. This is the largest single security
   concession in the design, and it should be a decision, not an accident.

Workspace containers additionally get: resource limits (§22), no host network,
no host filesystem mounts beyond what is required, and no route to
`backend-net`.

## Docker socket — general rule

**No service in this plan mounts the Docker socket except the specific Kasm
component that requires it.** No Portainer, no Watchtower, no auto-update
agents. Convenience tooling that holds the socket is a root shell with a web UI.

## Images

- Official and minimal where an arm64 build exists.
- Version-pinned; digest-pinned for internet-facing.
- Current pinned versions recorded in `docs/context/STATE.md`.
- No `latest`.

---

# 22. Resource Allocation

**The hardest constraint in this plan.** 2 vCPU, 11 GiB RAM, 4 GiB swap.

## Memory budget

| Component | Limit | Reservation | Expected | Purpose |
|---|---|---|---|---|
| Host OS, Docker daemon, tailscaled, sshd | — | — | ~1.0 G | Base |
| node_exporter (host) | — | — | ~30 M | Host metrics |
| nginx | 192 M | 64 M | ~40 M | Public gateway |
| test-website | 128 M | 32 M | ~50 M | Validation |
| **Prometheus** | 1.0 G | **768 M** | ~600 M | TSDB + head block |
| **Grafana** | 512 M | **256 M** | ~250 M | Dashboards |
| **Alertmanager** | 128 M | **96 M** | ~40 M | Routing |
| nginx-exporter | 64 M | 16 M | ~15 M | Optional |
| **Kasm services (all)** | **3.5 G** | 2.0 G | **MEASURE** | Platform |
| **Kasm workspace ×1** | **2.0 G** | 512 M | **MEASURE** | Session |
| | | | | |
| **Total limits** | **~7.5 G** | | | |
| **Expected steady** | | | **~4.1 G** | Without a workspace |
| **Expected with workspace** | | | **~6.5 G** | |
| **Available** | **11 GiB + 4 G swap** | | | |

Headroom at steady state is comfortable. With a workspace running it is ~4.5 G
— adequate, and the swap is genuine backstop rather than routine paging.

### Reservations are the important column

`limits` cap a container. **`reservations` tell the kernel what to protect.**
Prometheus, Grafana, and Alertmanager carry reservations at or near their
expected usage specifically so that under pressure the OOM killer prefers a
Kasm workspace. That is the entire §14-of-the-brief requirement, expressed as
configuration:

```text
Workspace launches → memory pressure → OOM killer picks the least-protected,
largest-RSS process → the workspace, not Prometheus.
```

Reinforce with `oom_score_adj: -500` on Prometheus and Alertmanager.

**This must be tested, not assumed** (§31): deliberately launch workspaces until
something is killed, and confirm the victim is the workspace.

### Kasm's default is rejected

Kasm ships workspaces at **2768 M and 2 cores**. Both are reduced:

- Memory to **2.0 G** — determine the true minimum for the chosen image at 7g.
- CPU to **1.0** — 2 cores is the entire machine; a workspace must not be able
  to starve nginx and Prometheus of scheduler time.
- **Concurrent sessions capped at 1.** CE allows 5; this hardware supports one
  interactive session. Cap it in Kasm rather than discovering it under load.

## CPU budget

| Component | Limit | Expected |
|---|---|---|
| nginx | 0.30 | ~0.02 |
| test-website | 0.15 | ~0.01 |
| Prometheus | 0.50 | ~0.10 |
| Grafana | 0.40 | ~0.05 |
| Alertmanager | 0.10 | ~0.01 |
| Kasm services | 0.75 | MEASURE |
| Kasm workspace | 1.00 | up to 1.00 |
| **Sum of limits** | **3.20** | of 2.00 available |

**CPU limits are deliberately oversubscribed, and that is correct.** They are
ceilings, not reservations. Reserving 2.0 of 2.0 vCPU would leave everything
idle-but-throttled. Oversubscription means idle services do not waste capacity,
while no single container can monopolise the box.

Honest consequence: with a workspace at full tilt, Grafana feels slow. That is
degradation, not failure — and memory reservations ensure it stays that way
rather than becoming an outage.

## Measurement protocol (Phase 7c, 7g)

Estimates above are inputs to a measurement, not conclusions.

```bash
# Steady state, everything but Kasm, 10 min
docker stats --no-stream --format \
  '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}'
free -h; swapon --show; uptime

# Kasm idle, then workspace launch (burst is what kills, not steady state)
# sample every 2s through the launch
while true; do date -u +%H:%M:%S; free -m | head -2; \
  docker stats --no-stream --format '{{.Name}} {{.MemUsage}}'; sleep 2; done
```

Record in `kasm/notes/measurements.md`. Set final limits from observed peak
**plus 30%**, never from steady state — launch burst is the risk.

## The stop condition

If measurement shows Kasm cannot coexist with monitoring on this host, **stop
and report the numbers.** Options to present:

1. Reduce the monitoring footprint (shorter retention, fewer panels).
2. Accept one workspace at a time with reduced allocation.
3. Resize the VPS.
4. Move Kasm to a different host and proxy to it over Tailscale.

Shipping something that OOMs under first real use is not on the list.

---

# 23. Logging

Full specification: `.claude/rules/10-logging-audit.md`. Summary of what gets
implemented.

## One canonical event

JSONL, one object per line, UTF-8. Required fields: `ts` (RFC 3339, **UTC**,
ms), `level`, `service`, `env`, `host`, `event` (`noun.verb`), `outcome`, `msg`.
Optional-when-applicable: `actor`, `source_ip`, `request_id`, `session_id`,
`target`, `status`, `duration_ms`, `reason`, `error`.

Additive only — never rename or repurpose a field. Flat, one level deep. `level`
is severity; `outcome` is result; they are not the same thing.

## Per producer

| Producer | Mechanism | Notes |
|---|---|---|
| nginx access | `log_format json_main escape=json` | `escape=json` mandatory — without it a crafted URL breaks the JSON |
| nginx error | plain text, `warn` | nginx cannot emit JSON here. **The one documented exception.** |
| test-website | native JSON | Reference implementation |
| Prometheus / Grafana / Alertmanager | native structured where supported | Do not fight their formats |
| Kasm | whatever it emits | Do not attempt to reshape it |
| Host | journald + auditd | §20 |
| Claude Code | `.claude/hooks/` → `docs/context/audit/*.jsonl` | Already live |

## Never logged

Passwords, API keys, session tokens, TOTP seeds, private keys, full
`Authorization`/`Cookie` headers, auth-endpoint request bodies. **Redact at the
emitter** — redaction after the write has already lost.

## Rotation and retention

| Stream | Bound |
|---|---|
| Docker containers | 10 M × 5 per service (daemon default + per-service) |
| journald | 2 G / 30 days |
| auditd | 90 days, `keep_logs` |
| nginx access/error | 14 days compressed, logrotate |
| Claude audit JSONL | Indefinite (small), in git |

Ceiling for container logs is ~500 MB across ~10 services — sane against a
48 G root disk, and moot once `data-root` moves to `/mnt/data`.

## Request tracing

`$request_id` generated at nginx → `X-Request-Id` downstream → returned to the
client. One ID ties a user report to nginx, the app, and the audit trail.
Demonstrated end to end by the test website (§9).

---

# 24. Health Checks

A healthcheck must prove the service **serves**. `pgrep` proves nothing — a
wedged process with an open socket passes it.

| Service | Check | Interval / timeout / retries / start_period |
|---|---|---|
| nginx | `wget -qO- http://localhost/healthz` | 30s / 5s / 3 / 10s |
| test-website | `wget -qO- http://localhost:3000/healthz` + JSON parse | 30s / 5s / 3 / 10s |
| Prometheus | `wget -qO- http://localhost:9090/-/healthy` | 30s / 5s / 3 / 30s |
| Grafana | `wget -qO- http://localhost:3000/api/health` | 30s / 5s / 3 / 60s |
| Alertmanager | `wget -qO- http://localhost:9093/-/healthy` | 30s / 5s / 3 / 20s |
| Kasm components | per Kasm docs, determined at 7a | — / — / — / **180s** |

`start_period` matters: Grafana takes ~30 s to become ready, and Kasm
considerably longer. Too short a start period produces restart loops on boot
that look like a crash.

**Explicitly acknowledged:** a healthy Kasm container does **not** prove
`Kasm → WebSocket → workspace` works through nginx. That is manual (§31).
Treating a green healthcheck as proof of that chain is the most likely way this
deployment gets declared "done" while broken.

## Restart policy

`restart: unless-stopped` everywhere. It survives daemon restarts and reboots,
but respects a deliberate `docker compose stop` — unlike `always`, which fights
you during maintenance.

Docker's exponential backoff (100 ms doubling to 1 min) prevents restart storms.
A container restarting repeatedly is caught by the restart-count check in §31
and by Grafana's service-health row.

---

# 25. Backup Strategy

## Classification

| Item | Class | Why |
|---|---|---|
| Git repo (all config) | **Critical** | The platform's source of truth |
| `.env` files | **Critical** | Not in git by design — backed up separately, encrypted |
| **Kasm database** | **Critical** | Users, groups, **MFA enrolments**, zone settings incl. `/webrdp` |
| Kasm custom config | Critical | Not reproducible from the installer |
| Grafana database | Critical | Dashboards are provisioned, but users/prefs/API keys are not |
| TLS certificates | Rebuildable | Reissue with certbot — faster and safer than restoring keys |
| Prometheus TSDB | **Rebuildable** | Metrics history is nice-to-have; alerting rules are in git |
| Workspace images | **Rebuildable** | Re-pull. Do **not** back these up — gigabytes for no value |
| Docker images | Rebuildable | Pinned tags/digests in git |

**The Kasm database is the crown jewel.** Zone configuration — including the
`/webrdp` proxy path this whole architecture depends on — lives in that
database, not in a file. Git cannot protect it. This backup is the only thing
that can, and it is also on the critical path for MFA recovery (§16).

## Schedule and retention

| What | Frequency | Retention | Destination |
|---|---|---|---|
| Kasm DB dump | Daily 03:00 UTC | 14 daily, 8 weekly | `/mnt/data/backups/` + off-site |
| Grafana DB | Daily | 14 daily | same |
| Config tarball | Daily | 14 daily | same |
| `.env` (encrypted) | On change | Keep 5 versions | Off-site **only** |
| Full weekly archive | Sunday 04:00 | 8 weeks | Off-site |

**Local plus off-site.** Local alone dies with the VPS — which is precisely the
scenario a backup exists for.

Off-site target: any S3-compatible object store or a second Tailscale node.
`restic` or `borg` for deduplication and encryption; either is fine, pick one
and stick to it.

## Encryption

Everything leaving the host is encrypted at rest. The passphrase is stored
somewhere the VPS dying does not take with it — **not** on the VPS, and not
only in a password manager that syncs through the VPS.

## Backup script requirements

- Consistent DB dumps (`pg_dump`, not a file copy of a running database).
- Canonical JSON log lines (`service: "backup"`, `event: "backup.complete"`).
- Non-zero exit on **any** failure, so a broken backup is loud.
- Write a node_exporter textfile metric with the last-success timestamp →
  alert if it goes stale. **A backup that stops silently is the default failure
  mode**; this is what catches it.
- Never log the encryption passphrase or DB credentials.

## Restore testing — non-negotiable

> A backup is not a backup until a restore has been tested.

| Test | Frequency | Method |
|---|---|---|
| Config restore | Monthly | Extract to a temp dir, diff against live |
| Kasm DB restore | **Before enforcing MFA**, then quarterly | Restore into a scratch Postgres, verify users + MFA rows present |
| Grafana DB restore | Quarterly | Same |
| Full rebuild | Once, before "production" | §26 |

`scripts/restore-test.sh` automates the first three and records results in
`docs/context/DECISIONS.md`. An untested restore is a hope.

---

# 26. Disaster Recovery

## Scenarios and RTO

| Scenario | Detection | Recovery | RTO |
|---|---|---|---|
| Container crash | Healthcheck + `TargetDown` | Auto-restart | < 1 min |
| Service misconfigured | Alert / manual | `git checkout <tag>` + `up -d` | < 10 min |
| Docker daemon dies | External monitor | `live-restore` keeps containers up | < 5 min |
| Disk full | `DiskWillFillIn24h` (24 h warning) | Prune logs/images | < 30 min |
| Kasm DB corrupted | Kasm unreachable | Restore latest dump | < 1 h |
| Host unbootable | External monitor | OCI console → rescue | 1–4 h |
| **VPS destroyed** | External monitor | Full rebuild | **4–8 h** |
| MFA lockout | Cannot log in | §16 out-of-band reset | < 30 min |
| Tailscale down | Cannot SSH | OCI serial console | < 15 min |

## Full rebuild procedure

```text
 1. Provision a new OCI instance — Ubuntu 24.04, aarch64, 2 vCPU / 12 GB
 2. Attach/recreate the data volume
 3. Install Docker; apply /etc/docker/daemon.json (data-root!)
 4. Create swap (D-008)
 5. Join Tailscale; verify SSH over it
 6. Apply firewall rules (§19); persist
 7. Harden sshd (§17), journald + auditd (§20)
 8. git clone <private repo> /opt/server
 9. Restore .env files from the encrypted off-site backup
10. docker network create proxy-net; docker network create --internal backend-net
11. Update DNS A records to the new IP  ← low TTL pays for itself here
12. Deploy nginx; issue certificates (STAGING first)
13. Deploy test-website; verify
14. Deploy monitoring; verify alerts fire
15. Install Kasm; restore its database; re-verify zone settings
16. Full acceptance run (§32)
```

Steps 1–10 are ~1 hour with practice. **Step 11 is the long pole** — DNS
propagation. This is the concrete reason §8 specifies a low TTL during
volatile periods.

**Do this once as a drill before declaring production.** A rebuild procedure
that has never been executed is fiction; the drill is what converts it into a
runbook.

## What is deliberately not recoverable

- Prometheus history before the incident — accepted (§25).
- Running Kasm sessions — inherent.
- Any secret that exists only on the box and only in someone's memory. Which is
  why §25 backs up `.env` separately and encrypted.

---

# 27. Update Strategy

## Per-project, never all at once

```text
1. Read the release notes. Actually read them — breaking changes hide there.
2. Verify the new tag has an arm64 manifest.
3. Back up (DB + config) BEFORE pulling.
4. Update the tag in the compose file; commit.
5. docker compose pull <service>
6. docker compose up -d <service>       ← one service
7. Healthcheck goes healthy
8. Endpoint responds correctly from outside
9. Logs clean for 5 minutes
10. Prometheus target up; no new alerts
11. Restart count stable after 10 minutes
12. Tag the commit
```

Roll back: `git checkout <previous-tag> -- <project>/ && docker compose up -d`.
Because the image tag lives in git, rollback is a checkout, not archaeology.

## Cadence

| Layer | Cadence | Notes |
|---|---|---|
| OS security patches | Automatic (`unattended-upgrades`) | Already on |
| Kernel | Manual, quarterly | Needs a reboot → §26 reboot test |
| nginx / Prometheus / Grafana / Alertmanager | Monthly review, patch versions promptly | Low risk |
| **Kasm** | **Deliberate, with a backup and a window** | Highest risk — see below |
| Docker engine | Quarterly | Uses `live-restore`; still verify |

## Kasm upgrades need special care

The installer owns its compose file and directory tree, and zone settings live
in its database. An upgrade can regenerate config and silently revert the
`/webrdp` proxy path — which would present as "Kasm broke" long after the
upgrade.

Every Kasm upgrade:

1. Full DB dump first, verified restorable.
2. Diff the newly generated compose against `kasm/compose.pinned.yml`.
3. **Re-verify zone settings after the upgrade** — Proxy Path, Proxy Port,
   upstream auth address.
4. Full §32 Kasm acceptance run, including an interactive session. Not just the
   login page.

Never update everything the same day. When two things change and something
breaks, you have doubled the search space for no benefit.

---

# 28. Failure Scenarios

| Failure | What breaks | Detection | Recovery |
|---|---|---|---|
| **nginx dies** | **Everything public** — all three routes | `TargetDown` (3 m); external monitor (~1 m). Internal alerting still works: Prometheus/Alertmanager/Brevo need only egress | `restart: unless-stopped`. If it crash-loops: `nginx -t`, check the last config commit |
| **Prometheus dies** | Alerting stops. **Nothing else notices** | `up{job="prometheus"}` cannot self-report → Grafana panel goes stale; external monitor is the real detector | Restart; check OOM (§22). If OOM, the budget is wrong — do not just raise the limit |
| **Grafana dies** | `/monitoring/` 502s. Alerting **unaffected** | `TargetDown`; nginx logs 502 | Restart. Dashboards are provisioned, so nothing is lost |
| **Alertmanager dies** | Alerts fire but nobody is told | `TargetDown` via Prometheus; `alertmanager_notifications_failed_total` | Restart. **Most dangerous silent failure** — everything looks fine |
| **Kasm dies** | `/webrdp/` down; sessions dropped | `TargetDown`; availability probe | Restart. Sessions do not survive |
| **Kasm DB dies** | Auth fails; sessions dropped | Kasm unhealthy | Restore from dump (§25) |
| **Disk fills** | Writes fail everywhere; Docker + sshd affected | `DiskWillFillIn24h` (24 h warning), then Low/Critical | Prune logs/images. Root cause is usually unbounded logs — §23 prevents it |
| **RAM exhausted** | OOM killer acts | `HostSwapInUse` (early), `HostMemoryPressure`, `HostOOMKill` | Reservations should make a workspace the victim. **Verify this in §31** |
| **Docker daemon restarts** | Brief blip only | Container restart counts | `live-restore: true` keeps containers running |
| **Entire VPS dies** | Everything, including all monitoring | **Only the external monitor (§37)** | §26 full rebuild |
| **TLS renewal fails** | Certificate expires → total browser failure | `CertificateRenewalStale` (~20 days early), then Expiring 21/10 d | Renew manually; check the webroot and rate limits |
| **Tailscale down** | Admin access lost. Services unaffected | Cannot SSH | OCI serial console |
| **Workspace escape** | Potential host compromise | auditd `docker-socket` key; unexpected containers | Isolate, rebuild. See §29 |

## The self-monitoring hole

Prometheus, Grafana, and Alertmanager all live on the box they monitor. **If
the VPS dies, every one of them dies with it, and no alert can be sent.** This
is inherent to single-node monitoring and is precisely why §37 exists.

---

# 29. Security Threat Model

| # | Threat | Likelihood | Impact | Mitigation | Residual |
|---|---|---|---|---|---|
| T1 | SSH brute force | Low | High | **Tailscale-only** (§17); no OCI ingress for 22; password auth off; fail2ban | Very low — *pending the §17 caveat check* |
| T2 | Kasm credential brute force | Med | **Critical** | `auth` rate-limit 5 r/m (§7); **mandatory TOTP** (§16); nginx-layer fail2ban | Low |
| T3 | Exposed Docker port | Med | High | `expose:` not `ports:`; OCI ingress 80/443 only; `port-audit.sh` after every phase | Low — two independent gates |
| T4 | **Workspace container escape** | Low | **Critical** | Resource limits; no host network; no host mounts; **socket unreachable from workspaces** (§21) | **Medium — highest residual risk** |
| T5 | **Docker socket abuse** | Low | **Critical** | Only the one required Kasm component; socket proxy considered; auditd watch | Medium |
| T6 | Vulnerable web app | Low | Med | Test site has no deps, no DB, read-only rootfs | Very low |
| T7 | TLS misconfiguration | Low | Med | Mozilla Intermediate; staging first; expiry + staleness alerts | Low |
| T8 | Secret leaked to git | Med | High | `.gitignore`; `.env.example` only; `checkpoint.sh` scanner; hook redaction; **private repo** | Low — but rotate, never delete (rule 30) |
| T9 | Disk exhaustion | Med | High | Log rotation everywhere; `predict_linear` 24 h warning; data on the 147 G volume | Low |
| T10 | **Resource exhaustion → monitoring death** | **High** | High | Reservations + `oom_score_adj`; workspace capped; **tested in §31** | **Medium — the defining risk of this design** |
| T11 | Privilege escalation | Low | Critical | `no-new-privileges`; `cap_drop: ALL`; non-root; auditd `execve` for uid 0 | Low |
| T12 | Compromised image | Low | Critical | Official images; pinned digests; deliberate updates | Medium — supply chain is not solvable here |
| T13 | Compromised dependency | Low | Med | Test site has **zero** dependencies | Very low |
| T14 | RDP exposed | Low | High | 3389 never opened at OCI; host rule removed; xrdp disabled; RDP over Tailscale only | Very low |
| T15 | Metadata endpoint (SSRF → 169.254.169.254) | Low | High | Oracle's `InstanceServices` chain — **do not modify** (§19) | Low |
| T16 | Alert path fails silently | Med | High | SPF/DKIM verified; `notifications_failed_total` alert; quarterly test; external monitor | Low |
| T17 | Backup silently stops | Med | High | Last-success textfile metric + staleness alert; restore tests | Low |

## The two that deserve attention

**T4/T5 — workspace escape and socket abuse.** A Kasm workspace is an
attacker-reachable container *by design*. Combined with a component that holds
the Docker socket, this is the largest concession in the design. It is
mitigated, not eliminated, and it is the price of choosing Kasm over Guacamole
— a fair trade for the capability, but it should be a conscious one.

**T10 — resource exhaustion killing monitoring.** Not a traditional security
threat, but denial-of-monitoring is denial of every other control's feedback
loop. It has the highest likelihood on this list, which is why §22's
reservations exist and why §31 tests them rather than trusting them.

---

# 30. Deployment Phases

Each phase is validated before the next starts. **Commit after every phase**
(rule 30) and tag it.

### Phase 0 — Discovery ✅ COMPLETE
Documented in `docs/context/ENVIRONMENT.md`. No changes made.

### Phase 1 — Host foundation
*Prereq: D-009 confirmed.*
1. `daemon.json` incl. **`data-root` migration** (do it now, before images exist)
2. journald bounds; **auditd rules (O-013)**; kernel sysctls
3. Disable `xrdp`, `rpcbind`, `iperf3`
4. Firewall: add 80/443, **remove the stale 3389 rule**, persist (§19)
5. sshd tightening (§17) — second session open throughout
6. Verify `unattended-upgrades` origins

**Gate:** reboot test. Everything returns; `iptables -S` matches intent;
SSH over Tailscale works; swap active.

### Phase 2 — Docker networking
`proxy-net` and `--internal backend-net`. Verify isolation with throwaway
containers: a `backend-net` container must fail to reach the internet.

**Gate:** isolation proven, not assumed.

### Phase 3 — nginx + TLS on Tailscale
*Prereq: HTTPS Certificates enabled in the Tailscale admin console. **No domain
needed, no OCI ports opened.***
1. `tailscale cert` for `onebox-prod.tailnet-example.ts.net`
2. nginx listening on the **tailscale0 interface only** — not `0.0.0.0`
3. TLS 1.2/1.3, security headers, rate-limit zones, JSON logging
4. HTTP→HTTPS redirect. **HSTS deferred** to Phase 11 — pinning a browser to
   a hostname you are still experimenting with is a self-inflicted wound
5. fail2ban nginx jails

**Gate:** `https://onebox-prod.tailnet-example.ts.net/` serves with a valid public
certificate; headers verified on 200 **and** 4xx; `port-audit.sh` clean;
request-ID propagation visible end to end; **nothing listening on a public
interface.**

### Phase 4 — Test website
Deploy; validate the full chain `DNS → TLS → nginx → Docker → app`.

**Gate:** page loads over HTTPS; `/healthz` returns JSON; backend port not
published; container logs are valid canonical JSON.

### Phase 5 — Monitoring
node_exporter (host systemd) → Prometheus → Grafana at `/monitoring/`.

**Gate:** all targets `up`; Grafana works **under the subpath**; dashboard
renders; no port published.

### Phase 6 — Alerting
Alertmanager → Brevo. **Test every critical alert by forcing its condition.**

**Gate:** test email received **in the inbox**; a real alert fires and
resolves; SPF/DKIM verified.

### Phase 7 — Kasm ⚠️ measurement-gated
*Prereq: Phases 1–6 green; swap active (done).*

| Sub | Work | Gate |
|---|---|---|
| 7a | Verify CE licensing; pin version; **arm64 for services AND workspace images**; MFA options; metrics; socket requirement | Documented in `DECISIONS.md` |
| 7b | Install; inventory every container, listener, network | Complete inventory |
| 7c | **Measure idle** with the full stack running | Fits the §22 budget |
| 7d | Lock down: no public listener; least-privilege networking; socket review | `port-audit.sh` clean |
| 7e | Zone config: Proxy Path `/webrdp`, Proxy Port 0 | Settings recorded |
| 7f | nginx `/webrdp/`; assets, API, WebSocket | **No 404s in the network tab** |
| 7g | ONE minimal workspace; **measure launch burst + steady state** | Fits; nothing evicted |
| 7h | Second admin; verify out-of-band reset; **then** enforce TOTP | Recovery proven first |
| 7i | Full interactive testing (§31) | All of §32 passes |
| 7j | Monitoring, health checks, DB backup **+ restore test** | Restore verified |

**Stop condition:** if 7c or 7g shows Kasm cannot coexist with monitoring,
report the measurements. Do not proceed.

### Phase 8 — Fail2ban completion
Kasm jail **only if** §18's investigation supports one. Test every jail from a
Tailscale address.

### Phase 9 — Backups
Scripts, schedule, off-site, encryption, staleness metric — **and a restore
test**.

### Phase 10 — Security validation and DR drill
Full Docker port audit; TLS and header validation; auth testing; fail2ban
tests; **resource-limit test (§31)**; backup restore; reboot test; **full DR
rebuild drill (§26)**.

External port scan expects **zero open ports** at this stage — nothing has been
opened at OCI yet.

### Phase 11 — Public launch ⏸ *deferred until the domain is bought*
Everything above runs on the tailnet. This phase makes it public, and it is
deliberately last — by now Kasm is proven, resources are measured, and the only
new variables are DNS and the public certificate.

1. Buy the domain; create A records for apex and `www` → `203.0.113.10`
   (low TTL, 300 s)
2. **Open OCI ingress 80/443** — the first and only public exposure
3. Add 80/443 to the host iptables ruleset; persist (§19)
4. nginx: add the public `server` block alongside the existing tailnet one.
   The tailnet listener **stays** — it becomes the admin path if the public
   path breaks
5. certbot: **staging certificate first**, verify, then production
6. `www` → apex canonicalisation
7. **Now** enable HSTS (still without `preload`)
8. Register the external uptime monitor (§H)
9. Re-run the full §32 acceptance matrix against the public URL — especially
   Kasm's `/webrdp/`, since cookie domain and origin both change

**Gate:** external scan shows only 80/443; SSL Labs A or better; the full Kasm
interactive matrix passes against the public hostname, not just the tailnet one.

---

# 31. Testing Strategy

## Per phase

Pre-flight and post-change procedure: `.claude/skills/infra-safety/SKILL.md`.
Validators (`nginx -t`, `promtool`, `amtool`, `sshd -t`, `compose config`) must
pass before apply, every time.

## The tests that are usually skipped, and matter most

### Reboot recovery
The single most valuable test on a single-node platform, because it is the
failure guaranteed to happen.

```bash
docker ps --format '{{.Names}}' | sort > /tmp/before-reboot.txt
sudo reboot
# reconnect, wait 3 min
docker ps --format '{{.Names}}' | sort > /tmp/after-reboot.txt
diff /tmp/before-reboot.txt /tmp/after-reboot.txt      # must be empty
curl -fsS -o /dev/null -w '%{http_code}\n' https://DOMAIN/
sudo iptables -S INPUT | grep 3389                      # must be EMPTY
swapon --show                                           # must show 4G
```

Anything that does not return by itself is a missing `restart:`, a missing
external network, or a dependency-ordering bug. Fix and re-test.

### Resource limit / OOM behaviour — **tests T10 directly**

```bash
# with monitoring running, launch workspaces until something is killed
# then confirm the victim:
sudo journalctl -k | grep -i 'killed process'
docker inspect prometheus --format '{{.State.OOMKilled}}'   # must be false
```

**Expected: the workspace dies, Prometheus survives.** If Prometheus is the
victim, the reservations in §22 are wrong and must be fixed before proceeding.
This is the one test that validates the central design claim.

### Alert verification
Every alert forced at least once — fill a disk with a temp file, stop a
container, spin CPU, expire a test certificate. **An alert that has never fired
is untested**, and the failure mode is silence.

### External port scan — from off-host

```bash
nmap -Pn -p- 203.0.113.10        # expect ONLY 80 and 443
nc -zv -w 5 203.0.113.10 3389    # expect refused/timeout
```

Must be run from a machine outside this network. Scanning yourself proves
nothing about the OCI Security List.

### Kasm interactive testing
The full §32 matrix. **A login page is not a passing test.** The chain
`Browser → nginx → Kasm → Workspace → interactive session` must be exercised,
including clipboard both directions, file transfer, terminal control keys, and
reconnect after a browser refresh.

### Backup restore
`scripts/restore-test.sh` — Kasm DB restored into a scratch Postgres, users and
MFA rows verified present. Before enforcing MFA, then quarterly.

---

# 32. Acceptance Criteria

### Website
```
[ ] DOMAIN and www.DOMAIN resolve to 203.0.113.10
[ ] HTTP 301-redirects to HTTPS
[ ] HTTPS serves with a valid production certificate
[ ] www canonicalises to apex
[ ] Test website loads; /healthz returns JSON
[ ] Backend port 3000 is NOT published
[ ] X-Request-Id round-trips and appears in nginx + app logs
```

### Monitoring
```
[ ] Grafana works at /monitoring/ (subpath, no broken assets)
[ ] Prometheus NOT publicly exposed
[ ] node_exporter NOT publicly exposed (127.0.0.1 + bridge only)
[ ] All scrape targets up
[ ] Dashboard renders; swap panel present
[ ] Retention is 15 days as configured
```

### Alerting
```
[ ] Alertmanager reachable by Prometheus
[ ] Brevo SMTP works; SPF/DKIM verified
[ ] Test email lands in the INBOX, not spam
[ ] Each critical alert fires when forced
[ ] Alerts resolve and send a resolved notification
[ ] Inhibition suppresses correlated alerts
```

### Kasm — see §15/§16; full checklist in `plan.md` §34
```
[ ] CE licensing verified; version pinned; arm64 confirmed for services AND images
[ ] https://DOMAIN/webrdp/ loads with all CSS/JS/assets (no 404s in network tab)
[ ] Login works; TOTP works; MFA REQUIRED for the group
[ ] Second admin exists; out-of-band reset TESTED BEFORE enforcement
[ ] Recovery codes stored encrypted, off-server
[ ] Workspace list loads; workspace launches; WebSocket connects
[ ] Interactive session works; reconnect works; browser refresh survives
[ ] Clipboard local→Kasm and Kasm→local (text, multiline, large, Unicode)
[ ] File upload and download through /webrdp/
[ ] Terminal: Ctrl+C/D/Z, arrows, Tab, resize, colors, Unicode
[ ] Desktop: mouse, keyboard, resolution, fullscreen
[ ] No broken redirects; no redirect to a Kasm hostname
[ ] Kasm not directly exposed; backend ports internal only
[ ] Docker socket unreachable from workspace containers
[ ] Survives Docker restart and host reboot
[ ] In monitoring; DB backup defined and restore TESTED
[ ] Resource consumption measured and within budget
[ ] Workspace launch does NOT evict Prometheus (tested)
```

### Security
```
[ ] External scan shows ONLY 80 and 443
[ ] 3389, 111, 5201 refused from outside; services disabled
[ ] No Docker backend port published
[ ] SSH hardened; Tailscale-only confirmed (or §17 caveat resolved)
[ ] fail2ban jails active and tested
[ ] TLS valid; SSL Labs A or better
[ ] Security headers present on 200 AND on 4xx/5xx
[ ] auditd rules loaded (auditctl -l is NOT empty)
[ ] No secrets in git; repo is PRIVATE
```

### Recovery
```
[ ] Reboot recovery: all containers return unaided
[ ] Stale 3389 rule does not return after reboot
[ ] Backup runs and reports success
[ ] Restore tested for Kasm DB, Grafana DB, and config
[ ] Full DR rebuild drill completed once
[ ] OOM behaviour verified: workspace dies, Prometheus survives
```

---

# 33. Future Expansion

Adding a service is a bounded, repeatable operation:

```text
1. New project dir with compose.yml
2. Join backend-net (+ proxy-net only if nginx must reach it)
3. New conf.d/NN-<name>.conf — no existing file edited
4. CPU + memory limits and reservations
5. Healthcheck that proves it serves
6. Logging limits + canonical log format
7. Prometheus scrape target or availability probe
8. Backup requirement, or an explicit "rebuildable"
9. Security review against §21
10. Update the port matrix; run port-audit.sh
```

`docs/ADDING-A-SERVICE.md` carries this as a checklist. **All ten, every
time** — the ten-point contract in `.claude/rules/20-docker-infra.md` is a
blocker, not a wish list.

## Constraints on new services

- **Path collision:** new public paths must not overlap `/webrdp` or
  `/monitoring` (§15b). `/webrdp-test` would break Kasm.
- **Resource budget:** §22 has ~4.5 G headroom with a workspace running. Every
  new service consumes it. Re-check the budget before adding, not after.
- **arm64 required.**

Plausible additions: git service, status page, file service, personal API,
internal dashboards. Each is a new Docker project plus an nginx route — not an
architecture change. That is the design working.

**CI/CD is deliberately not planned.** A runner on this box would compete with
Kasm for the resources that are already the binding constraint.

---

# 34. Recommended Repository Structure

Single **private** repository, mirroring §6. Private is not a preference: this
tree documents a live server's topology, firewall posture, and known
weaknesses.

```text
server-infrastructure/            (private GitHub)
├── README.md                     ← start here; 30-line orientation
├── CLAUDE.md                     ← auto-loaded rules + host facts
├── instructions.md               ← operating manual + turn ledger
├── .gitignore
├── .claude/                      ← rules, hooks, skills
├── docs/
│   ├── PLAN.md                   ← this document
│   ├── RUNBOOK.md                ← day-two operations
│   ├── DISASTER-RECOVERY.md      ← §26, standalone
│   ├── ADDING-A-SERVICE.md       ← §33 checklist
│   └── context/                  ← STATE, DECISIONS, ENVIRONMENT, audit
├── proxy-nginx/
├── monitoring/
├── kasm/
├── test-website/
└── scripts/
```

**Committed:** all config, `.env.example`, scripts, systemd units, docs,
provisioned dashboards, redacted audit JSONL.
**Never committed:** `.env`, keys, certs, databases, backups, TOTP seeds.

`main` is what is deployed. Tag each phase (`phase-3-nginx`, …) so rollback is
`git checkout <tag> -- <project>/ && docker compose up -d`.

Commit after every major action (D-005). Push requires an explicit ask.

Pre-push, every time:
```bash
git ls-files | grep -Ei '(^|/)\.env$|\.key$|\.pem$|/certs?/'   # must be empty
.claude/skills/session-continuity/scripts/checkpoint.sh
gh repo create <name> --private --source=. --push
```

---

# 35. Risks and Trade-offs

| # | Risk | Likelihood | Impact | Mitigation | Accepted? |
|---|---|---|---|---|---|
| R1 | **Kasm does not fit on 2 vCPU** | **High** | **High** | Measurement-gated Phase 7; reduced allocations; capped sessions; swap | ⚠️ **The defining risk** |
| R2 | **Workspace images lack arm64** | **Med-High** | High | Verify at 7a **before** anything else | ⚠️ Could force a workspace-image change |
| R3 | Kasm installer conflicts with git reproducibility | High | Med | `INSTALLER-OWNED.md`; pinned compose; DB backup for zone settings | Accepted |
| R4 | Kasm upgrade reverts the `/webrdp` zone config | Med | High | Post-upgrade re-verification in §27 | Accepted |
| R5 | Docker socket → workspace escape | Low | **Critical** | §21; socket proxy; auditd watch | ⚠️ Largest security concession |
| R6 | Single node — no HA | Certain | High | External monitor; tested DR; documented RTO | Accepted by design |
| R7 | Self-monitoring blind spot | Certain | High | External monitor (§37) | Accepted, mitigated |
| R8 | Tailscale dependency for admin | Med | Med | OCI serial console fallback — **verify it works** | Accepted |
| R9 | Manual iptables instead of UFW | Certain | Low | Documented; `port-audit.sh`; OCI as second gate | Accepted (D-009) |
| R10 | Let's Encrypt rate limits | Low | Med | Staging first, always | Accepted |
| R11 | ~~Local-only git repo~~ | — | — | **Resolved** — private repo live, pushed 2026-08-16 | ✅ Closed |
| R12 | Alert email to spam | Med | High | SPF/DKIM; inbox-verified test; different provider | Accepted |

## The honest summary

**R1 and R2 are the two that can end this plan**, and both resolve early —
7a (arm64) and 7c/7g (resources). That sequencing is deliberate: find out in
week one, not after building everything around Kasm.

R11 is closed — the private repo is live and pushed, so the project no longer
exists on a single disk.

R6/R7 (single node, self-monitoring blind spot) are accepted by design and
mitigated by §H. Note that §H's external monitor cannot be registered until
Phase 11, since there is no public URL before then — for Phases 1-10 the
blind spot is real and accepted, on the grounds that nothing is in production yet.

## Trade-offs consciously made

| Chose | Over | Because |
|---|---|---|
| Path-based routing | Subdomain | User requirement; single cert, single origin |
| Kasm | Guacamole | UX and capability — at a real resource cost |
| Manual iptables | UFW | UFW would flush the live ruleset and Oracle's chain |
| 15-day retention | 30-day | RAM and disk on a contended box |
| Node.js test site | Bun | Boring beats interesting for scaffolding |
| SMTP relay | Brevo REST API | No bespoke code in the alerting path |
| No log aggregation | Loki/ELK | Would cost more than it returns at this size |
| node_exporter on host | Containerised | Correct metrics without host-level mounts |
| Tailnet first, public last | Waiting for the domain | Real TLS with zero exposure; the plan-killing risks surface before a purchase |

---

# 36. Open Questions — Decisions Required

## Resolved 2026-08-16

| # | Resolution |
|---|---|
| **O-001** | **Closed.** NSG is egress-only. The 3389 ingress was a manual xrdp test, since removed. Nothing was ever publicly reachable |
| **D-009** | **Confirmed** — manage iptables directly, never enable UFW |
| **§17 caveat** | The `198.51.100.23` login was provisioning-era, before Tailscale. SSH and RDP are now Tailscale-only |
| **O-002** | SSH is Tailscale-only, confirmed live and by the user |
| **R11** | Private repo live at `git@github.com:yourusername/personal-infrastructure.git`; pushed |
| **O-004** | Domain deferred by choice → tailnet-first build, D-010 / §8a. No longer blocks anything before Phase 11 |
| **O-005 / O-007** | Swap 4 GiB (D-008); retention 15 days |

## Blocking Phase 3

| # | Question |
|---|---|
| **§8a** | **Enable HTTPS Certificates** in the Tailscale admin console. Currently off (`CertDomains: null`). One toggle; without it there is no TLS on the tailnet |

## Blocking Phase 6–7

| # | Question |
|---|---|
| **§14** | Brevo SMTP key, sender, recipient. The recipient must not be reachable only through this server |
| **O-003** | Is `your-laptop` (`100.64.0.20`) the intended RDP target? |
| — | Confirm the **OCI serial console** works — it is the recovery floor beneath Tailscale |

## Blocking Phase 11 only

| # | Question |
|---|---|
| **O-004** | Domain name and DNS provider — buy when ready. Everything else proceeds without it |

## Non-blocking, decide before the relevant phase

| # | Question | Recommendation |
|---|---|---|
| O-011 | Move Docker `data-root` to `/mnt/data`? | **Yes, in Phase 1** — cheap now, painful later |
| O-012 | Tighten sshd (root login, X11, maxauthtries)? | Yes, Phase 1, with the migration procedure |
| O-013 | Load auditd rules? | **Yes** — auditd currently produces nothing |
| — | Drop the `ubuntu` account from `allowusers`? | Yes — it is a provisioning artefact |
| — | Off-site backup destination? | A second Tailscale node is the cheapest good answer here |
| — | nginx-prometheus-exporter? | Yes if arm64 — ~15 MB for real request-rate data |

---

# 37. Final Recommended Architecture

```text
                            INTERNET
                               │
        ┌──────────────────────┴──────────────────────┐
        │  OCI Security List — ingress 80, 443 ONLY   │
        └──────────────────────┬──────────────────────┘
                               │
        ┌──────────────────────┴──────────────────────┐
        │  Host iptables — ACCEPT 80,443,22 · REJECT  │
        └──────────────────────┬──────────────────────┘
                               │
                       ┌───────┴────────┐
                       │     NGINX      │  TLS 1.2/1.3
                       │  :80 → :443    │  HSTS · headers
                       │  JSON logs     │  rate limits
                       │  request_id    │  the ONLY public process
                       └───────┬────────┘
                               │ proxy-net
        ┌──────────────────────┼──────────────────────┐
        │                      │                      │
   /  ·  /www            /monitoring/             /webrdp/
        │                      │                      │
  ┌─────┴──────┐        ┌──────┴──────┐        ┌──────┴───────┐
  │  test-site │        │   Grafana   │        │  Kasm proxy  │
  │  node:22   │        │  subpath    │        │    :8443     │
  │  read-only │        │  provisioned│        │  ws · 1800s  │
  └────────────┘        └──────┬──────┘        └──────┬───────┘
                               │ backend-net          │ kasm-internal
                    ┌──────────┴──────────┐   ┌───────┴────────────┐
                    │     Prometheus      │   │ api·manager·agent  │
                    │   15s · 15 days     │   │ share·postgres·redis│
                    │   reserved 768M     │   └───────┬────────────┘
                    └──────────┬──────────┘           │
                               │              workspace ×1 (capped)
                    ┌──────────┴──────────┐    2.0G · 1.0 cpu
                    │    Alertmanager     │           │
                    │  group·inhibit·dedup│      ┌────┴────┐
                    └──────────┬──────────┘      │         │
                               │                SSH       RDP
                     node_exporter (host)         └────┬────┘
                     127.0.0.1 + bridge :9100          │ tailscale0
                               │                       ▼
                          Brevo SMTP              your-laptop
                               │                 100.64.0.20
                             Email

   ADMIN PATH (independent):  you ──► Tailscale ──► sshd :22
   FALLBACK:                  OCI serial console
   STORAGE:                   /mnt/data — docker root, data, backups
   MEMORY GUARD:              reservations + oom_score_adj → workspace dies first
```

---

# A. Resource Budget

| Service | CPU limit | Mem limit | Mem reservation | Expected | Purpose |
|---|---|---|---|---|---|
| Host OS + Docker + tailscaled | — | — | — | ~1.0 G | Base system |
| node_exporter (systemd) | — | — | — | ~30 M | Host metrics |
| nginx | 0.30 | 192 M | 64 M | ~40 M | Public gateway, TLS |
| test-website | 0.15 | 128 M | 32 M | ~50 M | Chain validation |
| Prometheus | 0.50 | 1.0 G | **768 M** | ~600 M | TSDB, 15 d |
| Grafana | 0.40 | 512 M | **256 M** | ~250 M | Dashboards |
| Alertmanager | 0.10 | 128 M | **96 M** | ~40 M | Alert routing |
| nginx-exporter (opt.) | 0.05 | 64 M | 16 M | ~15 M | Request metrics |
| Kasm services | 0.75 | 3.5 G | 2.0 G | **MEASURE** | Workspace platform |
| Kasm workspace ×1 | 1.00 | 2.0 G | 512 M | **MEASURE** | Session |
| **Totals** | **3.20** / 2.00 | **7.5 G** | | | |

**Steady state (no workspace):** ~2.0 G used of 11 GiB → ~9 G free.
**With one workspace:** ~6.5 G used → ~4.5 G free + 4 G swap.

CPU limits are intentionally oversubscribed — they are ceilings, not
reservations. Memory reservations are the load-bearing column: they make the
OOM killer choose a workspace over Prometheus.

# B. Port Matrix

| Port | Proto | Scope | Service | Reason |
|---|---|---|---|---|
| 80 | tcp | **Public** | nginx | HTTP→HTTPS redirect; ACME http-01 |
| 443 | tcp | **Public** | nginx | All application traffic |
| 22 | tcp | **Tailscale only** | sshd | Administration. Not opened at OCI |
| 41641 | udp | Public (outbound) | tailscaled | Mesh |
| 9100 | tcp | Loopback + bridge | node_exporter | Prometheus scrape |
| 3000 | tcp | `proxy-net` | test-website | `expose:` only |
| 3000 | tcp | `proxy-net`/`backend-net` | Grafana | `expose:` only |
| 9090 | tcp | `backend-net` | Prometheus | `expose:` only |
| 9093 | tcp | `backend-net` | Alertmanager | `expose:` only |
| 8443 | tcp | `proxy-net` | Kasm proxy | `expose:` only |
| 5432 / 6379 | tcp | `kasm-internal` | Kasm DB / redis | Never leaves Kasm's network |
| ~~3389~~ | tcp | **Removed** | ~~xrdp~~ | Disabled; host rule deleted |
| ~~111~~ | tcp/udp | **Removed** | ~~rpcbind~~ | No NFS role |
| ~~5201~~ | tcp | **Removed** | ~~iperf3~~ | Leftover test tool |

**Only 80 and 443 are opened at OCI. Nothing else, ever, without a written reason.**

# C. Network Matrix

| Source | Destination | Allowed | Reason |
|---|---|---|---|
| Internet | nginx :80/:443 | ✅ | The only public entry |
| Internet | anything else | ❌ | OCI + iptables + `expose:` |
| nginx | test-website, Grafana, Kasm proxy | ✅ | Proxy targets |
| nginx | Prometheus, Alertmanager, Kasm internals | ❌ | Not proxied — no reason |
| Grafana | Prometheus, Alertmanager | ✅ | Datasource |
| Prometheus | node_exporter, Grafana, Alertmanager, nginx | ✅ | Scraping |
| Prometheus | internet | ❌ | `backend-net` is `internal` |
| Alertmanager | Brevo SMTP | ✅ | The one deliberate egress |
| Alertmanager | anything inbound except Prometheus | ❌ | Least privilege |
| test-website | anything | ❌ | Static; needs nothing |
| Kasm proxy | Kasm internals | ✅ | Session brokering |
| Workspace | Kasm internals | ⚠️ minimal | Required; keep narrow |
| Workspace | `backend-net` | ❌ | **Least-trusted component** |
| Workspace | Docker socket | ❌ | Root on host (T5) |
| Workspace | `your-laptop` via tailscale0 | ✅ | The RDP purpose |
| Anything | 169.254.169.254 | ❌ | Oracle `InstanceServices` — do not modify |

# D. Security Checklist — before declaring production

```
[ ] External scan from off-host shows ONLY 80, 443
[ ] port-audit.sh clean; no unintended non-loopback listener
[ ] xrdp, rpcbind, iperf3 disabled; stale 3389 iptables rule removed and not returning
[ ] Firewall rules persisted; live state == rules.v4
[ ] sshd: no root login, no X11, maxauthtries 3, Tailscale-only confirmed
[ ] auditd rules loaded — auditctl -l is NOT empty
[ ] journald bounded (2 G / 30 d)
[ ] fail2ban jails active and individually tested
[ ] TLS: production cert, A rating, HSTS, no TLS 1.0/1.1
[ ] Security headers on 200 AND on 4xx/5xx responses
[ ] Kasm: MFA enforced, recovery tested BEFORE enforcement
[ ] Docker socket unreachable from workspace containers
[ ] All containers: limits, reservations, healthcheck, log bounds, no-new-privileges
[ ] No secrets in git; repo PRIVATE; checkpoint.sh scanner clean
[ ] .env files are 0600
[ ] Backups running, restore tested, staleness alert configured
[ ] OOM test: workspace dies, Prometheus survives
[ ] Reboot test passed
[ ] Full DR rebuild drill completed once
```

# E. Deployment Sequence

```
Phase 0  Discovery                                        ✅ COMPLETE
Phase 1  Host foundation (daemon.json + data-root, auditd,
         journald, firewall, sshd, disable xrdp/rpcbind)  → reboot gate
Phase 2  Docker networks + isolation proof
Phase 3  nginx + TLS on the TAILNET (tailscale cert)      ← no domain needed
Phase 4  Test website — validates the whole chain
Phase 5  Monitoring (node_exporter → Prometheus → Grafana)
Phase 6  Alerting (Alertmanager → Brevo) — force every alert
Phase 7  Kasm, sub-phased 7a→7j                           ⚠️ measurement-gated
Phase 8  Fail2ban completion
Phase 9  Backups + restore test
Phase 10 Security validation + DR drill
Phase 11 PUBLIC LAUNCH — domain, OCI 80/443, certbot, HSTS ⏸ when domain bought

Phases 1-10 run entirely on the tailnet. Nothing is internet-reachable until 11.
```

# F. Validation Commands — run after every phase

```bash
# 1. Validators
nginx -t; docker compose config -q; sudo sshd -t
promtool check config prometheus.yml; promtool check rules rules/*.yml

# 2. Serving, not merely running
curl -fsS -o /dev/null -w '%{http_code} %{time_total}s\n' https://DOMAIN/
docker compose ps --format 'table {{.Name}}\t{{.State}}\t{{.Status}}'

# 3. Crash loops
docker ps --format '{{.Names}}' | xargs -I{} sh -c \
  'printf "%-24s restarts=%s\n" {} $(docker inspect -f "{{.RestartCount}}" {})'

# 4. Errors in the change window
docker compose logs --since 5m 2>&1 | grep -iE 'error|fatal|panic|denied' | head -30
sudo journalctl --since '5 min ago' -p warning --no-pager | tail -30

# 5. Exposure — the check that matters most
ss -tulpn | grep -vE '127\.0\.0\.1|\[::1\]'
docker ps --format '{{.Names}}\t{{.Ports}}'
sudo iptables -S INPUT

# 6. Resources
free -h; swapon --show; docker stats --no-stream \
  --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}'

# 7. Record and commit
# update STATE.md + DECISIONS.md, then commit and tag the phase
```

Diff §5 against the previous run. **Any new non-loopback listener is an
incident.**

# G. Risks — top five

1. **Kasm does not fit** (R1) — resolved at 7c/7g; stop condition defined.
2. **Workspace images lack arm64** (R2) — resolved at 7a, before anything is built.
3. **Docker socket → workspace escape** (R5) — mitigated, not eliminated;
   the price of Kasm.
4. **Resource exhaustion kills monitoring** (T10) — reservations + a test that
   proves it.
5. **Kasm upgrade silently reverts the `/webrdp` zone config** (R4) — caught by
   the post-upgrade re-verification in §27, not by any automated check.

# H. External Monitoring (§37 of the brief)

Prometheus, Grafana, and Alertmanager all die with the VPS. **No internal alert
can report that the VPS is gone.**

Recommendation: a **free external uptime service** (UptimeRobot, Better Stack,
Healthchecks.io free tier) checking:

```
https://DOMAIN/           expect 200
https://DOMAIN/monitoring/ expect 200 or 302
https://DOMAIN/webrdp/    expect 200
```

5-minute interval, alerting to the same address as Brevo — plus a push
notification, since email may route through infrastructure that is also down.

**Explicitly not** a self-hosted uptime stack. Monitoring this box from this box
solves nothing, and on 2 vCPU it costs resources that Kasm already needs.

Add this at Phase 3, as soon as there is a URL to check. It is five minutes of
work and it is the only thing that detects total failure.

# I. Open Decisions — summary

**Blocking Phase 3:** enable **HTTPS Certificates** in the Tailscale admin
console — one toggle, currently off.

**Blocking Phase 6–7:** Brevo credentials + a recipient not reachable only
through this server · is `your-laptop` the RDP target? (O-003) · confirm the OCI
serial console works.

**Blocking Phase 11 only:** the domain (O-004). Nothing before that needs it.

**Recommended in Phase 1:** move Docker `data-root` (O-011) · load auditd rules
(O-013) · tighten sshd and drop the `ubuntu` account (O-012).

**Already decided:** tailnet-first build (D-010) · iptables not UFW (D-009,
confirmed) · retention 15 days (O-007) · swap 4 GiB (D-008) · data on
`/mnt/data` (O-006) · Kasm at `/webrdp/` (D-006) · commit after every major
action (D-005).

**Closed:** O-001 (NSG egress-only) · O-002 (Tailscale-only SSH) · R11 (private
repo live).

---

*End of plan. Nothing herein has been implemented. Awaiting approval to begin
Phase 1.*
