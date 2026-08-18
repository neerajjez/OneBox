# test-website

Validates the delivery chain — `TLS -> nginx -> Docker network -> app`. It is
scaffolding and deliberately disposable; the real portfolio is out of scope
(`docs/PLAN.md` §9, §16).

- **Node 22 alpine, zero dependencies.** No framework, no database, no
  lockfile. Chosen to be boring: its job is to be the component that is
  definitely *not* the problem when something else breaks.
- Emits the canonical log event (rule 10) — the reference implementation for
  every service we write ourselves.
- Echoes `X-Request-Id` back so nginx->app propagation is provable in one
  request rather than inferred.
- `read_only` rootfs, `cap_drop: ALL`, non-root, no published port.

Routes: `/` renders the status page, `/healthz` returns JSON (used by the
container healthcheck). Note `/healthz` through nginx hits *nginx's* health
endpoint, not this one — they are separate liveness signals by design.

Future direction, **not now**: Astro + TypeScript + Tailwind + MDX built to
static output, served by this same nginx.
