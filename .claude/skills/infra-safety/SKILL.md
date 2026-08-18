---
name: infra-safety
description: Use before and after any change to this production VPS — deploying or restarting a container, editing nginx/sshd/firewall/TLS config, opening a port, pulling a new image, changing DNS, running a backup or restore, or completing a deployment phase. Also use when asked to verify the server is safe, audit exposed ports, or check whether a change is reversible. Provides the pre-flight gate, the post-change verification, and the per-phase acceptance checks.
---

# Infrastructure safety gate

This host is the live, internet-facing production server. There is no staging.
The cost of a mistake is measured in lockouts and downtime, not in a failed
test run.

Read `.claude/rules/00-safety.md` for the change-class table and the lockout
protocol. This skill is the procedure that table implies.

## Pre-flight — before any mutating change

Answer all five, out loud, before running anything:

1. **What exactly changes?** Name the files, services, and ports. "Update
   nginx" is not an answer; "add `conf.d/monitoring.conf`, reload nginx" is.
2. **What breaks if this is wrong?** Which routes stop serving, which users are
   locked out, what data is at risk.
3. **How do I undo it?** A concrete command, not "revert the change". If the
   undo requires access that the change itself could remove, the sequence is
   wrong — fix the sequence.
4. **What proves it worked?** A command whose output distinguishes success from
   failure. `docker ps` showing `Up` does not.
5. **Is a backup current?** For anything touching Postgres, Grafana's DB, or
   certificates.

Then capture current state before mutating:

```bash
TS=$(date -u +%Y%m%dT%H%M%SZ)
cp <config> <config>.bak-$TS                  # config files
docker compose config > /tmp/compose-$TS.yml  # resolved compose
sudo ufw status numbered | tee /tmp/ufw-$TS.txt
ss -tulpn | tee /tmp/ports-$TS.txt
```

Validate before applying, every time the tool offers it:

```bash
nginx -t                                   # or: docker compose exec nginx nginx -t
sudo sshd -t -f /etc/ssh/sshd_config
docker compose config -q
promtool check config prometheus.yml
promtool check rules rules/*.yml
amtool check-config alertmanager.yml
```

## Post-change — immediately after

```bash
# 1. Is it serving, not merely running?
curl -fsS -o /dev/null -w '%{http_code} %{time_total}s\n' https://<domain>/
docker compose ps --format 'table {{.Name}}\t{{.State}}\t{{.Status}}'

# 2. Did anything start crash-looping? (restart count climbing = trouble)
docker ps --format '{{.Names}}' | xargs -I{} sh -c \
  'printf "%-24s restarts=%s\n" {} $(docker inspect -f "{{.RestartCount}}" {})'

# 3. Errors in the change window?
docker compose logs --since 5m 2>&1 | grep -iE 'error|fatal|panic|denied' | head -30
sudo journalctl --since '5 min ago' -p warning --no-pager | tail -30

# 4. Did the change expose anything?  (the check that matters most)
ss -tulpn | grep -vE '127\.0\.0\.1|\[::1\]'
docker ps --format '{{.Names}}\t{{.Ports}}'
```

Compare port output against the pre-flight capture. **Any new non-loopback
listener that was not deliberately added is an incident**, not a curiosity —
see the UFW/Docker trap in `.claude/rules/20-docker-infra.md`.

## Lockout-capable changes

For sshd, firewall, TLS, MFA, or DNS, follow the protocol in
`.claude/rules/00-safety.md`: second session open and idle, change applied in
the first, login verified from a **third** new session before anything is
closed. Additionally:

- **sshd:** `sudo sshd -t` must pass before reload. Reload, never restart, and
  never disable password auth in the same step that installs the key — install
  and verify the key first, disable passwords second.
- **Firewall:** allow the current source IP explicitly before enabling
  default-deny. Know the provider's console/VNC recovery path *before* you need it.
- **TLS:** issue against Let's Encrypt **staging** first. Rate limits on
  production are low enough to block you for a week after a few failed attempts.
- **MFA:** enrol and verify a second admin account before enforcing TOTP, and
  store recovery codes outside the box.

## Phase completion gate

A deployment phase is not done until all of these pass:

```
[ ] Validator passes (nginx -t / promtool / sshd -t / compose config)
[ ] Endpoint returns the expected status from OUTSIDE the host
[ ] No unintended non-loopback listener (diffed against pre-flight)
[ ] Container has CPU limit, memory limit, healthcheck, logging limits
[ ] Healthcheck is `healthy`, not just `starting`
[ ] Restart count is 0 after 10 minutes
[ ] Logs are in the canonical JSON shape (rule 10) where we control the format
[ ] Prometheus scrapes it / a blackbox check covers it
[ ] Reboot test passed, or explicitly deferred to the phase that does it
[ ] Secrets are 0600 and untracked by git
[ ] STATE.md and DECISIONS.md updated; changes committed and tagged
```

## Reboot recovery test

The single most valuable test on a single-node platform, because it is the one
failure that is certain to happen eventually.

```bash
# before
docker ps --format '{{.Names}}' | sort > /tmp/before-reboot.txt
sudo reboot
# after reconnecting, give it 2-3 minutes
docker ps --format '{{.Names}}' | sort > /tmp/after-reboot.txt
diff /tmp/before-reboot.txt /tmp/after-reboot.txt   # must be empty
curl -fsS -o /dev/null -w '%{http_code}\n' https://<domain>/
```

Anything that does not come back on its own is a missing `restart:` policy, a
missing external network, a missing systemd unit, or a dependency ordering bug.
Fix it and re-test — a platform that needs a human after every reboot is not
finished.

## Stop and ask the user when

- The undo step is not obvious, or depends on access the change could remove.
- The change touches sshd, the firewall, DNS, or MFA and no second access path
  is confirmed open.
- A port would become publicly reachable that was not in the agreed port matrix.
- Restoring from a backup would be needed to recover, and no restore has ever
  been tested.
- The command is outside the currently approved deployment phase.
