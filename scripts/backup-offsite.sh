#!/usr/bin/env bash
# Off-site backup to OCI Object Storage via rclone (S3-compatible API).
#
# Replaces the SSH/rsync version, which never worked: `your-laptop` has no
# reachable sshd, so BackupOffsiteStale has been firing correctly since it was
# written. Object storage removes the dependency on another machine being up.
#
# THE HARD CONSTRAINT
# -------------------
# The bucket is capped at 9.90 GB (OCI Always Free is 10 GB; we leave headroom
# so a single oversized run cannot wedge the account). Exceeding it does not
# degrade gracefully — writes fail and you silently stop having backups. So this
# script enforces the budget itself rather than trusting retention counts to
# stay small: after uploading, it prunes oldest-first until usage is under
# BUDGET_BYTES, and refuses to start if a single archive would not fit.
#
# WHAT IS BACKED UP  (rule 30: rebuildable from repo + secrets + documented deps)
#   - the whole git repo except .git and caches (configs, compose, scripts, docs)
#   - every .env, encrypted — these are the part git deliberately does not hold
#   - /etc config the repo does not own: ssh, docker, audit, fail2ban, iptables,
#     systemd units, letsencrypt (certs, account key, and the Cloudflare token)
#   - Grafana DB and Prometheus TSDB (dashboards and history are not rebuildable)
#   - a live pg_dump of Kasm's database (users, workspaces, MFA enrolments)
#
# WHAT IS NOT, deliberately: Docker images (re-pullable, and huge), container
# logs (noise), and the Kasm workspace images (rebuildable from the Dockerfile).
#
# Restore: scripts/restore-test.sh proves the archive decrypts and unpacks.
# Rule 9 — a backup is not a backup until a restore has been tested.

set -uo pipefail

REPO="/mnt/data/projects"
WORK="/mnt/data/backups/offsite"
REMOTE="oci:your-backup-bucket/backups"
RCLONE_CONF="/etc/rclone/rclone.conf"
TEXTFILE_DIR="/var/lib/node_exporter/textfile_collector"
BUDGET_BYTES=$((9900 * 1000 * 1000))   # 9.90 GB, decimal — matches how OCI counts

STAMP="$(date -u +%Y-%m-%dT%H%M%SZ)"
ARCHIVE="vps-backup-${STAMP}.tar.zst.enc"
RC=0

