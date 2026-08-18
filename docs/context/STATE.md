# Current state

**Updated:** <date> · **This is a template — overwrite it with your reality.**

> Current truth only. History goes in `DECISIONS.md`. Overwrite this file freely;
> it is meant to be replaced, not appended to.
>
> This is the first file anyone (or any assistant) reads. A stale version here
> is worse than no version, because it is trusted.

## Where we are

| | |
|---|---|
| Domain | `yourdomain.com` |
| DNS | Cloudflare, proxied. SSL/TLS mode **Full (Strict)** |
| Edge cert | Cloudflare's — auto-renewed, not yours |
| Origin cert | Let's Encrypt, apex + wildcard, expires `<date>` |
| Public IP | `<addr>` |
| Ingress | Cloud firewall **and** `DOCKER-USER`: 443 from Cloudflare ranges only |
| Off-site backup | `<bucket>`, nightly |
| Health | `<n>` containers · `<n>/<n>` targets · `<n>` alert rules · `<n>` firing |

| Path | Service | State |
|---|---|---|
| `/` | website | |
| `/monitoring/` | Grafana | |
| `/webrdp/` | Kasm Workspaces | |

## Scheduled work

| Timer | When | What |
|---|---|---|
| `backup-offsite.timer` | 02:52 UTC | encrypted archive → object storage |
| `backup.timer` | 03:00 UTC | local backup set |
| `certbot-renew.timer` | 03:21 UTC ×2/day | DNS-01 renewal + nginx reload |
| `cf-range-drift.timer` | 06:41 UTC | Cloudflare IP list vs our allowlist |
| `container-stats.timer` | every 60s | per-container CPU/memory |

## What still needs attention

1.
2.
3.

## Things that were true and are no longer

Keep this section. It is the highest-value part of the file: it stops the next
person — including you in three months — re-deriving a wrong conclusion.

The original build's entries are preserved below as worked examples, because the
*shape* of the mistake generalises even though the specifics do not.

| Claim | Truth |
|---|---|
| "This host has no public IP" | It did. The cloud used 1:1 NAT, so the address appeared on no interface and was absent from instance metadata. **Read the access log for inbound connections; metadata and egress lookups answer a different question.** |
| "`NoSuchBucket` means the object-store compartment is wrong" | It was **authorization**. An empty bucket list is also what `ListBuckets` returns when denied. The API merged 403 into 404 deliberately, so the error could not distinguish them. |
| "The orphaned volumes came from the app install" | They came from the **restore test**, which used `docker rm -f` without `-v` and leaked ~139 MB per run. |
| "cAdvisor will give per-container metrics" | Not with Docker's containerd image store — it cannot resolve container names, via `--containerd` either. Replaced with a `docker stats` exporter. |
| "The hooks redact secrets" | They did not. Pattern matching cannot catch a bare value on a command line. A denylist of literal values was required. |
