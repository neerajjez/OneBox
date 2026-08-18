#!/usr/bin/env bash
# Nightly backup. docs/PLAN.md §25.
#
# Design notes that matter:
#  - Emits the canonical JSON log event (rule 10), so backup failures are
#    greppable the same way as everything else.
#  - Writes a node_exporter textfile metric on success. A backup that stops
#    silently is the DEFAULT failure mode; the BackupStale alert in
#    prometheus/rules/alerts.yml watches that metric, so silence becomes noise.
#  - Non-zero exit on ANY failure. A backup script that swallows errors is
#    worse than none, because it manufactures confidence.
#  - Databases are DUMPED, never file-copied. A file copy of a running
#    Postgres is not a backup.
#  - Never logs a credential.

set -uo pipefail

REPO="/mnt/data/projects"
DEST="${BACKUP_DEST:-/mnt/data/backups}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DAY="$(date -u +%Y-%m-%d)"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
KEEP_DAILY=14
KEEP_WEEKLY=8
RC=0

log() { # log <level> <event> <outcome> <msg> [extra-json]
  printf '{"ts":"%s","level":"%s","service":"backup","env":"vps-prod","host":"%s","event":"%s","outcome":"%s","msg":"%s"%s}\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%S.%3NZ)" "$1" "$(hostname -s)" "$2" "$3" "$4" "${5:-}"
}
fail() { RC=1; log error "$1" failure "$2"; }

mkdir -p "$DEST/daily/$DAY" "$DEST/weekly" || { log critical backup.start failure "cannot create $DEST"; exit 1; }
OUT="$DEST/daily/$DAY"
log info backup.start success "backup starting"

# --- 1. Kasm database — CRITICAL -------------------------------------------
# Users, groups, MFA enrolments, and the zone settings (/webrdp) that git
# cannot protect because they live only in this database.
if docker ps --format '{{.Names}}' | grep -qx kasm_db; then
  if docker exec kasm_db pg_dump -U kasmapp -d kasm 2>/dev/null | gzip > "$OUT/kasm-db-$STAMP.sql.gz"; then
    sz=$(stat -c %s "$OUT/kasm-db-$STAMP.sql.gz")
    (( sz > 1000 )) && log info backup.database success "kasm db dumped" ",\"target\":\"kasm\",\"bytes\":$sz" \
                    || fail backup.database "kasm dump suspiciously small ($sz bytes)"
  else
    fail backup.database "kasm pg_dump failed"
  fi
else
  log warn backup.database success "kasm_db not running — skipped"
fi

# --- 2. Grafana database ----------------------------------------------------
# Dashboards are provisioned from git, but users, API keys and preferences
# are not.
if [[ -f /mnt/data/data/grafana/grafana.db ]]; then
  # sqlite3 .backup is consistent against a live DB; cp is not.
  if docker run --rm -v /mnt/data/data/grafana:/g:ro -v "$OUT":/out \
       alpine:3.20 sh -c 'apk add -q sqlite && sqlite3 /g/grafana.db ".backup /out/grafana.db"' 2>/dev/null; then
    gzip -f "$OUT/grafana.db" && log info backup.database success "grafana db backed up" ',"target":"grafana"'
  else
    fail backup.database "grafana sqlite backup failed"
  fi
fi

# --- 3. Configuration -------------------------------------------------------
# The repo is in git and pushed, so this is belt-and-braces for the working
# tree plus anything untracked but needed.
if tar czf "$OUT/config-$STAMP.tar.gz" \
     --exclude='.git' --exclude='logs' --exclude='graphify-out/cache' \
     -C "$(dirname "$REPO")" "$(basename "$REPO")" 2>/dev/null; then
  log info backup.config success "config archived" ",\"bytes\":$(stat -c %s "$OUT/config-$STAMP.tar.gz")"
else
  fail backup.config "config tar failed"
fi

