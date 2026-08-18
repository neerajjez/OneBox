#!/usr/bin/env bash
# UserPromptSubmit — record the ask verbatim in the session log.
#
# Without this the session log reads as a monologue: you can see what was
# decided but not what was asked, which is exactly the context a future
# session (or a different Claude account) needs most.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

INPUT="$(cat)"

SESSION_ID="$(jq -r '.session_id // "unknown"' <<<"$INPUT")"
PROMPT="$(jq -r '.user_input // ""' <<<"$INPUT")"
export SESSION_ID ACTOR=user

[[ -z "$PROMPT" ]] && exit 0

TS="$(now_iso)"
SF="$(session_file "$SESSION_ID")"
SAFE="$(printf '%s' "$PROMPT" | redact)"

ensure_session_header "$SESSION_ID"

{
  printf '\n## %s — user\n\n' "$TS"
  printf '%s\n' "$SAFE" | sed 's/^/> /'
} | append_locked "$SF"

emit_audit "$(base_event "turn.prompt" "success" \
  | jq -c --arg p "$(printf '%s' "$SAFE" | tr '\n' ' ' | head -c 200)" \
      '. + {summary:$p}')"

exit 0
