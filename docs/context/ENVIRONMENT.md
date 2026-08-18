# Environment — verified host facts

Every line here was observed, not assumed. Re-verify before depending on it;
servers drift.

**Last verified:** 2026-08-16 (Phase 0 discovery complete; sudo, firewall, sshd, auditd all read)
**Verified by:** Claude session `c89f76b2`

---

## Host

| Fact | Value | Command |
|---|---|---|
| Hostname | `onebox-prod` | `hostname` |
| OS | Ubuntu 24.04.4 LTS (noble) | `cat /etc/os-release` |
| Kernel | `6.17.0-1018-oracle` | `uname -r` |
| **Platform** | **Oracle Cloud Infrastructure** (inferred from kernel flavour + `enp0s6` + `10.0.0.10`) | — |
| **Architecture** | **aarch64 / ARM64** | `uname -m` |
| CPU | 2 vCPU | `nproc` |
| RAM | 11 GiB total, ~10 GiB available | `free -h` |
| Swap | **4 GiB** `/swapfile`, `vm.swappiness=10` (added 2026-08-16, D-008) | `swapon --show` |
| Uptime | 1 day at time of check | `uptime` |
| Clock | UTC, NTP active, synchronized | `timedatectl` |
| User | `prodadmin` (uid 1002), groups: `sudo`, `users` — **not** in `docker` | `id` |
| sudo | **Passwordless** via `/etc/sudoers.d/99-prodadmin-nopasswd` (user, 2026-08-16) | `sudo -n true` |

## Storage

| Mount | Device | Size | Used | Note |
|---|---|---|---|---|
| `/` | `/dev/sda1` | 48 G | 5.5 G (12 %) | OS + `/var/lib/docker` |
| `/mnt/data` | `/dev/sdb1` | 147 G | 68 K (1 %) | **Empty.** Intended for persistent data + backups. |

`/mnt/data/projects` — this repo. The project directory lives on the data
volume, which is also where container volumes should go.

## Network

| Fact | Value |
|---|---|
| **OCI NSG** | **Egress `0.0.0.0/0` all ports. No ingress rules.** Confirmed by user 2026-08-16 |
| **Tailnet DNS** | MagicDNS suffix `tailnet-example.ts.net`; this host is `onebox-prod.tailnet-example.ts.net` |
| **Tailscale HTTPS certs** | **Not yet enabled** (`CertDomains: null`) — one toggle in the admin console. Prerequisite for Phase 3 (D-010) |
| **Public IPv4** | **`203.0.113.10` — reachable inbound. Verified by log evidence, not inference.** |
| Public IP visibility | **Not on any interface and absent from instance metadata** — OCI uses 1:1 NAT. See below. |
| Private IPv4 | `10.0.0.10/24` on `enp0s6`, virtual router `10.0.0.1`, subnet `10.0.0.0/24` |
| Public IPv6 | **None** (`api6.ipify.org` unreachable) |

> **How the public IP works here, and two wrong conclusions I reached first
> (2026-08-16).**
>
> OCI instance metadata reports **no `publicIp` field**, and the address appears
> on **no interface**:
>
> ```
> $ curl -H 'Authorization: Bearer Oracle' http://169.254.169.254/opc/v2/vnics/
> [{"privateIp":"10.0.0.10","subnetCidrBlock":"10.0.0.0/24", ...}]   # no publicIp
> $ ip -brief addr        # enp0s6 has only 10.0.0.10/24
> ```
>
> From that I concluded the host had no public IP and was unreachable. **That was
> wrong.** OCI attaches ephemeral public IPs by **1:1 NAT at the VCN layer** — the
> address is never configured on the guest OS and need not appear in that
> metadata field. Absence there is not evidence of absence.
>
> The *first* version of this file was also wrong, for a different reason: it
> recorded `203.0.113.10` from `curl api.ipify.org`, which only proves egress.
>
> **Neither method settles it. Log evidence does.** `access.log` shows inbound
> requests arriving from Cloudflare edges (`172.71.198.206`, `172.70.218.112`)
> and from 15 distinct unrelated public IPs running opportunistic scans. Inbound
> works, and the address is `203.0.113.10`.
>
> **Rule for next time:** to decide whether a host is reachable, read the access
> log for inbound connections from addresses you did not originate. Metadata
> fields and egress lookups both answer a different question.
>
> **Consequence:** D-018 stands as written. It also means the origin is
> **directly reachable, bypassing Cloudflare** — see **O-020**.
| Tailscale IPv4 | `100.64.0.10` (`onebox-prod`) |
| Tailscale IPv6 | `fd7a:115c:a1e0::4a01:f7be` |

