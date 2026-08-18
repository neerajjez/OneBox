#!/usr/bin/env bash
# Per-container CPU/memory attribution -> node_exporter textfile collector.
#
# WHY NOT cADVISOR
# ----------------
# cAdvisor v0.49.1 was tried first and does not work on this host. Docker 29
# uses the containerd image store, so /var/lib/docker/image/overlayfs/layerdb
# does not exist and cAdvisor's docker handler cannot map a cgroup to a
# container name:
#
#   failed to identify the read-write layer ID for container "b62e5be…"
#   open /rootfs/mnt/data/docker/image/overlayfs/layerdb/mounts/…: no such file
#
# Pointing it at containerd directly (--containerd + --containerd-namespace=moby)
# did not help either: it emitted cgroup ids with no name label, which is
# useless for attribution. Same root cause as D-017 — Docker 29 moved image
# storage and tooling that assumes the old layout silently half-works.
#
# `docker stats` asks the daemon, so it is immune to all of that. It costs one
# API call every 30s and answers exactly the question cAdvisor was added for:
# which container is using the CPU and memory. What it does NOT give is
# per-container disk I/O or network history at cAdvisor's granularity — an
# accepted trade for something that actually reports names.

set -uo pipefail

OUT_DIR="/var/lib/node_exporter/textfile_collector"
OUT="$OUT_DIR/container_stats.prom"
TMP="$OUT.$$"

[[ -d "$OUT_DIR" ]] || exit 0

# --no-stream: one sample and exit. Without it this blocks forever.
# The format is tab-separated so a container name containing a space cannot
# shift the columns.
STATS=$(timeout 25 docker stats --no-stream \
          --format '{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.MemPerc}}' 2>/dev/null)

if [[ -z "$STATS" ]]; then
  # Emit nothing rather than a file full of zeros: absent() in the alerting
  # rules can then distinguish "collector broken" from "containers idle".
  # Writing zeros would be indistinguishable from a genuinely idle host.
  exit 0
fi

# "1.234GiB / 2GiB" -> bytes. docker stats uses binary units with an iB suffix.
to_bytes() {
  local v="${1//[[:space:]]/}"
  local num="${v%%[A-Za-z]*}" unit="${v##*[0-9.]}"
  case "$unit" in
    B)          awk -v n="$num" 'BEGIN{printf "%.0f", n}' ;;
    KiB|kB|KB)  awk -v n="$num" 'BEGIN{printf "%.0f", n*1024}' ;;
    MiB|MB)     awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024}' ;;
    GiB|GB)     awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024}' ;;
    TiB|TB)     awk -v n="$num" 'BEGIN{printf "%.0f", n*1024*1024*1024*1024}' ;;
    *)          echo 0 ;;
  esac
}

{
  echo '# HELP container_cpu_percent Container CPU usage, percent of one core times cores.'
  echo '# TYPE container_cpu_percent gauge'
  while IFS=$'\t' read -r name cpu mem memp; do
    [[ -z "$name" ]] && continue
    printf 'container_cpu_percent{name="%s"} %s\n' "$name" "${cpu%\%}"
  done <<< "$STATS"

  echo '# HELP container_memory_bytes Container memory working set.'
  echo '# TYPE container_memory_bytes gauge'
  while IFS=$'\t' read -r name cpu mem memp; do
    [[ -z "$name" ]] && continue
    printf 'container_memory_bytes{name="%s"} %s\n' "$name" "$(to_bytes "${mem%%/*}")"
  done <<< "$STATS"

  echo '# HELP container_memory_limit_bytes Container memory limit.'
  echo '# TYPE container_memory_limit_bytes gauge'
  while IFS=$'\t' read -r name cpu mem memp; do
    [[ -z "$name" ]] && continue
    printf 'container_memory_limit_bytes{name="%s"} %s\n' "$name" "$(to_bytes "${mem##*/}")"
  done <<< "$STATS"

  # Restart count is the cheap early warning for a service that is crash-looping
  # while still passing its healthcheck between restarts.
  echo '# HELP container_restart_count Times the container has been restarted.'
  echo '# TYPE container_restart_count gauge'
  for c in $(docker ps --format '{{.Names}}' 2>/dev/null); do
    rc=$(docker inspect -f '{{.RestartCount}}' "$c" 2>/dev/null || echo 0)
    printf 'container_restart_count{name="%s"} %s\n' "$c" "${rc:-0}"
  done

  echo '# HELP container_stats_scrape_timestamp_seconds When this file was written.'
  echo '# TYPE container_stats_scrape_timestamp_seconds gauge'
  echo "container_stats_scrape_timestamp_seconds $(date +%s)"
} > "$TMP" && mv "$TMP" "$OUT" && chmod 644 "$OUT"
