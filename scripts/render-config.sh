#!/usr/bin/env bash
# Render *.tmpl config files by substituting ${VARS} from a project's .env.
#
# Exists because Alertmanager does NOT expand environment variables in its
# config file — it reads ${ALERT_SENDER} as a literal string and then fails to
# send mail, silently, the first time an alert fires. Found in Phase 6.
#
# Usage: scripts/render-config.sh <project-dir> [uid:gid]
#
# The optional uid:gid chowns rendered files to the container's user. Rendered
# configs stay 0600 because they contain secrets (rule 30), which means the
# container user must OWN them: a 0600 file owned by the deploying user is
# unreadable to a container running as someone else, and the service dies at
# startup with "permission denied".

set -euo pipefail

DIR="${1:?usage: render-config.sh <project-dir> [uid:gid]}"
OWNER="${2:-}"
ENV_FILE="$DIR/.env"

[[ -f "$ENV_FILE" ]] || { echo "no $ENV_FILE" >&2; exit 1; }

mapfile -t RENDERED < <(python3 - "$DIR" "$ENV_FILE" <<'PY'
import os, pathlib, re, subprocess, sys

d, envf = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

env = {}
for line in envf.read_text().splitlines():
    line = line.strip()
    if not line or line.startswith('#') or '=' not in line:
        continue
    k, v = line.split('=', 1)
    env[k.strip()] = v.strip()

for tmpl in sorted(d.rglob('*.tmpl')):
    out = tmpl.with_suffix('')
    # A previous run may have chowned the output to a container uid, leaving it
    # unwritable by us. Unlink rather than fail — we are regenerating it anyway.
    if out.exists() and not os.access(out, os.W_OK):
        subprocess.run(['sudo', 'rm', '-f', str(out)], check=True)
    text = tmpl.read_text()
    missing = sorted({m for m in re.findall(r'\$\{(\w+)\}', text) if not env.get(m)})
    out.write_text(re.sub(r'\$\{(\w+)\}', lambda m: env.get(m.group(1), m.group(0)), text))
    out.chmod(0o600)
    status = "MISSING: " + ", ".join(missing) if missing else "complete"
    print(f"{out}\t{status}", file=sys.stderr)
    print(out)
PY
)

if [[ -n "$OWNER" && ${#RENDERED[@]} -gt 0 ]]; then
  sudo chown "$OWNER" "${RENDERED[@]}"
  echo "  chowned ${#RENDERED[@]} rendered file(s) to $OWNER"
fi
