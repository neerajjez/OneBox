#!/usr/bin/env bash
# Phase 7b — install Kasm Workspaces, safely.
#
# Encodes the sequence learned from D-013, where a naive install took the whole
# stack down: Kasm's installer adds an rclone Docker plugin declaring
# PropagatedMount "/mnt", which relocated the data volume out from under
# Docker's data-root. Docker then restarted onto an empty root WITHOUT erroring.
#
# This script:
#   1. preflight — refuse to start if storage is already wrong
#   2. stop our stacks cleanly, so nothing writes to a volume that may move
#   3. run the Kasm installer
#   4. remove the rclone plugin immediately (we do not use cloud-storage mapping)
#   5. repair the mount if the installer moved it
#   6. bring our stacks back and verify
#
# Re-run after any Kasm UPGRADE: the upgrade re-runs the installer and the
# plugin comes back.
#
# Usage:  ./scripts/install-kasm.sh /tmp/kasm_release

set -uo pipefail

REPO="/mnt/data/projects"
KASM_SRC="${1:-/tmp/kasm_release}"
DATA_MOUNT="/mnt/data"
STACKS=(proxy-nginx monitoring test-website)

step() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die()  { printf '\033[31mABORT: %s\033[0m\n' "$*" >&2; exit 1; }

[[ -f "$KASM_SRC/install.sh" ]] || die "no install.sh under $KASM_SRC"
[[ -f "$REPO/kasm/.env" ]]      || die "no $REPO/kasm/.env (credentials)"

step "1/6  Preflight"
sudo "$REPO/scripts/preflight.sh" || die "storage is already wrong — fix before installing"

step "2/6  Stopping our stacks cleanly"
for s in "${STACKS[@]}"; do
  envf=(); [[ -f "$REPO/$s/.env" ]] && envf=(--env-file "$REPO/$s/.env")
  sudo docker compose -f "$REPO/$s/compose.yml" "${envf[@]}" stop 2>&1 | tail -1
done

step "3/6  Running the Kasm installer"
# shellcheck disable=SC1091
set -a; . "$REPO/kasm/.env"; set +a
sudo bash "$KASM_SRC/install.sh" \
  --accept-eula \
  --no-check-ports \
  --proxy-port "${KASM_PROXY_PORT:-8443}" \
  --admin-password "$KASM_ADMIN_PASSWORD" \
  --user-password  "$KASM_USER_PASSWORD" \
  --db-password    "$KASM_DB_PASSWORD" \
  --redis-password "$KASM_REDIS_PASSWORD" 2>&1 | tail -25
INSTALL_RC=${PIPESTATUS[0]}
printf '\ninstaller exit: %s\n' "$INSTALL_RC"

step "4/6  Removing the rclone plugin (D-013)"
# --skip-custom-rclone does NOT skip rclone; it installs the stock plugin,
# which carries the same /mnt claim. Removing it afterwards is the only option.
while read -r plug; do
  [[ -z "$plug" ]] && continue
  pm="$(sudo docker plugin inspect "$plug" --format '{{.Config.PropagatedMount}}' 2>/dev/null)"
  if [[ -n "$pm" && "$pm" != "<no value>" ]] && [[ "$DATA_MOUNT" == "$pm"* || "$pm" == "$DATA_MOUNT"* ]]; then
    echo "  removing $plug (PropagatedMount $pm overlaps $DATA_MOUNT)"
    sudo docker plugin disable "$plug" >/dev/null 2>&1
    sudo docker plugin rm "$plug"      >/dev/null 2>&1 && echo "  removed"
  fi
done < <(sudo docker plugin ls --format '{{.Name}}' 2>/dev/null)

step "5/6  Repairing the mount if it moved"
if ! findmnt -no TARGET --target "$DATA_MOUNT" 2>/dev/null | grep -qx "$DATA_MOUNT"; then
  echo "  data volume was relocated — restoring"
  sudo systemctl stop docker docker.socket
  sudo findmnt -rno TARGET | grep '/propagated-mount' | sort -r | while read -r m; do
    sudo umount -l "$m" 2>/dev/null
  done
  sudo mount "$DATA_MOUNT" && echo "  remounted $DATA_MOUNT"
  sudo systemctl start docker
  sleep 8
else
  echo "  mount intact — no repair needed"
fi

step "6/6  Restoring our stacks"
for s in "${STACKS[@]}"; do
  envf=(); [[ -f "$REPO/$s/.env" ]] && envf=(--env-file "$REPO/$s/.env")
  sudo docker compose -f "$REPO/$s/compose.yml" "${envf[@]}" up -d 2>&1 | tail -1
done
sleep 25

printf '\n== Verification ==\n'
sudo "$REPO/scripts/preflight.sh"
sudo docker ps --format '  {{.Names}}\t{{.Status}}' | sort
printf '  https://127.0.0.1/            %s\n' "$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/)"
printf '  https://127.0.0.1/monitoring/ %s\n' "$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/monitoring/)"
printf '\nInstaller exit code was %s. If non-zero, review the log in %s\n' "$INSTALL_RC" "$(dirname "$KASM_SRC")"
