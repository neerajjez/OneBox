# Kasm resource measurements (D-007 gate)

Measured 2026-08-16 on onebox-prod (2 vCPU / 11.9 GB / 4 GB swap, aarch64).

## The concern

`docs/PLAN.md` §22 / D-007: Kasm's published minimum is 2 cores / 4 GB — the
whole machine — and its default workspace wants **2768 MB and 2 cores**. The
predicted failure was a workspace launch driving the host into OOM and taking
Prometheus with it.

## What we changed before measuring

| | Kasm default | Ours |
|---|---|---|
| Workspace cores | 2.0 | **1.0** |
| Workspace memory | 2768 MB | **2048 MB** |
| Service memory limits | none at all | **3456 MB total** (D-015) |

## Measured, with one Terminal workspace running

| Component | Usage | Limit |
|---|---|---|
| Workspace (`adminkasm.lo_*`) | **556 MiB** | 2048 MB |
| kasm_api | 318 MiB | 768 MB |
| kasm_manager | 293 MiB | 640 MB |
| kasm_guac | 80 MiB | 512 MB |
| kasm_share | 65 MiB | 256 MB |
| kasm_db | 53 MiB | 512 MB |
| kasm_agent | 36 MiB | 512 MB |
| kasm_proxy | 7 MiB | 128 MB |
| kasm_redis | 2 MiB | 128 MB |
| **Kasm total** | **~1410 MiB** | 5504 MB |

**Host: 3127 MB used of 11927. 8799 MB available. Swap 1 MB.**

Monitoring during the launch: **0 OOM kills, 0 restarts, 5/5 targets up.**

## Verdict

**The gate passes.** The predicted failure did not materialise, because the
allocation was reduced first. At Kasm's defaults (2 cores + 2768 MB per session,
services uncapped) the picture would have been very different on 2 vCPU.

Headroom supports roughly **one interactive workspace**, which matches the §22
plan. Do not raise the workspace allocation without re-measuring.

## First-launch timeout — a real operational gotcha

The **first** launch of a newly pulled image FAILED:

```
Failed to start container ... UnixHTTPConnectionPool: Read timed out (read timeout=60)
```

Unpacking a 3.9 GB image on 2 vCPU exceeded the agent's 60-second Docker API
timeout. It left an orphaned container in `Created` state, and the next attempt
returned "No resources are available" until that was cleared.

The **second** launch, with layers already unpacked, took **1 second**.

So: pre-pull any workspace image before a user needs it
(`docker pull <image>`), or the first person to launch it gets a failure and a
stuck session. This is not a resource shortage — it is a cold-start cost.