ts() { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
log() { # level event outcome msg [reason]
  printf '{"ts":"%s","level":"%s","service":"backup","env":"vps-prod","host":"%s",' \
         "$(ts)" "$1" "$(hostname -s)"
  printf '"event":"%s","actor":"system","outcome":"%s","target":"%s"' "$2" "$3" "$REMOTE"
  [[ -n "${5:-}" ]] && printf ',"reason":"%s"' "$5"
  printf ',"msg":"%s"}\n' "$4"
}
die() { log error "$1" failure "$2" "${3:-}"; write_metrics 0; exit 1; }

write_metrics() {
  [[ -d "$TEXTFILE_DIR" ]] || return 0
  local ok="$1" size="${2:-0}" used="${3:-0}" count="${4:-0}"
  local f="$TEXTFILE_DIR/backup_offsite.prom"
  {
    echo '# HELP backup_offsite_last_success_timestamp_seconds Unix time of last successful off-site upload.'
    echo '# TYPE backup_offsite_last_success_timestamp_seconds gauge'
    [[ "$ok" == "1" ]] && echo "backup_offsite_last_success_timestamp_seconds $(date +%s)" \
                       || echo "backup_offsite_last_success_timestamp_seconds $(awk '/last_success/{print $2}' "$f" 2>/dev/null | tail -1 || echo 0)"
    echo '# HELP backup_offsite_archive_bytes Size of the most recent archive.'
    echo '# TYPE backup_offsite_archive_bytes gauge'
    echo "backup_offsite_archive_bytes $size"
    echo '# HELP backup_offsite_bucket_used_bytes Total bytes stored in the off-site bucket.'
    echo '# TYPE backup_offsite_bucket_used_bytes gauge'
    echo "backup_offsite_bucket_used_bytes $used"
    echo '# HELP backup_offsite_bucket_budget_bytes Hard ceiling this script enforces.'
    echo '# TYPE backup_offsite_bucket_budget_bytes gauge'
    echo "backup_offsite_bucket_budget_bytes $BUDGET_BYTES"
    echo '# HELP backup_offsite_archive_count Archives currently retained off-site.'
    echo '# TYPE backup_offsite_archive_count gauge'
    echo "backup_offsite_archive_count $count"
  } > "$f.$$" && mv "$f.$$" "$f" && chmod 644 "$f"
}

RCL() { rclone --config "$RCLONE_CONF" "$@"; }

# --- preflight ---------------------------------------------------------------
[[ -f "$RCLONE_CONF" ]] || die backup.offsite "rclone config missing at $RCLONE_CONF" "no-config"
[[ -f "$REPO/.backup-env" ]] || die backup.offsite ".backup-env missing" "no-passphrase-file"
# shellcheck disable=SC1091
set -a; . "$REPO/.backup-env"; set +a
[[ -n "${BACKUP_PASSPHRASE:-}" ]] || die backup.offsite "BACKUP_PASSPHRASE empty" "no-passphrase"

RCL lsd oci: >/dev/null 2>&1 || true   # informational; the real check is below
if ! RCL ls "$REMOTE" >/dev/null 2>&1; then
  # Distinguish "bucket empty" from "bucket unreachable" — they need different fixes.
  if ! RCL mkdir "oci:your-backup-bucket" >/dev/null 2>&1 || ! RCL ls "oci:your-backup-bucket" >/dev/null 2>&1; then
    die backup.offsite \
      "bucket your-backup-bucket not reachable over the S3 API" \
      "bucket-invisible: check the OCI S3 Compatibility designated compartment"
  fi
fi

mkdir -p "$WORK"
STAGE="$(mktemp -d "$WORK/stage.XXXXXX")"
cleanup() { rm -rf "$STAGE"; }
trap cleanup EXIT

# --- collect -----------------------------------------------------------------
log info backup.collect success "collecting sources"

# 1. repo: config, compose, scripts, docs. .git is excluded because GitHub holds
#    it; this archive is for the things git does NOT have.
tar cf "$STAGE/repo.tar" -C "$REPO" \
    --exclude='.git' --exclude='logs' --exclude='graphify-out/cache' \
    --exclude='backups' --exclude='node_modules' . 2>/dev/null \
  || log warn backup.collect failure "repo tar reported errors" "tar-warnings"

# 2. host config the repo does not own.
sudo tar cf "$STAGE/etc.tar" \
    /etc/ssh /etc/docker /etc/audit /etc/fail2ban /etc/iptables \
    /etc/letsencrypt /etc/rclone /etc/systemd/system \
    /etc/systemd/journald.conf /etc/sysctl.d 2>/dev/null \
  || log warn backup.collect failure "/etc tar reported errors" "tar-warnings"

# 3. Kasm database — a live dump, not a file copy of a running Postgres.
if docker ps --format '{{.Names}}' | grep -q '^kasm_db$'; then
  docker exec kasm_db pg_dump -U kasmapp -d kasm 2>/dev/null > "$STAGE/kasm.sql" \
    || log warn backup.collect failure "kasm pg_dump failed" "pg_dump-error"
fi

# 4a. Bind-mounted service data. Grafana, Prometheus and Alertmanager do NOT use
#     Docker volumes here — they bind-mount /mnt/data/data/<service>. An
#     earlier version of this script only iterated `docker volume ls` and so
#     silently shipped an archive with no dashboards and no metrics history.
#     The upload succeeded, which is exactly what made it dangerous.
if [[ -d /mnt/data/data ]]; then
  sudo tar cf "$STAGE/data-binds.tar" -C /mnt/data/data . 2>/dev/null \
    || log warn backup.collect failure "bind-mount data tar reported errors" "tar-warnings"
else
  log warn backup.collect failure "/mnt/data/data missing" "no-bind-data"
fi

# 4b. Named volumes holding non-rebuildable state. Matched by name; anonymous
#     hash-named volumes are deliberately skipped — on this host they are all
#     orphaned Postgres data left by the Kasm install and the containerd move,
#     and backing up ~580 MB of dead data every night would burn the budget.
for v in $(docker volume ls -q); do
  case "$v" in
    *grafana*|*prometheus*|*kasm_db*)
      mp=$(docker volume inspect "$v" -f '{{.Mountpoint}}' 2>/dev/null)
      [[ -d "$mp" ]] && sudo tar cf "$STAGE/vol-$v.tar" -C "$mp" . 2>/dev/null
      ;;
  esac
