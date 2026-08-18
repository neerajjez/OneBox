# Working on OneBox

## Before changing anything on a live server

```bash
./scripts/preflight.sh
```

State what changes, what could break, and how to undo it — in that order.
Capture current state first (`cp file file.bak-$(date -u +%Y%m%dT%H%M%SZ)`).
Prefer validate-then-apply: `nginx -t`, `docker compose config`, `sshd -t`,
`promtool check config`.

## After

Re-run the validator. Then check the service is **serving**, not merely
running — hit the endpoint, do not trust `Up`. Then check logs for the change
window. Then record the outcome in `docs/context/STATE.md` and the *why* in
`docs/context/DECISIONS.md`.

## Adding a service

Ten things get decided before it is added, not after:

1. CPU limit
2. Memory limit **and reservation**
3. `restart:` policy
4. A healthcheck that proves it **serves**, not that a PID exists
5. Logging limits
6. Network membership (`backend-net` unless nginx proxies to it directly)
7. Port exposure — `expose:`, never `ports:`, unless it is nginx
8. Backup requirement, or an explicit "rebuildable, no backup"
9. Monitoring: a scrape target or a blackbox probe
10. Security posture: user, capabilities, read-only rootfs, `no-new-privileges`

Missing any one of these is a blocker, not a follow-up.

Also verify the image has a manifest for your architecture **before** planning
around it:

```bash
docker manifest inspect <image>:<tag> | jq -r '.manifests[].platform.architecture'
```

## Lockout-capable changes

SSH, firewall, TLS, DNS, MFA, disk. Open a second session and leave it idle.
Apply the change in the first. Verify login in a **third**. Only then close
anything.

## Commits

Commit after every meaningful change, not in one batch at the end. On a single
node the commit is the rollback point, and a rollback point covering six
unrelated changes cannot be used.

Config changes and their `DECISIONS.md` entry go in the **same commit**. A diff
without its reasoning is nearly useless six months later.

Run the secret scan before any commit touching a new directory:

```bash
git ls-files | grep -Ei '(^|/)\.env$|\.key$|\.pem$|/certs?/'   # must be empty
```
