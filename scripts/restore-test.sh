#!/usr/bin/env bash
# Restore verification. docs/PLAN.md §25.
#
#   "A backup is not a backup until a restore has been tested."
#
# Restores the latest backup set into SCRATCH locations and asserts the data is
# actually there — not merely that files exist and are non-zero. Touches
# nothing live.
#
# Run: monthly, and ALWAYS before enforcing Kasm MFA (§16 depends on being able
# to restore the enrolments).

set -uo pipefail

DEST="${BACKUP_DEST:-/mnt/data/backups}"
WORK="$(mktemp -d /tmp/restore-test.XXXXXX)"
RC=0

# Load the passphrase the same way backup.sh does. Without this the decryption
# check — the single most important assertion in this script — silently
# downgrades to a warning, and the run still reports "FAILED" for a reason that
# has nothing to do with the backup. A test that skips its own subject is worse
# than no test, because it produces a comforting transcript.
BACKUP_ENV="/mnt/data/projects/.backup-env"
if [[ -r "$BACKUP_ENV" ]]; then
  set -a; . "$BACKUP_ENV"; set +a
fi
# `docker rm -fv` — the -v matters. The postgres image declares a VOLUME for
# /var/lib/postgresql/data, so every run creates an anonymous ~139 MB volume.
# Without -v the container goes away and the volume does not, so each restore
# test silently leaked 139 MB. Five had accumulated (~580 MB) before anyone
# looked, and nothing would ever have reclaimed them.
trap 'docker rm -fv restore-test-pg >/dev/null 2>&1; rm -rf "$WORK"' EXIT

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; RC=1; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }

LATEST="$(find "$DEST/daily" -mindepth 1 -maxdepth 1 -type d | sort | tail -1)"
[[ -d "$LATEST" ]] || { echo "no backup set under $DEST/daily" >&2; exit 1; }

printf '\nRestore test — %s\n  source: %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LATEST"

# --- 1. Kasm database -------------------------------------------------------
printf 'Kasm database\n'
DUMP="$(find "$LATEST" -name 'kasm-db-*.sql.gz' | sort | tail -1)"
if [[ -f "$DUMP" ]]; then
  docker run -d --name restore-test-pg -e POSTGRES_PASSWORD=scratch \
    -e POSTGRES_USER=kasmapp -e POSTGRES_DB=kasm postgres:16-alpine >/dev/null 2>&1
  for _ in $(seq 1 30); do
    docker exec restore-test-pg pg_isready -U kasmapp >/dev/null 2>&1 && break; sleep 1
  done
  if gunzip -c "$DUMP" | docker exec -i restore-test-pg psql -U kasmapp -d kasm >/dev/null 2>&1; then
    q() { docker exec restore-test-pg psql -U kasmapp -d kasm -t -A -c "$1" 2>/dev/null; }
    users=$(q "select count(*) from users;")
    zone=$(q  "select proxy_path from zones where zone_name='default';")
    sett=$(q  "select count(*) from settings;")
    grp=$(q   "select count(*) from groups;")
    # Assert CONTENT, not just that the restore command exited 0.
    (( ${users:-0} > 0 )) && ok "users restored: $users" || bad "no users in restored DB"
    (( ${sett:-0}  > 0 )) && ok "settings restored: $sett" || bad "no settings in restored DB"
    (( ${grp:-0}   > 0 )) && ok "groups restored: $grp"   || bad "no groups in restored DB"
    # 'webrdp/desktop' — NOT '/webrdp'. Kasm's proxy_path is both the external
    # prefix and its own internal path, and kasm_proxy hardcodes /desktop/.
    # Four values were tried before this one: '/webrdp' produced a double slash,
    # 'webrdp' and 'desktop' both 404'd. This assertion previously encoded the
    # broken value, so a correct restore was reported as a failure.
    [[ "$zone" == "webrdp/desktop" ]] && ok "zone proxy_path preserved: $zone" \
                                      || bad "zone proxy_path is '$zone', expected webrdp/desktop"
    # MFA enrolments live here; §16 recovery depends on them surviving.
    mfa=$(q "select count(*) from users where otp_secret is not null;")
    ok "users with MFA enrolled: ${mfa:-0} (0 is expected until MFA is turned on)"
  else
    bad "psql restore failed"
  fi
