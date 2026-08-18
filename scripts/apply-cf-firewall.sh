#!/usr/bin/env bash
# Rebuild the DOCKER-USER chain so only Cloudflare can reach the published
# web ports, and persist it.
#
# WHY DOCKER-USER AND NOT INPUT
# -----------------------------
# nginx's 80/443 are published by dockerd, so inbound packets are DNAT'd and
# traverse FORWARD -> DOCKER -> the container. They never hit INPUT. A rule in
# INPUT (or a UFW allow/deny) is therefore invisible to them: the firewall will
# report the port as blocked while it is in fact wide open. DOCKER-USER is the
# one chain Docker guarantees it will not overwrite and that is evaluated before
# its own rules. This is rule 20's "UFW trap", applied.
#
# This is defence in depth. The OCI NSG is the first layer and already restricts
# 443 to Cloudflare. This layer survives an NSG misconfiguration, and it is the
# only layer that exists if the NSG is ever widened for a test and not restored.
#
# The allowlist is generated from host/cloudflare/ips-v4.txt — the SAME file
# cf-range-drift.sh compares against Cloudflare's published list. One source of
# truth, so a drift alert and this chain can never disagree.
#
# Rollback:  sudo iptables-restore < /mnt/data/backups/iptables/rules.<STAMP>

set -uo pipefail

BASELINE="/mnt/data/projects/host/cloudflare/ips-v4.txt"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/mnt/data/backups/iptables/rules.$STAMP"

[[ -r "$BASELINE" ]] || { echo "missing $BASELINE" >&2; exit 1; }
COUNT=$(grep -cE '^[0-9]' "$BASELINE")
(( COUNT > 5 )) || { echo "baseline has only $COUNT ranges — refusing" >&2; exit 1; }

mkdir -p "$(dirname "$BACKUP")"
iptables-save > "$BACKUP"
echo "  rollback point: $BACKUP"

iptables -F DOCKER-USER

# 1. Established traffic first. Without this, return packets for connections
#    opened from inside (a container fetching an image, Kasm reaching the host)
#    would be evaluated against the rules below and dropped.
iptables -A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN

# 2. Internal sources. Docker bridges, the tailnet, and the VCN subnet must keep
#    working: blackbox-exporter probes nginx container-to-container over
#    proxy-net, and those packets traverse FORWARD exactly like external ones.
for net in 172.16.0.0/12 192.168.0.0/16 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8; do
  iptables -A DOCKER-USER -s "$net" -j RETURN
done

# 3. Cloudflare, for the web ports only.
while read -r cidr; do
  [[ "$cidr" =~ ^[0-9] ]] || continue
  iptables -A DOCKER-USER -s "$cidr" -p tcp -m multiport --dports 80,443 -j RETURN
done < "$BASELINE"

# 4. Everything else that wants the web ports is dropped.
#    DROP, not REJECT: a reject tells a scanner something is listening and worth
#    revisiting. A drop costs them a timeout per probe.
iptables -A DOCKER-USER -p tcp -m multiport --dports 80,443 \
         -m comment --comment "non-Cloudflare -> web ports" -j DROP

# 5. Anything not touching 80/443 is unaffected — this chain must not become a
#    general-purpose firewall by accident.
iptables -A DOCKER-USER -j RETURN

echo "  DOCKER-USER rebuilt: $COUNT Cloudflare ranges + internal, else DROP on 80/443"
