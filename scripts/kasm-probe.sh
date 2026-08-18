#!/usr/bin/env bash
# Kasm availability probe -> node_exporter textfile metrics.
#
# Kasm 1.17.0 exposes NO Prometheus endpoint (/metrics, /api/metrics and
# /api/public/metrics all 404). docs/PLAN.md §26c anticipated this and said not
# to build a bespoke exporter — so this is a probe, not an exporter: it answers
# "is it serving" and "are the containers healthy", nothing more.
#
# Deliberately probes THROUGH nginx at /webrdp/, so it exercises the same path
# a user does. A container that is healthy but unreachable through the proxy is
# still an outage.
#
# Run every minute by kasm-probe.timer.

set -uo pipefail

OUT_DIR="/var/lib/node_exporter/textfile_collector"
OUT="$OUT_DIR/kasm.prom"
TMP="$OUT.$$"
URL="https://127.0.0.1/webrdp/api/__healthcheck"

[[ -d "$OUT_DIR" ]] || exit 0

# --- serving through the proxy? ---
start=$(date +%s%3N)
body=$(curl -sk --max-time 10 "$URL" 2>/dev/null)
code=$(curl -sk --max-time 10 -o /dev/null -w '%{http_code}' "$URL" 2>/dev/null)
dur=$(( $(date +%s%3N) - start ))

up=0
[[ "$code" == "200" ]] && echo "$body" | grep -q '"ok"' && up=1

# --- container health ---
healthy=0; total=0; restarts=0
while read -r name; do
    [[ -z "$name" ]] && continue
    total=$((total+1))
    st=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$name" 2>/dev/null)
    [[ "$st" == "healthy" || "$st" == "running" ]] && healthy=$((healthy+1))
    rc=$(docker inspect -f '{{.RestartCount}}' "$name" 2>/dev/null || echo 0)
    restarts=$((restarts + ${rc:-0}))
done < <(docker ps -a --filter 'name=kasm_' --format '{{.Names}}' 2>/dev/null)

sessions=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -c 'kasm\.lo' || true)

# --- xrdp health ---
# Orphaned X sessions are what make xrdp "work sometimes": a dead session's
# D-Bus/agent blocks the next login, and the symptom is the session closing
# immediately after a correct password. Counting them makes that visible
# BEFORE a user hits it.
xrdp_live=$(pgrep -c -f '^/usr/lib/xorg/Xorg :1[0-9]' 2>/dev/null || echo 0)
xrdp_orphans=0
for lock in /tmp/.X*-lock; do
    [ -e "$lock" ] || continue
    d="${lock#/tmp/.X}"; d="${d%-lock}"
    case "$d" in (*[!0-9]*|'') continue;; esac
    pgrep -f "Xorg :${d}\b" >/dev/null 2>&1 || xrdp_orphans=$((xrdp_orphans+1))
done

{
  echo '# HELP kasm_up Kasm reachable through nginx at /webrdp/ (1 = serving).'
  echo '# TYPE kasm_up gauge'
  echo "kasm_up $up"
  echo '# HELP kasm_probe_duration_ms Round-trip of the /webrdp/ healthcheck.'
  echo '# TYPE kasm_probe_duration_ms gauge'
  echo "kasm_probe_duration_ms $dur"
  echo '# HELP kasm_containers_healthy Kasm service containers healthy or running.'
  echo '# TYPE kasm_containers_healthy gauge'
  echo "kasm_containers_healthy $healthy"
  echo '# HELP kasm_containers_total Kasm service containers defined.'
  echo '# TYPE kasm_containers_total gauge'
  echo "kasm_containers_total $total"
  echo '# HELP kasm_container_restarts_total Cumulative restarts across Kasm containers.'
  echo '# TYPE kasm_container_restarts_total counter'
  echo "kasm_container_restarts_total $restarts"
  echo '# HELP kasm_workspace_sessions Active workspace containers.'
  echo '# TYPE kasm_workspace_sessions gauge'
  echo "kasm_workspace_sessions ${sessions:-0}"
  echo '# HELP xrdp_sessions Live xrdp X servers.'
  echo '# TYPE xrdp_sessions gauge'
  echo "xrdp_sessions ${xrdp_live:-0}"
  echo '# HELP xrdp_orphan_locks Stale X lock files with no matching Xorg process.'
  echo '# TYPE xrdp_orphan_locks gauge'
  echo "xrdp_orphan_locks ${xrdp_orphans:-0}"
} > "$TMP" && mv "$TMP" "$OUT" && chmod 644 "$OUT"