# --- 4. Secrets, ENCRYPTED and separate ------------------------------------
# .env files are gitignored by design, so git does not protect them. They are
# encrypted because this archive leaves the host.
if [[ -n "${BACKUP_PASSPHRASE:-}" ]]; then
  if tar czf - -C "$REPO" $(cd "$REPO" && find . -name '.env' -not -path './.git/*' 2>/dev/null) 2>/dev/null \
       | openssl enc -aes-256-cbc -pbkdf2 -salt -pass env:BACKUP_PASSPHRASE \
       > "$OUT/secrets-$STAMP.tar.gz.enc" 2>/dev/null; then
    chmod 600 "$OUT/secrets-$STAMP.tar.gz.enc"
    log info backup.secrets success "secrets archived encrypted"
  else
    fail backup.secrets "secrets encryption failed"
  fi
else
  log warn backup.secrets success "BACKUP_PASSPHRASE unset — secrets NOT backed up"
fi

# --- 5. Weekly promotion ----------------------------------------------------
if [[ "$(date -u +%u)" == "7" ]]; then
  cp -r "$OUT" "$DEST/weekly/$DAY" 2>/dev/null && log info backup.weekly success "promoted to weekly"
fi

# --- 6. Retention -----------------------------------------------------------
find "$DEST/daily"  -mindepth 1 -maxdepth 1 -type d -mtime "+$KEEP_DAILY"        -exec rm -rf {} + 2>/dev/null
find "$DEST/weekly" -mindepth 1 -maxdepth 1 -type d -mtime "+$((KEEP_WEEKLY*7))" -exec rm -rf {} + 2>/dev/null

# --- 7. Tell Prometheus ------------------------------------------------------
# Written ONLY on full success, so a partial failure ages the metric and trips
# BackupStale rather than looking healthy.
if (( RC == 0 )) && [[ -d "$TEXTFILE_DIR" ]]; then
  TMP="$TEXTFILE_DIR/.backup.prom.$$"
  {
    echo '# HELP backup_last_success_timestamp_seconds Unix time of last fully successful backup.'
    echo '# TYPE backup_last_success_timestamp_seconds gauge'
    echo "backup_last_success_timestamp_seconds $(date +%s)"
    echo '# HELP backup_size_bytes Size of the most recent backup set.'
    echo '# TYPE backup_size_bytes gauge'
    echo "backup_size_bytes $(du -sb "$OUT" | cut -f1)"
  } > "$TMP" && mv "$TMP" "$TEXTFILE_DIR/backup.prom" && chmod 644 "$TEXTFILE_DIR/backup.prom"
fi

# --- 7b. second physical disk ------------------------------------------------
# SECOND DISK. Backups live on /mnt/data (sdb1) alongside the data they
# protect, so a single disk failure loses both. This mirrors the newest set to
# the root disk (sda1) — a different device.
#
# This is NOT off-site and does NOT substitute for it: both copies die with the
# host. BackupOffsiteStale stays firing until a genuine off-site target exists.
MIRROR="/var/backups/vps"
if mkdir -p "$MIRROR" 2>/dev/null; then
  if rsync -a --delete "$OUT/" "$MIRROR/" 2>/dev/null; then
    log info backup.mirror success "mirrored to the root disk" ",\"target\":\"$MIRROR\""
  else
    log warn backup.mirror failure "second-disk mirror failed (not fatal)"
  fi
fi

# --- 8. off-site -------------------------------------------------------------
# Deliberately does NOT set RC: a local backup that succeeded is still worth
# recording. The off-site failure surfaces via BackupOffsiteStale instead.
if (( RC == 0 )); then
  "$(dirname "$0")/backup-offsite.sh" || log warn backup.offsite failure "off-site sync failed — see D-014"
fi

if (( RC == 0 )); then
  log info backup.complete success "backup complete" ",\"bytes\":$(du -sb "$OUT" | cut -f1)"
else
  log error backup.complete failure "backup completed WITH FAILURES — metric not updated"
fi
exit $RC
