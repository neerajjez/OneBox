# Reaching THIS host from a Kasm workspace

The RDP/SSH target is **this OCI instance itself** — the machine Kasm runs on —
not `your-laptop` (the laptop). This corrects O-003, which had assumed the
laptop was the target.

## The addresses to use

From inside a Kasm workspace container, `localhost` is the **container**, not
the host. The host is reachable on the Kasm bridge gateway:

| Target | Address from a workspace |
|---|---|
| This host's XFCE desktop (xrdp) | `172.20.0.1:3389` |
| This host's shell (SSH) | `172.20.0.1:22` |

`172.20.0.1` is the gateway of `kasm_default_network`. Do **not** use
`127.0.0.1` or `localhost` — those resolve to the workspace container.

## Firewall rules that make this work

The host firewall is default-deny, so both paths needed explicit rules:

```
-A INPUT -s 172.20.0.0/16 -d 172.20.0.1/32 -p tcp --dport 3389 \
   -m comment --comment "kasm-workspace->host-xrdp" -j ACCEPT
-A INPUT -p tcp -m state --state NEW --dport 22 -j ACCEPT      (pre-existing)
```

The RDP rule is scoped to source subnet **and** destination address **and**
port — it does not reopen 3389 to anything else. The stale wide-open 3389 rule
removed in Phase 1 has not come back.

**Security note, stated plainly:** this deliberately lets a Kasm workspace
container reach the host's RDP and SSH. A workspace is the least-trusted thing
on this box (threat T4), so this is a real widening of the blast radius of a
workspace compromise. It is the functionality that was asked for, and the rule
is as narrow as it can be while still providing it — but it is a conscious
trade, not an oversight.

## How to actually connect

**Remmina** (enabled) is a browser-based RDP/SSH client:

1. `https://<host>/webrdp/` → launch **Remmina**
2. New connection → RDP → `172.20.0.1:3389`
3. Log in with your normal host credentials (`prodadmin`)

**Terminal** (enabled) for a shell:

1. Launch **Terminal**
2. `ssh prodadmin@172.20.0.1`
3. Key auth only — password auth is disabled on this host (§17), so the
   workspace needs a key that is in `~prodadmin/.ssh/authorized_keys`.

**Ubuntu Noble** is also enabled if you want a full desktop *inside* Kasm
rather than a view of this host's desktop.

## If the gateway address ever changes

`kasm_default_network` is created by Kasm's installer without a pinned subnet,
so a reinstall could allocate a different range. Re-check with:

```bash
docker network inspect kasm_default_network --format '{{range .IPAM.Config}}{{.Gateway}}{{end}}'
```

and update the firewall rule to match. Our own `backend-net` is pinned
(172.19.0.0/24) precisely to avoid this class of drift; Kasm's is not ours to
pin without editing installer-owned config.
