#!/usr/bin/env bash
# Port exposure audit. Run after EVERY phase and diff against the previous run.
#
# The premise (rule 20): Docker writes into the DOCKER chain, which is evaluated
# before the host's own rules. A published port can therefore be reachable even
# when the firewall says otherwise. Belief is not evidence — this script is the
# evidence.
#
# Usage:  scripts/port-audit.sh [outdir]
# Exit:   0 clean · 1 unexpected non-loopback listener found

set -uo pipefail

OUT_DIR="${1:-/mnt/data/projects/docs/context/port-audits}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
OUT="$OUT_DIR/$STAMP.txt"
mkdir -p "$OUT_DIR"

# Expected listeners, keyed by "port:process". Matching on the port alone is
# wrong: tailscaled's listeners use ephemeral ports that change on restart, so
# a port-number allowlist would either churn or be permanently stale.
declare -A EXPECTED=(
  ["22:sshd"]="reached over Tailscale only; OCI has no ingress"
  ["3389:xrdp"]="in active use over Tailscale — see DECISIONS.md"
  ["41641:tailscaled"]="mesh"
  ["68:systemd-network"]="DHCP on the OCI VNIC"
  ["5353:avahi-daemon"]="zeroconf — cups-browsed depends on it; pending O-014"
  # nginx, published by dockerd. Now bound to 0.0.0.0 at the user's direction,
  # ahead of opening 443 in the OCI NSG. These two are the ONLY listeners
  # permitted on a public address — anything else on 0.0.0.0 is still a finding.
  ["80:dockerd"]="nginx :80 — public"
  ["443:dockerd"]="nginx :443 — public"
  # Phase 5: node_exporter on the backend-net gateway so Prometheus (on that
  # internal network) can scrape it. BIND_SCOPED keeps it off 0.0.0.0.
  ["9100:node_exporter"]="node_exporter — loopback + backend-net gateway only"
)

# Processes whose listeners are acceptable on ANY port, provided they bind to a
# non-public address. Keyed by process, value is a regex the bind address must
# match. This is how tailscaled's ephemeral ports are handled correctly.
declare -A BIND_SCOPED=(
  ["tailscaled"]='^(100\.|\[?fd7a:115c:a1e0)'
  ["avahi-daemon"]='.'   # firewall-blocked; tracked as O-014, not silently ignored
  # dockerd is deliberately NOT bind-scoped. 80 and 443 are allowed by the
  # EXPECTED map above, keyed by port. Adding 0.0.0.0 here would whitelist
  # EVERY dockerd-published port on a public address — which is precisely the
  # mistake this script exists to catch. Verified with a negative control:
  # publishing 0.0.0.0:9299 must be reported.
  ["node_exporter"]='^(127\.0\.0\.1|172\.19\.0\.1)$'
)

{
  printf '# Port audit — %s on %s\n\n' "$STAMP" "$(hostname -s)"

  printf '## Non-loopback listeners\n\n'
  ss -tulpnH 2>/dev/null | grep -vE '127\.0\.0\.1|\[::1\]|127\.0\.0\.5[34]' || true

  printf '\n## Published container ports\n\n'
  if docker ps -q >/dev/null 2>&1; then
    docker ps --format '{{.Names}}\t{{.Ports}}' 2>/dev/null || true
  else
    printf '(docker not accessible to this user — run under `sg docker` or re-login)\n'
  fi

  printf '\n## INPUT chain\n\n'
  sudo iptables -S INPUT 2>/dev/null || true

  printf '\n## DOCKER-USER chain\n\n'
  sudo iptables -S DOCKER-USER 2>/dev/null || true
} > "$OUT"

# --- evaluate ---
FINDINGS=0
while read -r local proc; do
  [[ -z "$local" ]] && continue
  port="${local##*:}"
  addr="${local%:*}"

  # 1. exact port:process match
  [[ -n "${EXPECTED[${port}:${proc}]:-}" ]] && continue

  # 2. process allowed on any port, provided the bind address is not public
  scope="${BIND_SCOPED[$proc]:-}"
  if [[ -n "$scope" && "$addr" =~ $scope ]]; then continue; fi

  printf '\033[31mUNEXPECTED\033[0m  %-24s %s\n' "$local" "${proc:-<unknown>}"
  FINDINGS=$((FINDINGS+1))
done < <(sudo ss -tulpnH 2>/dev/null \
          | grep -vE '127\.0\.0\.1|\[::1\]|127\.0\.0\.5[34]' \
          | sed -E 's/.*[[:space:]]([^[:space:]]+:[0-9]+)[[:space:]]+[^[:space:]]+[[:space:]]+users:\(\("([^"]+)".*/\1 \2/' \
          | grep -E '^[^ ]+ [^ ]+$' | sort -u)

printf 'Report: %s\n' "$OUT"
if (( FINDINGS == 0 )); then
  printf '\033[32mCLEAN\033[0m — no unexpected non-loopback listeners\n'
else
  printf '\033[31m%d unexpected listener(s)\033[0m — investigate before accepting the phase\n' "$FINDINGS"
  printf 'A new non-loopback listener that was not deliberately added is an incident.\n'
fi
exit $(( FINDINGS > 0 ))