### Tailscale mesh — account `you@example.com`

| Node | Tailscale IP | OS | State |
|---|---|---|---|
| `onebox-prod` | `100.64.0.10` | linux | this host |
| `your-laptop` | `100.64.0.20` | linux | **active**, direct via `198.51.100.45` |
| `oneplus-nord-3-5g` | `100.100.160.47` | android | offline |

This changes the architecture materially — see `DECISIONS.md` D-002 and D-003.

### Listening sockets — non-loopback (2026-08-16)

| Port | Proto | Bind | Owner | Assessment |
|---|---|---|---|---|
| 22 | tcp | `0.0.0.0`, `[::]` | sshd | Reached over Tailscale; not opened at the OCI NSG. |
| **80, 443** | tcp | `0.0.0.0` | **nginx** (dockerd) | **Public** once the NSG allows 443 (D-018). |
| **3389** | tcp | `*` | **xrdp** (active + enabled) | Stale wide-open rule removed in Phase 1. Now reachable **only** from the Kasm bridge (`172.20.0.0/16 -> 172.20.0.1:3389`), so workspaces can RDP to this host. |
| ~~111~~ | — | — | ~~rpcbind~~ | **Disabled in Phase 1.** No longer listening. |
| ~~5201~~ | — | — | ~~iperf3~~ | **Disabled in Phase 1.** No longer listening. |
| 41641 | udp | `0.0.0.0`, `[::]` | tailscaled | Expected. |
| 5353 | udp | `0.0.0.0`, `[::]` | mDNS | Review. |
| 53 | tcp+udp | `127.0.0.53`, `127.0.0.54` | systemd-resolved | Loopback — fine. |
| 68 | udp | `10.0.0.10` | dhclient | Expected. |
| 39604 / 56020 | tcp | Tailscale addrs only | tailscaled | Expected. |

## Firewall — read 2026-08-16

### UFW is INACTIVE

```
$ sudo ufw status verbose
Status: inactive
```

`ufw` is installed (0.36.2-6) and its unit is `enabled`, but it is **not
running**. The live filter is plain iptables restored by
`netfilter-persistent` (enabled) from `/etc/iptables/rules.v4`.

**Planning consequence:** do **not** enable ufw on top of this. The existing
ruleset already implements default-deny; turning ufw on would flush and replace
it, and the first casualty would be the SSH rule we are connected through.
**Decided (D-009, confirmed by the user 2026-08-16): manage `rules.v4`
directly. UFW is never enabled on this host.**

### Live INPUT chain (effective policy)

**As first discovered** (pre-Phase-1), for the record:

```
-A INPUT -p tcp -m tcp --dport 3389 -j ACCEPT          # <-- RDP, ANY SOURCE
```

**Current** (Phase 1 + D-018; live and persisted verified identical):

```
-P INPUT ACCEPT
-A INPUT -j ts-input                                    # Tailscale, runtime
-A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
-A INPUT -p icmp -j ACCEPT
-A INPUT -i lo -j ACCEPT
-A INPUT -s 172.19.0.0/24 -d 172.19.0.1/32 -p tcp --dport 9100 -j ACCEPT  # prometheus->node_exporter
-A INPUT -s 172.20.0.0/16 -d 172.20.0.1/32 -p tcp --dport 3389 -j ACCEPT  # kasm workspace->host xrdp
-A INPUT -p tcp -m state --state NEW --dport 80  -j ACCEPT
-A INPUT -p tcp -m state --state NEW --dport 443 -j ACCEPT
-A INPUT -p tcp -m state --state NEW --dport 22  -j ACCEPT
-A INPUT -j REJECT --reject-with icmp-host-prohibited   # default-deny in practice
```

