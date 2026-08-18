# Host firewall

Managed as plain iptables restored by `netfilter-persistent`. **UFW is never
enabled on this host** — see `docs/context/DECISIONS.md` D-009.

## Do NOT run `netfilter-persistent save`

It snapshots the *live* tables, which include chains that Docker (`DOCKER*`)
and Tailscale (`ts-input`, `ts-forward`) create at runtime and recreate on
every start. Saving them produces duplicate and stale rules on the next
restore. `rules.v4` deliberately contains only the rules **we** own.

To change the firewall: edit `rules.v4` here, copy it to `/etc/iptables/`,
then `sudo netfilter-persistent reload`. Keep a second session open.

## Expected live-vs-persisted delta

`iptables -S INPUT` will show one extra line that is not in `rules.v4`:

```
-A INPUT -j ts-input
```

That is Tailscale, inserted at runtime. It is correct. Any *other* difference
means live and persisted state have drifted and should be investigated.

## Current policy

Default-deny via the trailing REJECT. Open: 22 (reached over Tailscale only —
OCI has no ingress rules). Ports 80 and 443 are added at **Phase 11**, public
launch — not before.