done

# 4c. Fail loudly if the archive would omit a service we claim to protect.
# Verifying the manifest is cheap; discovering the omission during a restore is
# not. This check exists because the bind-mount bug above shipped undetected.
for required in repo.tar etc.tar data-binds.tar; do
  [[ -s "$STAGE/$required" ]] || die backup.collect \
    "expected component $required is missing or empty" "incomplete-archive"
done

# --- compress + encrypt ------------------------------------------------------
# zstd -19 over gzip: roughly 20-30% smaller on this mix of text and SQL, which
# directly buys retention depth against a fixed 9.90 GB ceiling.
log info backup.compress success "compressing with zstd -19 and encrypting"
sudo tar cf - -C "$STAGE" . \
  | zstd -19 -T2 -q \
  | openssl enc -aes-256-cbc -pbkdf2 -iter 200000 -salt -pass env:BACKUP_PASSPHRASE \
  > "$WORK/$ARCHIVE" || die backup.compress "compress/encrypt pipeline failed" "pipeline-error"

SIZE=$(stat -c '%s' "$WORK/$ARCHIVE")
(( SIZE > 0 )) || die backup.compress "archive is empty" "zero-bytes"
(( SIZE < BUDGET_BYTES )) || die backup.compress "single archive exceeds the whole budget" "oversized"

# Checksum travels with the archive so a restore can prove integrity before
# spending time on decryption.
sha256sum "$WORK/$ARCHIVE" | awk '{print $1}' > "$WORK/$ARCHIVE.sha256"

# --- upload ------------------------------------------------------------------
log info backup.upload success "uploading $ARCHIVE ($(numfmt --to=iec "$SIZE"))"
RCL copy "$WORK/$ARCHIVE"        "$REMOTE/" || die backup.upload "upload failed" "rclone-copy-failed"
RCL copy "$WORK/$ARCHIVE.sha256" "$REMOTE/" || log warn backup.upload failure "checksum upload failed" "rclone-copy-failed"

# Verify by reading back the size from the remote, not by trusting exit code 0.
REMOTE_SIZE=$(RCL size "$REMOTE/$ARCHIVE" --json 2>/dev/null | grep -oE '"bytes":[0-9]+' | cut -d: -f2)
[[ "$REMOTE_SIZE" == "$SIZE" ]] || die backup.upload "remote size $REMOTE_SIZE != local $SIZE" "size-mismatch"

rm -f "$WORK/$ARCHIVE" "$WORK/$ARCHIVE.sha256"

# --- retention + hard budget -------------------------------------------------
# Count-based retention first (readable intent), then a byte-based sweep that
# guarantees the ceiling regardless of how large individual archives became.
KEEP=30
mapfile -t ALL < <(RCL lsf "$REMOTE/" --include '*.tar.zst.enc' 2>/dev/null | sort)
if (( ${#ALL[@]} > KEEP )); then
  for old in "${ALL[@]:0:$(( ${#ALL[@]} - KEEP ))}"; do
    RCL delete "$REMOTE/$old" 2>/dev/null && RCL delete "$REMOTE/$old.sha256" 2>/dev/null
    log info backup.prune success "pruned $old (count retention, keep $KEEP)"
  done
fi

used() { RCL size "oci:your-backup-bucket" --json 2>/dev/null | grep -oE '"bytes":[0-9]+' | cut -d: -f2; }
USED=$(used); USED=${USED:-0}
while (( USED > BUDGET_BYTES )); do
  OLDEST=$(RCL lsf "$REMOTE/" --include '*.tar.zst.enc' 2>/dev/null | sort | head -1)
  [[ -z "$OLDEST" ]] && break
  RCL delete "$REMOTE/$OLDEST" 2>/dev/null; RCL delete "$REMOTE/$OLDEST.sha256" 2>/dev/null
  log warn backup.prune success "pruned $OLDEST to stay under the 9.90 GB ceiling" "budget-enforced"
  USED=$(used); USED=${USED:-0}
done

COUNT=$(RCL lsf "$REMOTE/" --include '*.tar.zst.enc' 2>/dev/null | wc -l)
write_metrics 1 "$SIZE" "$USED" "$COUNT"
log info backup.offsite success \
  "off-site backup complete: $COUNT archives, $(numfmt --to=iec "${USED:-0}") of $(numfmt --to=iec $BUDGET_BYTES) used"
exit $RC