Policy is `ACCEPT` but the trailing REJECT makes it effectively default-deny.
`FORWARD` policy is `DROP`. Oracle's `InstanceServices` chain protects the
169.254.0.0/16 metadata range — **do not modify it**, per Oracle's own comment
in the ruleset.

### The 3389 rule is live-only, NOT persisted

`grep 3389 /etc/iptables/rules.v4` returns **nothing**. The rule exists only in
the running kernel table. Two consequences:

1. **The firewall is not reproducible.** Live state and persisted state differ,
   which violates the reproducibility principle this project is built on.
   Something added it at runtime — most likely the `xrdp` install.
2. **It should vanish on reboot**, when `netfilter-persistent` restores
   `rules.v4`. That must be verified, not assumed — if xrdp re-adds it on
   start, the exposure returns every boot.

### What this resolves, and what it does not

| Port | Host firewall | Verdict |
|---|---|---|
| 111 rpcbind | REJECTed | **Not reachable.** Still disable it — no NFS role. |
| 5201 iperf3 | REJECTed | **Not reachable.** Still stop it — leftover test tool. |
| 22 sshd | ACCEPT | Intended. Reached over Tailscale. |
| ~~3389 wide open~~ | **removed Phase 1** | Now only `172.20.0.0/16 -> 172.20.0.1:3389`. |
| 80, 443 | **ACCEPT (added)** | Public once the NSG allows them (D-018). |

**Resolved 2026-08-16.** The OCI NSG carries egress only, no ingress, so a port
is unreachable regardless of what the host firewall permits. The 3389 host rule
was added manually by the user while testing xrdp and was never persisted; the
matching NSG ingress rule has since been removed. O-001 is closed.

The rule is still deleted in Phase 1 — not for exposure, but so that live and
persisted firewall state agree.

## SSH — `sshd -T`, read 2026-08-16

| Setting | Value | Assessment |
|---|---|---|
| `port` | 22 | Default. |
| `passwordauthentication` | **no globally, but see below** | **Corrected 2026-08-16.** |
| `pubkeyauthentication` | yes | Good. |
| `kbdinteractiveauthentication` | no | Good. |
| `permitemptypasswords` | no | Good. |
| `allowusers` | `prodadmin`, `ubuntu` | Good — allowlisted. Consider dropping `ubuntu`. |
| `permitrootlogin` | **`without-password`** | **Should be `no`.** Key-based root login is still root login. |
| `maxauthtries` | 6 | Consider 3. |
| `x11forwarding` | **yes** | **Should be `no`** — unused, and it is attack surface. |

**Correction (2026-08-16):** the earlier claim that password auth was off was
WRONG, and it stood for most of this project. `sshd -T` reports the GLOBAL
value; it does not show `Match` blocks. The main `sshd_config` contained a
pre-existing, unscoped:

```
Match User prodadmin
    PasswordAuthentication yes
```

so `prodadmin` could password-authenticate from anywhere sshd was reachable. That was
survivable while SSH was Tailscale-only and became unacceptable once the host
was bound publicly. Now scoped to `172.20.0.0/16` (Kasm workspaces) and
`100.64.0.0/10` (Tailscale); the internet is key-only. Verify with
`sshd -T -C addr=<ip>,user=prodadmin,host=h`, never plain `sshd -T`.

SSH is otherwise in good shape: users are allowlisted. Three items to tighten (O-012), none urgent, all lockout-capable —
apply under the migration procedure in `docs/PLAN.md` §17.

`allowusers ubuntu` is a provisioning artefact: port 22 was used during initial
setup before Tailscale, which explains the `198.51.100.23` entry in `last`. Drop
it once confirmed unused.

## Audit and intrusion detection — read 2026-08-16

