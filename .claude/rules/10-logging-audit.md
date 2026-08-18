# Rule 10 — Logging and audit standard

One shape for every log line we control. A field name means the same thing
whether it came from nginx, a backup script, or a Claude hook — that is the
entire value of a standard, and it is why ad-hoc formats are not allowed.

## Canonical event

One JSON object per line (JSONL), UTF-8, no pretty-printing, no trailing comma.

```json
{"ts":"2026-08-16T03:37:08.258Z","level":"info","service":"nginx","env":"vps-prod","host":"onebox-prod","event":"http.request","actor":"anon","source_ip":"203.0.113.7","request_id":"7f3c…","target":"/webrdp/api/tokens","outcome":"success","status":200,"duration_ms":42,"msg":"proxied to guacamole"}
```

### Required on every event

| Field | Type | Notes |
|---|---|---|
| `ts` | string | RFC 3339, **UTC**, millisecond precision, `Z` suffix. Never local time. |
| `level` | enum | `debug` \| `info` \| `warn` \| `error` \| `critical` |
| `service` | string | Emitter: `nginx`, `guacamole`, `prometheus`, `backup`, `claude-code`, … |
| `env` | string | `vps-prod` for this host |
| `host` | string | Short hostname |
| `event` | string | `noun.verb`, lowercase, dot-separated: `http.request`, `auth.login`, `backup.complete`, `tool.bash` |
| `outcome` | enum | `success` \| `failure` \| `blocked` \| `denied` |
| `msg` | string | Human sentence. Never the only source of truth — never parse it. |

### Required when applicable

| Field | Notes |
|---|---|
| `actor` | Authenticated identity, or `anon`/`system`. Never a password or token. |
| `source_ip` | Real client IP, not the proxy's. Requires correct `X-Forwarded-For` handling. |
| `request_id` | Generated at nginx, propagated downstream. Makes a request traceable end to end. |
| `session_id` | Claude Code session, Guacamole session, etc. |
| `target` | What was acted on: URL path, file path, container, table. |
| `status` | Numeric protocol status (HTTP code, exit code). |
| `duration_ms` | Integer milliseconds. |
| `reason` | Why a `blocked`/`denied`/`failure` outcome happened. |
| `error` | Error class or message, redacted. |

### Rules

- **Additive only.** Never rename or repurpose a field; add a new one.
- **No nesting beyond one level.** Flat objects survive every log tool.
- `level` describes severity; `outcome` describes result. A `warn` can be a
  `success`. Do not collapse them.
- Timestamps are UTC everywhere, including cron and backup scripts. Local time
  in logs costs an hour of confusion twice a year.

## Never logged

Passwords, API keys (`BREVO_API_KEY`), session tokens, TOTP seeds or codes,
private keys, full `Authorization` / `Cookie` headers, request bodies of auth
endpoints. Redact at the emitter, not at the collector — a redaction that runs
after the write has already lost.

## Per-producer configuration

### Nginx — access log

Define once in `nginx.conf`, reuse per site. `escape=json` is mandatory: without
it a crafted URL breaks the JSON and poisons every downstream parser.

```nginx
log_format json_main escape=json
  '{"ts":"$time_iso8601","level":"info","service":"nginx","env":"vps-prod",'
  '"host":"$hostname","event":"http.request","actor":"$remote_user",'
  '"source_ip":"$remote_addr","request_id":"$request_id",'
  '"target":"$request_uri","method":"$request_method","status":$status,'
  '"outcome":"$upstream_cache_status","duration_ms":$request_time_ms,'
  '"upstream":"$upstream_addr","upstream_ms":"$upstream_response_time",'
  '"bytes_sent":$body_bytes_sent,"referer":"$http_referer",'
  '"user_agent":"$http_user_agent","server_name":"$server_name","msg":""}';
```

Notes:
- `$time_iso8601` is second-precision and local-offset. Set the container `TZ=UTC`
  and accept second precision, or use `$msec` and normalise downstream. Decide
  this during Phase 3 and record it in `DECISIONS.md`.
- `duration_ms` needs a `map` from `$request_time` (seconds, float) — nginx has
  no millisecond variable. Do not silently log seconds in a `_ms` field.
- Add `add_header X-Request-Id $request_id;` and pass
  `proxy_set_header X-Request-Id $request_id;` so backends can correlate.
- Health-check noise: `access_log off;` for `/healthz` only.

### Nginx — error log

`error_log /var/log/nginx/error.log warn;` — nginx cannot emit JSON here. It is
the one accepted exception; parse it with a regex at collection time.

### Docker

Every service in every compose file:

```yaml
logging:
  driver: json-file
  options:
    max-size: "10m"
    max-file: "5"
    tag: "{{.Name}}"
```

Also set the daemon default in `/etc/docker/daemon.json` so a service that
forgets the block still cannot fill the disk. Ceiling per service is 50 MB;
with ~10 services that bounds container logs at ~500 MB — sane against a 48 G
root disk.

### Host

- **journald persistent and bounded**: `Storage=persistent`,
  `SystemMaxUse=2G`, `MaxRetentionSec=30day` in `/etc/systemd/journald.conf`.
  Default volatile journald loses everything on reboot — exactly the logs you
  want after an unexplained reboot.
- **auditd**, narrow and defensible scope. Watch identity and config, not
  every syscall (a broad ruleset will eat a 2-vCPU box):
  `/etc/passwd`, `/etc/shadow`, `/etc/sudoers`, `/etc/sudoers.d/`,
  `/etc/ssh/sshd_config`, `/etc/systemd/system/`, `/etc/cron*`,
  `/opt/server/**/.env`, and `execve` for uid 0.
- **logrotate** for anything written outside Docker/journald, including
  `docs/context/audit/`.

### Claude Code (this repo)

`.claude/hooks/*` already emit the canonical event to
`docs/context/audit/YYYY-MM-DD.jsonl` with `service:"claude-code"`. Events:
`session.start`, `turn.prompt`, `turn.end`, `tool.bash`, `tool.edit`,
`tool.write`, `guard.deny`, `guard.escalate`.

## Retention

| Stream | Retention | Where |
|---|---|---|
| Docker container logs | 50 MB/service rolling | `/var/lib/docker` |
| journald | 30 days / 2 GB | `/var/log/journal` |
| auditd | 90 days, `max_log_file_action = keep_logs` | `/var/log/audit` |
| nginx access/error | 14 days compressed | `/var/log/nginx` |
| Claude audit JSONL | indefinite (small), in git | `docs/context/audit` |
| Prometheus TSDB | see `DECISIONS.md` | volume |

## Deliberately out of scope for now

No Loki, no OpenTelemetry collector, no ELK. On 2 vCPU that stack costs more
than it returns at this size. The standard above is chosen so that adding a
shipper later is a collection change, not a rewrite of every emitter — which is
the only reason to standardise this early.
