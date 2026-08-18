#!/usr/bin/env bash
# PostToolUse / PostToolUseFailure — append one canonical audit event per
# mutating or shell tool call. This is the "who changed what, when" trail.
#
# Read-only tools (Read, Grep, Glob, WebFetch…) are intentionally NOT audited:
# they generate volume without changing state. The matcher in settings.json
# already narrows this, but we re-check so the script is safe to reuse.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

INPUT="$(cat)"

SESSION_ID="$(jq -r '.session_id // "unknown"' <<<"$INPUT")"
TOOL="$(jq -r      '.tool_name  // "unknown"' <<<"$INPUT")"
EVENT_NAME="$(jq -r '.hook_event_name // "PostToolUse"' <<<"$INPUT")"
MODE="$(jq -r      '.permission_mode // "unknown"' <<<"$INPUT")"
export SESSION_ID

case "$TOOL" in
  Bash|Edit|Write|NotebookEdit|MultiEdit) ;;
  *) exit 0 ;;
esac

if [[ "$EVENT_NAME" == "PostToolUseFailure" ]]; then
  OUTCOME="failure"
  DETAIL="$(jq -r '.tool_error.text // .tool_error // ""' <<<"$INPUT")"
else
  OUTCOME="success"
  DETAIL="$(jq -r '.tool_response.text // .tool_response.stdout // ""' <<<"$INPUT")"
fi

# `action` = what was actually done; `target` = what it was done to.
case "$TOOL" in
  Bash)
    ACTION="$(jq -r '.tool_input.command // ""' <<<"$INPUT" | head -c 500)"
    TARGET="shell"
    ;;
  *)
    ACTION="$(jq -r '.tool_input.description // .hook_event_name // ""' <<<"$INPUT")"
    TARGET="$(jq -r '.tool_input.file_path // .tool_input.notebook_path // ""' <<<"$INPUT")"
    ;;
esac

ACTION="$(printf '%s' "$ACTION" | redact)"
TARGET="$(printf '%s' "$TARGET" | redact)"
DETAIL="$(printf '%s' "$DETAIL" | redact | clip 400)"

REC="$(base_event "tool.${TOOL,,}" "$OUTCOME" \
  | jq -c \
      --arg tool   "$TOOL" \
      --arg action "$ACTION" \
      --arg target "$TARGET" \
      --arg detail "$DETAIL" \
      --arg mode   "$MODE" \
      --arg tuid   "$(jq -r '.tool_use_id // ""' <<<"$INPUT")" \
      '. + {tool:$tool, action:$action, target:$target,
            permission_mode:$mode, tool_use_id:$tuid, detail:$detail}
       | if $ARGS.named.detail == "" then del(.detail) else . end')"

emit_audit "$REC"
exit 0
