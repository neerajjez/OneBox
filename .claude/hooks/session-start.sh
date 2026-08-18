#!/usr/bin/env bash
# SessionStart — rehydrate. This is what makes a brand-new session (or a
# brand-new Claude account) pick up where the last one stopped.
#
# Emits `additionalContext`, which Claude Code injects into the session before
# the first user turn. Kept deliberately small: pointers and open items, not
# content. The full detail is on disk and gets read on demand.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

INPUT="$(cat)"
SESSION_ID="$(jq -r '.session_id // "unknown"' <<<"$INPUT")"
REASON="$(jq -r '.start_reason // "startup"' <<<"$INPUT")"
export SESSION_ID

emit_audit "$(base_event "session.start" "success" \
  | jq -c --arg r "$REASON" '. + {start_reason:$r}')"

# Only rehydrate on a genuinely fresh start; on resume/compact the context is
# already there and re-injecting it just burns tokens.
case "$REASON" in
  startup|clear) ;;
  *) exit 0 ;;
esac

section() { # section <title> <file> <max-lines>
  [[ -f "$2" ]] || return 0
  printf '\n### %s (`%s`)\n\n' "$1" "${2#$PROJECT_DIR/}"
  head -n "${3:-40}" "$2"
}

CTX="$(
  printf 'PROJECT REHYDRATION — read this before acting.\n'
  printf 'Canonical context store: %s\n' "$CTX_DIR"
  section 'Current state' "$CTX_DIR/STATE.md" 60
  section 'Open decisions' "$CTX_DIR/DECISIONS.md" 40

  if [[ -f "$LEDGER" ]]; then
    printf '\n### Last 5 ledger entries (`instructions.md`)\n\n'
    grep -E '^\| 20' "$LEDGER" | tail -n 5
  fi

  printf '\nIf anything above is stale, correct the file before continuing.\n'
)"

jq -nc --arg c "$CTX" \
  '{hookSpecificOutput:{hookEventName:"SessionStart", additionalContext:$c}}'
exit 0