else
  bad "no kasm dump in the backup set"
fi

# --- 2. Grafana database ----------------------------------------------------
printf '\nGrafana database\n'
GDB="$(find "$LATEST" -name 'grafana.db.gz' | tail -1)"
if [[ -f "$GDB" ]]; then
  gunzip -c "$GDB" > "$WORK/grafana.db"
  n=$(docker run --rm -v "$WORK":/w:ro alpine:3.20 sh -c \
        'apk add -q sqlite && sqlite3 /w/grafana.db "select count(*) from dashboard;"' 2>/dev/null)
  integrity=$(docker run --rm -v "$WORK":/w:ro alpine:3.20 sh -c \
        'apk add -q sqlite && sqlite3 /w/grafana.db "pragma integrity_check;"' 2>/dev/null)
  [[ "$integrity" == "ok" ]] && ok "sqlite integrity_check: ok" || bad "sqlite integrity: $integrity"
  ok "dashboards in restored db: ${n:-0}"
else
  bad "no grafana db in the backup set"
fi

# --- 3. Config archive ------------------------------------------------------
printf '\nConfig archive\n'
CFG="$(find "$LATEST" -name 'config-*.tar.gz' | tail -1)"
if [[ -f "$CFG" ]] && tar tzf "$CFG" >/dev/null 2>&1; then
  tar xzf "$CFG" -C "$WORK" 2>/dev/null
  for f in projects/docs/PLAN.md projects/proxy-nginx/nginx.conf projects/monitoring/compose.yml; do
    [[ -f "$WORK/$f" ]] && ok "present: ${f#projects/}" || bad "MISSING: ${f#projects/}"
  done
  # The archive must not carry secrets — they travel encrypted, separately.
  if tar tzf "$CFG" | grep -qE '/\.env$'; then
    bad "config archive contains .env files — secrets must be in the encrypted set only"
  else
    ok "no .env files in the config archive"
  fi
else
  bad "config archive missing or corrupt"
fi

# --- 4. Encrypted secrets ---------------------------------------------------
printf '\nEncrypted secrets\n'
SEC="$(find "$LATEST" -name 'secrets-*.tar.gz.enc' | tail -1)"
if [[ -f "$SEC" ]]; then
  # Distinguish "cannot read the file" from "wrong passphrase". The archive is
  # written 0600 by root, so an unprivileged run fails on permissions — and
  # reporting that as a passphrase mismatch sends whoever is restoring at 3am
  # down entirely the wrong path.
  if [[ ! -r "$SEC" ]]; then
    bad "cannot READ the archive (permission denied) — it is 0600 root-owned."
    bad "re-run this test with sudo -E so it has the same privilege as backup.sh"
  elif [[ -n "${BACKUP_PASSPHRASE:-}" ]]; then
    if openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BACKUP_PASSPHRASE -in "$SEC" 2>/dev/null \
         | tar tzf - >/dev/null 2>&1; then
      n=$(openssl enc -d -aes-256-cbc -pbkdf2 -pass env:BACKUP_PASSPHRASE -in "$SEC" 2>/dev/null | tar tzf - | wc -l)
      ok "decrypts and lists $n .env file(s)"
    else
      bad "readable, but decryption FAILED — the passphrase does not match this archive"
    fi
  else
    warn "BACKUP_PASSPHRASE unset — cannot verify decryption (this is the test that matters most)"
  fi
else
  warn "no encrypted secrets archive in this set"
fi

printf '\n'
if (( RC == 0 )); then
  printf '\033[32mRESTORE TEST PASSED\033[0m — record the date in docs/context/DECISIONS.md\n\n'
else
  printf '\033[31mRESTORE TEST FAILED\033[0m — the backup is not usable. Fix before relying on it.\n\n'
fi
exit $RC
