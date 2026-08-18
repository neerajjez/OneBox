# Host configuration

The files under `host/` are the **source of truth** for this server's
host-level configuration. They are copied to their real locations by
`scripts/apply-host-config.sh`, never edited in place on the server.

This is what makes §26's "rebuild from git" claim true for the host layer,
not just the container layer.

| Repo path | Deployed to | Applied by |
|---|---|---|
| `docker/daemon.json` | `/etc/docker/daemon.json` | `systemctl restart docker` |
| `systemd/journald.conf` | `/etc/systemd/journald.conf` | `systemctl restart systemd-journald` |
| `audit/hardening.rules` | `/etc/audit/rules.d/hardening.rules` | `augenrules --load` |
| `sysctl/99-hardening.conf` | `/etc/sysctl.d/99-hardening.conf` | `sysctl --system` |
| `sysctl/99-swap.conf` | `/etc/sysctl.d/99-swap.conf` | `sysctl --system` |
| `iptables/rules.v4` | `/etc/iptables/rules.v4` | `netfilter-persistent reload` |
| `containerd/config.toml` | `/etc/containerd/config.toml` | `systemctl restart containerd docker` |
| `xrdp/sesman.ini` | `/etc/xrdp/sesman.ini` | `systemctl restart xrdp-sesman xrdp` |
| `xrdp/startwm.sh` | `/etc/xrdp/startwm.sh` | takes effect on next session |
| `ssh/99-hardening.conf` | `/etc/ssh/sshd_config.d/99-hardening.conf` | `sshd -t && systemctl reload ssh` |
| `fail2ban/jail-nginx.local` | `/etc/fail2ban/jail.d/nginx.local` | `fail2ban-client reload` |
| `fail2ban/filter.d/*.conf` | `/etc/fail2ban/filter.d/` | `fail2ban-client reload` |
| `systemd/node_exporter.service` | `/etc/systemd/system/` | `systemctl daemon-reload` |

## SSH

`ssh/99-hardening.conf` is a drop-in, so the distribution `sshd_config` stays
pristine and the whole change is one file to delete.

One exception: **`AllowUsers` is additive in sshd, not override.** A drop-in
cannot remove a user that the main config allows — it only adds. So dropping
the `ubuntu` account required editing line 132 of `/etc/ssh/sshd_config`
directly. Backups are at `/etc/ssh/sshd_config.bak-allowusers-*`.

Every SSH change follows the rule 00 protocol: validate with `sshd -t`,
**reload not restart** (reload keeps existing sessions), then prove a BRAND NEW
login works before considering it done. `~/.ssh/id_verify` exists solely to be
that independent verification path.

## Not in here, deliberately
- Anything containing a secret.
