#!/usr/bin/env bash
# Storage and mount integrity check.
#
# Exists because of D-013: Kasm's installer adds an rclone Docker plugin that
# declares PropagatedMount "/mnt". That claims the whole /mnt tree, relocated
# our data volume out from under Docker's data-root, and Docker then restarted
# onto an EMPTY data-root without erroring. Total stack loss, silently.
#
# A Kasm upgrade re-runs the installer, so the plugin can come back. This turns
# that silent catastrophic failure into a loud one.
#
# Run: before and after ANY Kasm operation, after any docker plugin install,
#      and as part of the post-reboot check.

set -uo pipefail

DATA_MOUNT="${DATA_MOUNT:-/mnt/data}"
FINDINGS=0

ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FINDINGS=$((FINDINGS+1)); }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; }

printf '\nStorage preflight — %s\n\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# --- 1. the data volume is mounted where we expect --------------------------
printf 'Data volume\n'
SRC="$(findmnt -no SOURCE --target "$DATA_MOUNT" 2>/dev/null)"
TGT="$(findmnt -no TARGET --target "$DATA_MOUNT" 2>/dev/null)"
if [[ "$TGT" == "$DATA_MOUNT" ]]; then
  ok "$DATA_MOUNT is a mountpoint ($SRC)"
else
  bad "$DATA_MOUNT is NOT a mountpoint — it resolves to $TGT ($SRC)"
  bad "anything writing there is landing on the wrong filesystem"
fi

# The same device mounted twice is how D-013 presented mid-incident.
DUPES="$(findmnt -rno TARGET,SOURCE 2>/dev/null | awk -v s="$SRC" '$2==s{print $1}' | grep -v overlay | wc -l)"
if [[ -n "$SRC" ]] && (( DUPES > 1 )); then
  bad "$SRC is mounted at $DUPES locations — something relocated it:"
  findmnt -rno TARGET,SOURCE | awk -v s="$SRC" '$2==s{print "          " $1}'
else
  ok "no duplicate mounts of the data device"
fi

# --- 2. Docker's data-root is actually ON that volume -----------------------
printf '\nDocker data-root\n'
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
  ROOT="$(docker info --format '{{.DockerRootDir}}' 2>/dev/null)"
  ROOT_DEV="$(findmnt -no SOURCE --target "$ROOT" 2>/dev/null)"
  if [[ "$ROOT_DEV" == "$SRC" && -n "$SRC" ]]; then
    ok "data-root $ROOT is on $SRC"
  else
    bad "data-root $ROOT is on $ROOT_DEV, expected $SRC"
    bad "Docker may have started on an empty root — check containers/images"
  fi
  CN="$(docker ps -aq 2>/dev/null | wc -l)"; IM="$(docker images -q 2>/dev/null | wc -l)"
  (( CN > 0 || IM > 0 )) && ok "$CN container(s), $IM image(s) visible" \
                         || bad "Docker sees NO containers and NO images"
else
  warn "docker not reachable by this user — re-run with sudo or under sg docker"
fi

# --- 3. no plugin claims a path that overlaps our data ----------------------
printf '\nDocker plugins\n'
if docker plugin ls --format '{{.Name}}' >/dev/null 2>&1; then
  FOUND=0
  while read -r plug; do
    [[ -z "$plug" ]] && continue
    pm="$(docker plugin inspect "$plug" --format '{{.Config.PropagatedMount}}' 2>/dev/null)"
    [[ -z "$pm" || "$pm" == "<no value>" ]] && continue
    FOUND=1
    # Does the claimed path contain, or sit inside, our data mount?
    if [[ "$DATA_MOUNT" == "$pm"* || "$pm" == "$DATA_MOUNT"* ]]; then
      bad "plugin $plug declares PropagatedMount '$pm' — OVERLAPS $DATA_MOUNT"
      bad "this is the D-013 failure. Remove it: docker plugin rm $plug"
    else
      ok "plugin $plug PropagatedMount '$pm' (no overlap)"
    fi
  done < <(docker plugin ls --format '{{.Name}}' 2>/dev/null)
  (( FOUND == 0 )) && ok "no plugin declares a propagated mount"
else
  warn "cannot list docker plugins"
fi

printf '\n'
if (( FINDINGS == 0 )); then
  printf '\033[32mPREFLIGHT CLEAN\033[0m\n\n'
else
  printf '\033[31m%d finding(s) — do NOT proceed until resolved.\033[0m\n\n' "$FINDINGS"
fi
exit $(( FINDINGS > 0 ))
