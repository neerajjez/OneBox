#!/usr/bin/env bash
# Verify the context store is coherent, then sync pointer memories into the
# Claude account memory dir.
#
# This script never invents content — it checks and it mirrors pointers. The
# curated files are written by hand (see SKILL.md) because they need judgment.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/mnt/data/projects}"
CTX="$PROJECT_DIR/docs/context"
SLUG="$(printf '%s' "$PROJECT_DIR" | tr '/' '-')"
MEM="$HOME/.claude/projects/$SLUG/memory"
NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
WARN=0

say()  { printf '  %s\n' "$*"; }
ok()   { printf '  \033[32mok\033[0m    %s\n' "$*"; }
warn() { printf '  \033[33mwarn\033[0m  %s\n' "$*"; WARN=$((WARN+1)); }

printf '\nContext checkpoint — %s\n\n' "$NOW"

# --- 1. required files exist and are not stale placeholders ----------------
printf 'Curated state\n'
for f in STATE.md DECISIONS.md ENVIRONMENT.md; do
  p="$CTX/$f"
  if [[ ! -f "$p" ]]; then
    warn "$f is MISSING"
  elif grep -q 'TODO: fill this in' "$p"; then
    warn "$f still contains an unfilled placeholder"
  else
    age_d=$(( ( $(date -u +%s) - $(stat -c %Y "$p") ) / 86400 ))
    if (( age_d > 7 )); then
      warn "$f not updated in ${age_d}d — is it still true?"
    else
      ok "$f (updated ${age_d}d ago)"
    fi
  fi
done

# --- 2. raw layers are being written ---------------------------------------
printf '\nRaw capture\n'
turns=$(find "$CTX/sessions" -name '*.md' 2>/dev/null | wc -l)
events=$(cat "$CTX"/audit/*.jsonl 2>/dev/null | wc -l)
(( turns  > 0 )) && ok "$turns session log(s)"      || warn "no session logs — are hooks wired up?"
(( events > 0 )) && ok "$events audit event(s)"     || warn "no audit events — are hooks wired up?"

# every audit line must be valid JSON, or the format standard is already broken
if compgen -G "$CTX/audit/*.jsonl" >/dev/null; then
  bad=$(cat "$CTX"/audit/*.jsonl | jq -e . >/dev/null 2>&1; echo $?)
  (( bad == 0 )) && ok "audit log is valid JSONL" || warn "audit log has malformed lines"
fi

# --- 3. no secrets leaked into the context store ---------------------------
printf '\nSecret scan\n'
# Each pattern requires an actual payload after the prefix. Matching a bare
# prefix flags every doc that *describes* the redaction rules — which is most
# of them — and a scanner that cries wolf is a scanner nobody reads.
SECRET_RE='(xkeysib-[A-Za-z0-9]{16,}|sk-[A-Za-z0-9]{20,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[A-Z0-9]{16}|BEGIN [A-Z ]*PRIVATE KEY)'
if hits=$(grep -rEl "$SECRET_RE" "$CTX" "$PROJECT_DIR/instructions.md" 2>/dev/null) && [[ -n "$hits" ]]; then
  warn "possible unredacted secret — inspect before committing:"
  printf '        %s\n' $hits
else
  ok "no secrets in context store"
fi

if git -C "$PROJECT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if git -C "$PROJECT_DIR" ls-files 2>/dev/null \
       | grep -Ei '(^|/)\.env$|\.key$|\.pem$|/certs?/' | grep -q .; then
    warn "secret-shaped files are TRACKED BY GIT — fix before pushing"
  else
    ok "no secret-shaped files tracked by git"
  fi
  dirty=$(git -C "$PROJECT_DIR" status --porcelain | wc -l)
  (( dirty > 0 )) && warn "$dirty uncommitted change(s) — commit to make the checkpoint durable" \
                  || ok "working tree clean"
else
  warn "not a git repo — context is not versioned or backed up"
fi

# --- 4. mirror POINTERS into the account memory dir ------------------------
# Deliberately pointers only. Content lives in docs/context/ so that switching
# Claude accounts or machines loses nothing.
printf '\nAccount memory pointers\n'
mkdir -p "$MEM"

write_mem() { # write_mem <name> <type> <description> <body>
  cat > "$MEM/$1.md" <<EOF
---
name: $1
description: $3
metadata:
  type: $2
---

$4
EOF
  ok "memory/$1.md"
}

write_mem "vps-project-context-store" "project" \
  "Canonical context for the /mnt/data/projects VPS platform lives in docs/context/, not in account memory" \
"Authoritative project context is on disk at \`$CTX\`, versioned in git — not in
this memory directory. Read in this order: \`STATE.md\` (current truth),
\`DECISIONS.md\` (ADR log), \`ENVIRONMENT.md\` (verified host facts),
\`$PROJECT_DIR/instructions.md\` (operating manual + turn ledger).

Raw per-turn capture is appended automatically by \`.claude/hooks/\` into
\`sessions/\` and \`audit/\`. This design is what lets the project move between
Claude accounts or machines without loss — see [[vps-continuity-workflow]].

Last checkpoint: $NOW"

write_mem "vps-continuity-workflow" "feedback" \
  "Checkpoint and handoff procedure for the VPS project; run the session-continuity skill at session boundaries" \
"Use the \`session-continuity\` skill to checkpoint before \`/clear\`, at the end
of a session, or when handing off to another Claude account or machine.

**Why:** conversation context is not portable and is lost on compaction; the
user explicitly requires that switching sessions or accounts loses nothing.

**How to apply:** update \`STATE.md\`, \`DECISIONS.md\`, \`ENVIRONMENT.md\`, and
\`instructions.md\` by hand, run
\`.claude/skills/session-continuity/scripts/checkpoint.sh\`, then commit.
For a machine or account move use \`scripts/export-bundle.sh\`.
See [[vps-project-context-store]] and [[vps-production-safety]]."

write_mem "vps-production-safety" "project" \
  "The /mnt/data/projects host IS the live internet-facing VPS — commands there touch production" \
"\`/mnt/data/projects\` runs on the deployment target itself: \`onebox-prod\`,
Ubuntu 24.04, **aarch64**, 2 vCPU / 11 GiB, no swap. There is no separate staging
box, so every command is a production command, and every image needs an arm64
manifest.

Hard rules are in \`$PROJECT_DIR/CLAUDE.md\` and \`.claude/rules/\`;
\`.claude/hooks/guard-destructive.sh\` blocks disk, firewall, and sshd
destruction at the tool layer. See [[vps-project-context-store]]."

# MEMORY.md index — rebuild the block we own, preserve anything else.
IDX="$HOME/.claude/projects/$SLUG/memory/MEMORY.md"
{
  [[ -f "$IDX" ]] && grep -v '^- \[VPS' "$IDX" | sed '/^$/d'
  echo "- [VPS project context store](vps-project-context-store.md) — canonical state is in docs/context/, not here"
  echo "- [VPS continuity workflow](vps-continuity-workflow.md) — how to checkpoint and hand off without loss"
  echo "- [VPS production safety](vps-production-safety.md) — this host is the live ARM64 VPS; commands are production"
} > "$IDX.tmp" && mv "$IDX.tmp" "$IDX"
ok "MEMORY.md index updated"

# --- 5. result --------------------------------------------------------------
printf '\n'
if (( WARN == 0 )); then
  printf '\033[32mCheckpoint clean.\033[0m\n\n'
else
  printf '\033[33m%d warning(s) — resolve before treating this as a handoff point.\033[0m\n\n' "$WARN"
fi
exit 0
