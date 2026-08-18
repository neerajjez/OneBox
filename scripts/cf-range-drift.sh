#!/usr/bin/env bash
# Detect drift between Cloudflare's published IP ranges and the list this host
# actually allows through the firewall.
#
# WHY THIS MATTERS (the failure it prevents)
# ------------------------------------------
# Once ingress on 443 is restricted to Cloudflare's ranges, that allowlist is a
# hardcoded copy of a list Cloudflare controls and occasionally changes. Both
# directions of drift fail badly, and neither is obvious:
#
#   Cloudflare ADDS a range  -> edges in that range cannot reach the origin.
#     Visitors routed to those edges get 522. Everyone else is fine. It looks
#     like an intermittent, geography-dependent fault and it will not reproduce
#     from your own machine. This is the expensive one.
#
#   Cloudflare DROPS a range -> you keep allowing address space Cloudflare no
#     longer owns, which will eventually belong to somebody else. Quietly turns
#     a tight allowlist into a hole.
#
# Neither shows up in any health check, because from the origin's point of view
# nothing is wrong. The only way to catch it is to compare the lists.
#
# Run daily by cf-range-drift.timer. Emits a metric so it alerts rather than
# needing anyone to read output.

set -uo pipefail

BASELINE="/mnt/data/projects/host/cloudflare/ips-v4.txt"
TEXTFILE="/var/lib/node_exporter/textfile_collector/cf_ranges.prom"
URL="https://www.cloudflare.com/ips-v4"

ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
log() {
  printf '{"ts":"%s","level":"%s","service":"cf-drift","env":"vps-prod","host":"%s",' \
         "$(ts)" "$1" "$(hostname -s)"
  printf '"event":"cf.ranges.check","actor":"system","outcome":"%s","target":"%s","msg":"%s"}\n' \
         "$2" "$URL" "$3"
}

write_metric() {
  [[ -d "$(dirname "$TEXTFILE")" ]] || return 0
  {
    echo '# HELP cloudflare_ranges_drift Ranges differing between Cloudflare and our allowlist.'
    echo '# TYPE cloudflare_ranges_drift gauge'
    echo "cloudflare_ranges_drift $1"
    echo '# HELP cloudflare_ranges_check_success Whether the published list could be fetched.'
    echo '# TYPE cloudflare_ranges_check_success gauge'
    echo "cloudflare_ranges_check_success $2"
    echo '# HELP cloudflare_ranges_count Ranges currently published by Cloudflare.'
    echo '# TYPE cloudflare_ranges_count gauge'
    echo "cloudflare_ranges_count $3"
  } > "$TEXTFILE.$$" && mv "$TEXTFILE.$$" "$TEXTFILE" && chmod 644 "$TEXTFILE"
}

CURRENT=$(mktemp); trap 'rm -f "$CURRENT"' EXIT

if ! curl -fsS --max-time 30 "$URL" | grep -E '^[0-9]' | sort > "$CURRENT"; then
  # Deliberately does NOT reset the drift gauge: a fetch failure must not look
  # like "no drift". Report the fetch failure and leave the last known drift.
  log error failure "could not fetch $URL"
  write_metric "$(awk '/^cloudflare_ranges_drift /{print $2}' "$TEXTFILE" 2>/dev/null || echo 0)" 0 0
  exit 1
fi

COUNT=$(wc -l < "$CURRENT")
(( COUNT > 5 )) || { log error failure "fetched only $COUNT ranges — refusing to trust that"; \
                     write_metric 0 0 "$COUNT"; exit 1; }

if [[ ! -f "$BASELINE" ]]; then
  mkdir -p "$(dirname "$BASELINE")"
  cp "$CURRENT" "$BASELINE"
  log info success "baseline created with $COUNT ranges"
  write_metric 0 1 "$COUNT"
  exit 0
fi

ADDED=$(comm -13 <(sort "$BASELINE") "$CURRENT")
REMOVED=$(comm -23 <(sort "$BASELINE") "$CURRENT")
DRIFT=$(( $(echo -n "$ADDED" | grep -c . ) + $(echo -n "$REMOVED" | grep -c . ) ))

if (( DRIFT == 0 )); then
  log info success "no drift — $COUNT ranges match the allowlist"
  write_metric 0 1 "$COUNT"
  exit 0
fi

[[ -n "$ADDED"   ]] && while read -r r; do [[ -n "$r" ]] && \
  log warn failure "Cloudflare ADDED $r — allow it or those edges will 522"; done <<< "$ADDED"
[[ -n "$REMOVED" ]] && while read -r r; do [[ -n "$r" ]] && \
  log warn failure "Cloudflare REMOVED $r — stop allowing it"; done <<< "$REMOVED"

write_metric "$DRIFT" 1 "$COUNT"
log warn failure "$DRIFT range(s) drifted; update the OCI NSG, DOCKER-USER rules, and $BASELINE"
exit 2
