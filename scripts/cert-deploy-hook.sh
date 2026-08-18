#!/usr/bin/env bash
# certbot deploy hook — install a renewed cert into nginx and reload it.
#
# certbot runs this ONLY when a certificate was actually renewed, and exports
# RENEWED_LINEAGE (e.g. /etc/letsencrypt/live/yourdomain.com). Running on
# every timer tick instead would reload nginx daily for no reason.
#
# Order matters and is deliberate:
#   1. back up the cert currently in place   (rollback point — rule 00)
#   2. copy the new pair in
#   3. `nginx -t` INSIDE the container
#   4. reload only if the test passed; otherwise restore the backup
#
# A reload is not a restart: nginx keeps serving on the old workers until the
# new config is accepted, so a bad cert cannot drop live connections. But a bad
# cert that passes `-t` and then fails at handshake time still would, which is
# why step 5 verifies a real TLS handshake afterwards.

set -uo pipefail

CERT_DIR="/mnt/data/projects/proxy-nginx/certs"
BACKUP_DIR="/mnt/data/backups/certs"
CONTAINER="nginx"
LOG_TAG="cert-deploy"

ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }

# Canonical event shape — rule 10. Same field names as every other emitter here.
emit() {
  local level="$1" outcome="$2" msg="$3" reason="${4:-}"
  printf '{"ts":"%s","level":"%s","service":"certbot","env":"vps-prod","host":"%s",' \
         "$(ts)" "$level" "$(hostname -s)" >&2
  printf '"event":"cert.deploy","actor":"system","outcome":"%s","target":"%s"' \
         "$outcome" "${RENEWED_LINEAGE:-unknown}" >&2
  [[ -n "$reason" ]] && printf ',"reason":"%s"' "$reason" >&2
  printf ',"msg":"%s"}\n' "$msg" >&2
}

if [[ -z "${RENEWED_LINEAGE:-}" ]]; then
  emit error failure "deploy hook run without RENEWED_LINEAGE" "not-invoked-by-certbot"
  exit 1
fi

mkdir -p "$BACKUP_DIR"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

# --- 1. back up what is live right now ---
if [[ -f "$CERT_DIR/tls.crt" ]]; then
  cp -a "$CERT_DIR/tls.crt" "$BACKUP_DIR/tls.crt.$STAMP"
  cp -a "$CERT_DIR/tls.key" "$BACKUP_DIR/tls.key.$STAMP"
fi

restore() {
  [[ -f "$BACKUP_DIR/tls.crt.$STAMP" ]] || return
  cp -a "$BACKUP_DIR/tls.crt.$STAMP" "$CERT_DIR/tls.crt"
  cp -a "$BACKUP_DIR/tls.key.$STAMP" "$CERT_DIR/tls.key"
}

# --- 2. install the new pair ---
install -m 0644 "$RENEWED_LINEAGE/fullchain.pem" "$CERT_DIR/tls.crt" || {
  emit error failure "could not install fullchain" "copy-failed"; exit 1; }
install -m 0600 "$RENEWED_LINEAGE/privkey.pem"   "$CERT_DIR/tls.key" || {
  emit error failure "could not install privkey" "copy-failed"; restore; exit 1; }

# --- 3. validate before reloading ---
if ! docker exec "$CONTAINER" nginx -t >/dev/null 2>&1; then
  restore
  emit critical failure "nginx -t failed with the new cert; previous cert restored" "config-test-failed"
  exit 1
fi

# --- 4. reload ---
if ! docker exec "$CONTAINER" nginx -s reload >/dev/null 2>&1; then
  restore
  docker exec "$CONTAINER" nginx -s reload >/dev/null 2>&1
  emit critical failure "reload failed; previous cert restored and reloaded" "reload-failed"
  exit 1
fi

# --- 5. prove it actually serves, do not trust the reload's exit code ---
sleep 2
SERVED=$(echo | timeout 10 openssl s_client -connect 127.0.0.1:443 \
           -servername yourdomain.com 2>/dev/null \
         | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
if [[ -z "$SERVED" ]]; then
  emit critical failure "nginx reloaded but is not serving TLS" "handshake-failed"
  exit 1
fi

# Keep 10 generations. Older ones are useless — the key they pair with is gone.
ls -1t "$BACKUP_DIR"/tls.crt.* 2>/dev/null | tail -n +11 | xargs -r rm -f
ls -1t "$BACKUP_DIR"/tls.key.* 2>/dev/null | tail -n +11 | xargs -r rm -f

emit info success "certificate deployed and verified serving until $SERVED"

# Feed the renewal date to Prometheus so an expiring cert alerts rather than
# being discovered by a user seeing a browser warning.
TEXTFILE="/var/lib/node_exporter/textfile_collector/cert.prom"
if [[ -d "$(dirname "$TEXTFILE")" ]]; then
  EXP_EPOCH=$(date -d "$SERVED" +%s 2>/dev/null || echo 0)
  {
    echo '# HELP nginx_cert_expiry_seconds Unix time the served TLS cert expires.'
    echo '# TYPE nginx_cert_expiry_seconds gauge'
    echo "nginx_cert_expiry_seconds $EXP_EPOCH"
  } > "$TEXTFILE.$$" && mv "$TEXTFILE.$$" "$TEXTFILE" && chmod 644 "$TEXTFILE"
fi
