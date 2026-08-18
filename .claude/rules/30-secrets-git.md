# Rule 30 — Secrets, git, and reproducibility

## The reproducibility target

> The server is rebuildable from: this git repo + the secrets store + the
> documented external dependencies (DNS, domain registrar, Brevo account).

If something is needed to rebuild and lives only in someone's head or only on
the running box, that is a defect. Write it into `docs/`.

## Committed vs not

**Committed:**
- All compose files, nginx configs, Prometheus/Alertmanager/Grafana provisioning
- `.env.example` for every project — every key present, every value blank
- Scripts, systemd units, logrotate/auditd/journald configs
- `docs/`, `CLAUDE.md`, `instructions.md`, `.claude/`
- `docs/context/audit/*.jsonl` (already redacted)

**Never committed:**
- `.env`, `*.key`, `*.pem`, `certs/`, `secrets/`
- Postgres data, Prometheus TSDB, Grafana `grafana.db`
- Backup archives
- Guacamole TOTP seeds or recovery codes

`.gitignore` enforces this. Verify before the first push:

```bash
git ls-files | grep -Ei '\.env$|\.key$|\.pem$|secret|credential'   # must be empty
```

## If a secret is committed

Rotate it. Do not "remove it in the next commit" — it is in the object store
and, if pushed, in every clone and possibly in provider caches. Order:

1. Rotate the credential at the source (Brevo, Grafana admin, Postgres).
2. Update the running `.env` and restart the affected service.
3. Then, optionally, rewrite history.
4. Note the incident in `docs/context/DECISIONS.md` with the rotation date.

## Secret handling on this host

Simplest secure option for a single-node Compose deployment:
`.env` files with `chmod 600`, owned by the deploying user, injected via
`env_file:`. Docker *swarm* secrets are not available outside swarm mode, and
mounting a secrets file adds moving parts without adding much here.

Requirements either way:
- `chmod 600` on every `.env`; verify with `find /opt/server -name '.env' -not -perm 600`.
- No secret passed on a command line (it lands in shell history and `ps`).
- No secret in a compose `environment:` block in a committed file.
- Secrets are backed up **encrypted**, separately from the repo, with the
  passphrase stored somewhere the VPS dying does not take with it.

## Commit cadence — commit after every major action

Do not batch a session's work into one commit at the end. On a single-node
platform the commit *is* the rollback point, and a rollback point that covers
six unrelated changes cannot be used.

**Commit immediately after each of these**, without being asked:

| Trigger | Example message |
|---|---|
| A deployment phase completes | `phase-3: nginx serving 443 with staging cert` |
| A service is added or its compose file changes | `monitoring: add alertmanager, 128M limit, healthcheck` |
| Config that affects behaviour is edited | `nginx: json_main log format + request_id propagation` |
| A decision is recorded | `docs: D-007 prometheus retention 30d` |
| Rules, hooks, or skills change | `rules: require commit after every major action` |
| Discovery changes a documented fact | `docs: ENVIRONMENT — ufw inactive, OCI SL is the only filter` |
| Before starting anything risky | `checkpoint before firewall change` |
| A checkpoint is taken | `checkpoint: <what changed>` |

Rules:

- **Config change and its `DECISIONS.md` entry go in the same commit.** A diff
  without its reasoning is nearly useless six months later.
- Never commit a broken intermediate state as "wip". If it does not validate
  (`nginx -t`, `docker compose config`), fix it or stash it.
- Run the secret scan before any commit that touches a new directory.
- Tag at phase boundaries: `phase-3-nginx`, `phase-5-monitoring`, …
- `git push` still requires the user to ask. Committing is automatic; publishing
  is not.

## Remote — private GitHub repository

The remote is **not configured yet**. It will be a **private** GitHub repo.

Before the first push:

1. Confirm the repo is private — this tree documents a live server's topology,
   firewall posture, and open weaknesses. Public would be an own goal.
2. Run the full scan: `git ls-files | grep -Ei '(^|/)\.env$|\.key$|\.pem$|/certs?/'`
   and `.claude/skills/session-continuity/scripts/checkpoint.sh`.
3. Review `docs/context/audit/*.jsonl` — redacted, but confirm rather than assume.
4. Only then `gh repo create <name> --private --source=. --push`.

Until the remote exists, the repo is local-only, which means **a disk failure
loses everything**. Treat `export-bundle.sh` output as the interim off-box copy.

## Branching and rollback

- `main` is what is deployed. A change is reviewed as a diff before it is
  applied to the server.
- Tag before each phase completes: `phase-3-nginx`, `phase-5-monitoring`, …
  Rollback is then `git checkout <tag> -- <project>/ && docker compose up -d`.
- Commit messages state the phase and the observable effect, not just the file.
- Config changes and the `DECISIONS.md` entry explaining them go in the **same**
  commit. A decision found six months later without its diff is nearly useless.

## Commit hygiene

Do not commit or push unless asked. When asked, run the secret scan above first.
