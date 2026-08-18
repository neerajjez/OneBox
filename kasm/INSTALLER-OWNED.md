# Kasm: what the installer owns, and what we changed

Kasm installs itself under `/opt/kasm/<version>` and generates its own compose
file. That sits awkwardly with "rebuildable from git" (O-009), so this file
records exactly what we changed and why. **Re-apply after every upgrade** — the
installer regenerates the compose file.

Version pinned: **1.17.0**. Proxy port: 8443. Install log: `/tmp/kasm_install_*.log`.

## Installer-owned — do not hand-edit

```
/opt/kasm/1.17.0/          entire tree
/opt/kasm/current          symlink
```

## Our changes to `/opt/kasm/current/docker/docker-compose.yaml`

A copy of the modified file lives here as `compose.pinned.yml`. Original is at
`docker-compose.yaml.orig` on the host.

| Change | Why |
|---|---|
| Removed `rdp_gateway` and `kasm_rdp_https_gateway` | They publish `0.0.0.0:3389`, which collides with **xrdp** — the host's own desktop, which is our RDP *target*, not an inbound listener. The collision aborted the install. Kasm reaches RDP targets outbound via `kasm_guac`; these gateways are for inbound RDP clients, which we do not use. |
| Removed `- kasm_rdp_https_gateway` from `proxy.depends_on` | It no longer exists. |
| Removed `ports: "8443:8443"` from `proxy` | Rule 20: only nginx publishes ports. |
| Added `proxy-net` to `proxy.networks` | So our nginx reaches `kasm_proxy:8443` by container name over the Docker network instead of via a published host port. |
| Added `mem_limit` to all 8 services (3456M total) | Kasm sets none, so every container was entitled to all 11.65 GiB. See D-015. |
| Mounted `kasm/patches/sitecustomize.py` into `kasm_api` | Works around a 1.17.0 CE inheritance bug that makes every successful login 500. See `notes/hubspot-defect.md`. |

## Zone configuration (lives in Kasm's DATABASE, not a file)

Git cannot protect this — only the DB backup can (§25).

| Setting | Value |
|---|---|
| `proxy_path` | **`webrdp/desktop`** — external prefix + Kasm's internal path, no leading slash. See PLAN §15b for why the three obvious values all fail. |
| `proxy_port` | `0` |
| `upstream_auth_address` | `proxy` (single-server default) |

Pre-change snapshot: `notes/zones-before.csv`.

Applied with:
```sql
update zones set proxy_path='/webrdp', proxy_port=0 where zone_name='default';
```

## Operating

```bash
sudo /opt/kasm/bin/start     # exports KASM_UID/KASM_GID then compose up
sudo /opt/kasm/bin/stop
sudo /opt/kasm/bin/restart
```

Plain `docker compose` in that directory **fails** — the compose file requires
`KASM_UID`/`KASM_GID`, which those wrappers export.

## After any upgrade

1. `scripts/preflight.sh` — the upgrade reinstalls the rclone plugin (D-013).
2. Re-apply the compose changes above.
3. Re-verify the zone settings — an upgrade can revert `/webrdp`.
4. Re-run the §32 Kasm acceptance checks.
