#!/usr/bin/env bash
# Produce a portable context bundle for moving this project to another machine
# or another Claude account.
#
# Includes everything needed to resume. Excludes every secret — those travel
# through the secrets channel, never inside a context bundle that gets copied
# around, mailed, or pasted into a chat.

set -euo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/mnt/data/projects}"
OUT_DIR="${1:-$PROJECT_DIR/docs/context/bundles}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BUNDLE="$OUT_DIR/context-bundle-$STAMP.tar.gz"

mkdir -p "$OUT_DIR"
cd "$PROJECT_DIR"

EXCLUDES=(
  --exclude='.env'            --exclude='.env.*'
  --exclude='*.key'           --exclude='*.pem'   --exclude='*.crt'
  --exclude='certs'           --exclude='secrets'
  --exclude='.git'            --exclude='node_modules'
  --exclude='docs/context/bundles'
  --exclude='graphify-out/*.html'
)

INCLUDE=()
for p in CLAUDE.md instructions.md plan.md README.md .gitignore \
         .claude docs proxy-nginx monitoring guacamole test-website scripts; do
  [[ -e "$p" ]] && INCLUDE+=("$p")
done

tar czf "$BUNDLE" "${EXCLUDES[@]}" "${INCLUDE[@]}"

# Fail loudly rather than shipping a bundle with a credential in it.
if tar tzf "$BUNDLE" | grep -Ei '(^|/)\.env$|\.key$|\.pem$|/certs?/' | grep -q .; then
  rm -f "$BUNDLE"
  echo "ABORTED: secret-shaped path made it into the bundle. Bundle deleted." >&2
  exit 1
fi

cat > "$OUT_DIR/RESTORE-$STAMP.md" <<EOF
# Restore instructions — bundle $STAMP

Created: $(date -u +%Y-%m-%dT%H:%M:%SZ) on $(hostname -s)
Source:  $PROJECT_DIR

## Restore

\`\`\`bash
mkdir -p <new-project-dir> && cd <new-project-dir>
tar xzf context-bundle-$STAMP.tar.gz
chmod +x .claude/hooks/*.sh .claude/skills/*/scripts/*.sh
git init && git add -A && git commit -m "restore from bundle $STAMP"
claude
\`\`\`

## Not in this bundle — restore these separately

- \`.env\` files for every project (rebuild from the \`.env.example\` files that
  ARE included, then fill from the secrets store)
- TLS certificates and private keys — reissue with certbot rather than copying
- Guacamole Postgres dump and Grafana database — from the backup store
- Guacamole TOTP enrolments — users re-enrol

## Verify the handoff worked

Start Claude in the restored directory and ask:
*"Read docs/context/STATE.md and DECISIONS.md, then tell me where we are and
what the next action is."*

A correct answer means the handoff succeeded. A vague one means the last
checkpoint was incomplete — fix the state files at the source.
EOF

printf 'Bundle:  %s (%s)\n' "$BUNDLE" "$(du -h "$BUNDLE" | cut -f1)"
printf 'Restore: %s\n' "$OUT_DIR/RESTORE-$STAMP.md"
printf 'Files:   %s\n' "$(tar tzf "$BUNDLE" | wc -l)"
