# Rule 00 — Production safety

This is a live, internet-facing box with no out-of-band console guaranteed.
Treat every command as irreversible until proven otherwise.

## Change classes

| Class | Examples | Gate |
|---|---|---|
| **Read** | `docker ps`, `ss -tulpn`, `journalctl`, reading configs | Free |
| **Additive** | new file in a project dir, new compose service, new nginx `conf.d` file | State intent, then do |
| **Mutating** | restart a service, edit an existing config, pull a new image | Announce + rollback plan + verify after |
| **Lockout-capable** | sshd, ufw/nftables, TLS, MFA, DNS, disk/partition | Second access path open, written rollback, explicit user go-ahead |

`.claude/hooks/guard-destructive.sh` enforces the floor of this table. It
denies disk/firewall/sshd destruction outright and forces a prompt on volume
deletion, reboots, force-push, and `curl | sh`. The hook is a backstop, not
permission to be careless.

## Before any mutating change

1. State what changes, what could break, and how to undo it — in that order.
2. Capture the current state first (`cp file file.bak-$(date -u +%Y%m%dT%H%M%SZ)`,
   `docker compose config > …`, `ufw status numbered`).
3. Prefer validate-then-apply: `nginx -t`, `docker compose config`,
   `sshd -t`, `promtool check config`.

## After any mutating change

1. Re-run the validator.
2. Check the service is actually serving, not merely running — hit the
   endpoint, do not trust `Up`.
3. Check logs for the change window.
4. Record the outcome in `docs/context/STATE.md`; record the *why* in
   `docs/context/DECISIONS.md`.

## Lockout protocol (SSH, firewall, MFA)

Never close the current session while making the change. Open a second SSH
session and keep it idle. Apply the change in the first. Verify login in a
**third**, new session. Only then close anything. For firewall work, stage a
`ufw` rule allowing the current source IP before enabling default-deny, and
know the VPS provider's web console recovery path in advance.

## Never do

- Run a destructive command "to see what happens".
- Disable a security control to make something work, intending to re-enable later.
- Use `latest` image tags in a deployed compose file.
- Delete or rewrite `docs/context/audit/*.jsonl` — it is append-only.
- Commit a real secret, then remove it in a later commit. Rotate it instead.
