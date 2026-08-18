#!/usr/bin/env bash
# Shared helpers for Claude Code hooks in this project.
# Sourced by the other hook scripts — not executed directly.
#
# Every hook writes the SAME canonical JSON event shape (see
# .claude/rules/10-logging-audit.md). Keep this file dependency-light:
# bash + coreutils + jq only.

set -uo pipefail

PROJECT_DIR="${CLAUDE_PROJECT_DIR:-/mnt/data/projects}"
CTX_DIR="$PROJECT_DIR/docs/context"
AUDIT_DIR="$CTX_DIR/audit"
SESSION_DIR="$CTX_DIR/sessions"
LEDGER="$PROJECT_DIR/instructions.md"
LOCK_DIR="${TMPDIR:-/tmp}/claude-hooks-$(id -u)"

mkdir -p "$AUDIT_DIR" "$SESSION_DIR" "$LOCK_DIR" 2>/dev/null || true

now_iso()     { date -u +%Y-%m-%dT%H:%M:%S.%3NZ; }
audit_file()  { printf '%s/%s.jsonl' "$AUDIT_DIR" "$(date -u +%Y-%m-%d)"; }
session_file(){ printf '%s/%s.md' "$SESSION_DIR" "${1:-unknown}"; }

# Strip anything that looks like a credential before it reaches a log file.
# Deliberately aggressive: a false positive costs readability, a false
# negative writes a secret to disk (and possibly to git).
redact() {
  # Every addition below is a credential this pattern FAILED to catch and which
  # consequently reached docs/context/audit/*.jsonl. Do not trim this list to
  # make it tidier — each entry is a real incident.
  #
  # 2026-08-16: 'passphrase' was missing while 'passwd|password' were present,
  #   so BACKUP_PASSPHRASE=... was written verbatim and pushed to GitHub.
  # 2026-08-16: Cloudflare's 'cfut_' token prefix was unknown.
  # 2026-08-16: OCI S3 keys have no distinguishing prefix at all — a 40-char hex
  #   access key and a base64 secret look like ordinary strings, so they are only
  #   caught by the key-name rule, which is why the name list must stay wide.
  # Pattern matching alone is not sufficient and this was proven the hard way:
  # a secret pasted into a command line appears as a bare string with no
  # key=value shape and, for things like an OCI access key (40 hex chars), no
  # distinguishing prefix either. Nothing generic can catch that without
  # redacting every hash and container ID in the log.
  #
  # So: an explicit denylist of currently-active secret VALUES, one per line,
  # in /etc/claude-redact.list (0600, root, never in git). Anything listed there
  # is masked wherever it appears, in any context. Add a value when a secret is
  # created; remove it when the secret is rotated and dead.
  local DENYLIST="/etc/claude-redact.list"
  sed -E \
    -e 's/((api[_-]?key|apikey|token|secret|passwd|password|passphrase|access[_-]?key|secret[_-]?key|bearer|authorization|credential)[a-z0-9_]*[[:space:]]*[:=][[:space:]]*)[^[:space:]",}\\]+/\1***REDACTED***/Ig' \
    -e 's/(xkeysib-|sk-|ghp_|github_pat_|AKIA|cfut_|glpat-)[A-Za-z0-9_\-]{8,}/***REDACTED***/g' \
    -e 's/(-----BEGIN [A-Z ]*PRIVATE KEY-----)/\1***REDACTED***/g' \
  | {
      if [[ -r "$DENYLIST" ]]; then
        # -F fixed strings: secret values contain regex metacharacters
        # (the OCI secret key ends in '=' and contains '/'), and treating them
        # as patterns would both fail to match and corrupt the line.
        local tmp; tmp="$(mktemp)"
        grep -vE '^[[:space:]]*(#|$)' "$DENYLIST" > "$tmp" 2>/dev/null
        if [[ -s "$tmp" ]]; then
          # Build a sed script that replaces each literal value.
          local script=""
          while IFS= read -r v; do
            [[ -z "$v" ]] && continue
            local esc; esc=$(printf '%s' "$v" | sed -e 's/[\/&|]/\\&/g')
            script+="s|${esc}|***REDACTED***|g;"
          done < "$tmp"
          rm -f "$tmp"
          [[ -n "$script" ]] && sed -E "$script" || cat
        else
          rm -f "$tmp"; cat
        fi
      else
        cat
      fi
    }
}

# clip <max-chars> — truncate stdin, marking that truncation happened.
clip() {
  local max="${1:-400}"
  awk -v m="$max" '{ s = s $0 "\n" } END {
    if (length(s) > m) printf "%s… [truncated %d chars]", substr(s, 1, m), length(s) - m;
    else printf "%s", s
  }'
}

# append_locked <file> — append stdin under an flock so parallel tool calls
# cannot interleave partial lines.
append_locked() {
  local target="$1"
  local lock="$LOCK_DIR/$(basename "$target").lock"
  if command -v flock >/dev/null 2>&1; then
    flock "$lock" -c "cat >> '$target'"
  else
    cat >> "$target"
  fi
}

# ensure_session_header <session_id> — idempotently create the session log
# with its front matter. Called by whichever hook touches the file first
# (record-prompt or record-turn, depending on where the turn starts).
ensure_session_header() {
  local sf; sf="$(session_file "$1")"
  [[ -f "$sf" ]] && return 0
  {
    printf '# Session %s\n\n' "$1"
    printf -- '- Opened: %s\n' "$(now_iso)"
    printf -- '- Project: `%s`\n' "$PROJECT_DIR"
    printf -- '- Host: `%s`\n\n' "$(hostname -s 2>/dev/null || echo unknown)"
    printf -- '---\n'
  } > "$sf"
}

# emit_audit <json> — write one canonical event to today's audit log.
emit_audit() {
  printf '%s\n' "$1" | append_locked "$(audit_file)"
}

# base_event <event> <outcome> — the common envelope, as a jq --argjson base.
base_event() {
  jq -nc \
    --arg ts        "$(now_iso)" \
    --arg host      "$(hostname -s 2>/dev/null || echo unknown)" \
    --arg event     "${1:-unknown}" \
    --arg outcome   "${2:-success}" \
    --arg session   "${SESSION_ID:-unknown}" \
    --arg actor     "${ACTOR:-claude}" \
    '{ts:$ts, level:"info", service:"claude-code", env:"vps-prod",
      host:$host, event:$event, session_id:$session, actor:$actor,
      outcome:$outcome}'
}