| Finding | Detail |
|---|---|
| `auditd` | Running and enabled, but **`auditctl -l` reports "No rules"** |
| `fail2ban` | Running and enabled, **one jail: `sshd`** |

**`auditd` is producing nothing.** The daemon is up, so a status check looks
healthy, but with zero rules loaded there is no audit trail of identity, sudo,
SSH config, or unit-file changes. This is a real gap against the audit
requirement — rule 10 specifies the ruleset to load.

`fail2ban` covers SSH only. Nginx jails come with Phase 3; a Kasm jail only if
section 30's investigation supports one.

## Already-installed services

| Service | Active | Enabled | Note |
|---|---|---|---|
| `docker` | yes | yes | 29.7.2; Compose plugin **v5.4.0** |
| `fail2ban` | yes | yes | **Already running** — extend its jails, do not reinstall |
| `auditd` | yes | yes | **Already running** — audit rules not yet reviewed |
| `unattended-upgrades` | yes | yes | Already running; scope not reviewed |
| `xrdp` | yes | yes | See port 3389 above |
| `rpcbind` | yes | yes | See port 111 above |
| `tailscaled` | yes | — | Mesh above |

`journald`: `/var/log/journal` exists, so storage is **persistent**. No
`SystemMaxUse`/`MaxRetentionSec` set — currently unbounded. See rule 10.

`/etc/docker/daemon.json`: **absent**. No default log driver limits, no
log rotation defaults, no custom data-root.

## Absent tooling

`node`, `bun`, `nginx` (host), `certbot`. Installed during this session:
`uv` 0.12.5 and `graphify` 0.9.44 (both under `~/.local/bin`).

## What has NOT been verified

- Whether the live 3389 rule survives a reboot (needs a reboot test). It was
  never persisted to `rules.v4`, so it should not — but xrdp may re-add it.
- Whether `your-laptop` is the intended RDP target.
- `unattended-upgrades` scope — which origins it actually applies.
- Whether the **OCI serial console** works. It is the recovery floor beneath
  Tailscale, and an untested recovery path is not a recovery path.

**Resolved by the user 2026-08-16:** OCI NSG carries **egress `0.0.0.0/0` only,
no ingress rules**. Nothing on this host is reachable from the internet. The
3389 NSG rule used during xrdp testing has been removed. SSH and RDP both go
over Tailscale from the laptop; port 22 was only used during initial
provisioning, which explains the `198.51.100.23` entry in `last`.

## Changes made to this host by us

| Date | Change | Reversal |
|---|---|---|
| 2026-08-16 | `uv` 0.12.5 + `graphify` 0.9.44 into `~/.local/bin` | `uv tool uninstall graphifyy`, `rm -rf ~/.local/bin/uv*` |
| 2026-08-16 | 4 GiB `/swapfile`, fstab entry, `/etc/sysctl.d/99-swap.conf` (D-008) | `sudo swapoff /swapfile && sudo rm /swapfile`, restore `/etc/fstab.bak-20260816T040703Z`, `rm /etc/sysctl.d/99-swap.conf` |
| 2026-08-16 | `~/.ssh` → 700, `~/.ssh/id_ed25519` → 600 (was world-readable 644) | None wanted — this is the correct state |
| 2026-08-16 | `git remote add origin git@github.com:yourusername/personal-infrastructure.git`; pushed `main` | `git remote remove origin` |

Nothing else on the host has been modified. No firewall, sshd, DNS, service, or
container change.

## Re-verification command

```bash
uname -srm; nproc; free -h; df -h / /mnt/data
ss -tulpn | grep -vE '127\.0\.0\.1|\[::1\]'
tailscale status
sudo ufw status verbose; sudo iptables -S | head -40
sudo sshd -T | grep -Ei '^(port|permitrootlogin|passwordauthentication|allowusers)'
for s in docker fail2ban auditd unattended-upgrades xrdp rpcbind; do \
  printf '%-22s %s %s\n' "$s" "$(systemctl is-active $s)" "$(systemctl is-enabled $s)"; done
```
