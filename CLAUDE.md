# Project: OneBox — single-server production platform

Single-server, Docker-based, internet-facing platform. Nginx terminates TLS and
is the only public entry point; monitoring, remote desktop, and the site sit
behind it on internal Docker networks.

**If you are running this on the deployment target, commands here touch
production.** Read `docs/context/STATE.md` for current truth before acting.

## Fill these in for your host

Replace this table with facts you have **verified**, not assumed. Record how you
verified them — the method matters as much as the value, and getting it wrong
here costs hours later.

| | |
|---|---|
| Host | `<hostname>`, Ubuntu 24.04 |
| Arch | `<arm64 or amd64>` — every image must have a matching manifest |
| CPU / RAM | `<n>` vCPU / `<n>` GiB · swap `<n>` GiB, `swappiness=10` |
| Disks | `/` `<size>` · `<DATA_ROOT>` `<size>` — Docker, containerd, data, backups |
| Docker | `<version>`; `<admin user>` in the `docker` group |
| Storage | Docker data-root **and containerd root** on the large disk |
| Firewall | plain iptables via `netfilter-persistent`. UFW is never enabled |
| Exposure | Public IP `<addr>`; 443 restricted to Cloudflare ranges — cloud firewall **and** `DOCKER-USER` |

> **Determining public reachability:** read the nginx access log for inbound
> connections from addresses you did not originate. Cloud metadata and
> `curl ifconfig.me` answer a *different* question — the first can omit a
> 1:1-NAT address entirely, the second only tells you where egress appears from.

## Non-negotiable rules

1. **Plan before touching production.** No install, no config write, no
   container start outside an approved change. Ask if it is unclear.
2. **Never lock yourself out.** SSH, firewall, and MFA changes require a
   verified second access path open *before* the change, and a written rollback.
3. **Secrets never reach git or a log.** `.env` files are gitignored; only
   `.env.example` is committed. Hooks redact, but do not rely on that.
4. **Every container declares** CPU limit, memory limit + reservation,
   `restart:`, a healthcheck that proves it *serves*, logging limits, network,
   and an explicit ports decision. See `.claude/rules/20-docker-infra.md`.
5. **Only 443 is public.** Backends use `expose:`, never `ports:`.
   Docker bypasses UFW — see `.claude/rules/20-docker-infra.md`.
6. **One canonical log shape** for everything we write. See
   `.claude/rules/10-logging-audit.md`.
7. **Record as you go.** Decisions in `docs/context/DECISIONS.md`, state in
   `docs/context/STATE.md`, before the turn ends. Hooks capture the transcript;
   they cannot capture *why*.
8. **Commit after every major action** — a change complete, a service added, a
   config edited, a decision recorded, or before anything risky. The commit is
   the rollback point. Config and its `DECISIONS.md` entry go in the *same*
   commit. See `.claude/rules/30-secrets-git.md`.
9. **A backup is not a backup until a restore has been tested.**

## Context store

`docs/context/` is canonical and portable — that is the whole point of this
layout. Any assistant memory holds pointers into it, so switching machines,
accounts, or tools loses nothing.

Read `CONTRIBUTING.md` for the operating procedure.
