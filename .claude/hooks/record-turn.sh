#!/usr/bin/env bash
# Stop / StopFailure — the durability guarantee.
#
# Two writes per turn, both append-only:
#   1. docs/context/sessions/<session_id>.md  — full fidelity assistant output
#   2. instructions.md                        — one index row, appended at EOF
#
# instructions.md deliberately gets only a pointer row. The prose there is
# curated by hand; if the hook dumped whole turns into it the file would stop
# being readable within a day, and a ledger nobody reads is not a ledger.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

INPUT="$(cat)"

SESSION_ID="$(jq -r '.session_id // "unknown"' <<<"$INPUT")"
MSG="$(jq -r '.last_assistant_message // ""' <<<"$INPUT")"
EVENT_NAME="$(jq -r '.hook_event_name // "Stop"' <<<"$INPUT")"
MODE="$(jq -r '.permission_mode // "unknown"' <<<"$INPUT")"
export SESSION_ID

[[ -z "$MSG" ]] && exit 0

TS="$(now_iso)"
SF="$(session_file "$SESSION_ID")"
SAFE_MSG="$(printf '%s' "$MSG" | redact)"

# First line of the response, flattened, as the human-scannable summary.
SUMMARY="$(printf '%s' "$SAFE_MSG" \
  | tr '\n' ' ' \
  | sed -E 's/^[[:space:]]*[#>*_`-]+[[:space:]]*//; s/\|/\\|/g' \
  | head -c 140)"

ensure_session_header "$SESSION_ID"

{
  printf '\n## %s — assistant (%s, mode=%s)\n\n' "$TS" "$EVENT_NAME" "$MODE"
  printf '%s\n' "$SAFE_MSG"
} | append_locked "$SF"

printf '| %s | `%s` | %s | [log](docs/context/sessions/%s.md) |\n' \
  "$TS" "${SESSION_ID:0:8}" "$SUMMARY" "$SESSION_ID" \
  | append_locked "$LEDGER"

emit_audit "$(base_event "turn.end" "success" \
  | jq -c --arg s "$SUMMARY" --arg m "$MODE" \
      '. + {summary:$s, permission_mode:$m}')"

exit 0
