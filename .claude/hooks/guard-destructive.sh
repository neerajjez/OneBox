#!/usr/bin/env bash
# PreToolUse(Bash) — the last line of defence on a live, internet-facing box.
#
# Two tiers:
#   DENY     — no legitimate reason to run this from an agent turn. Blocked
#              outright; the human runs it by hand with `!` if truly needed.
#   ESCALATE — plausible but irreversible or lockout-capable. Forced to a
#              permission prompt even in auto/acceptEdits mode.
#
# Anything not matched falls through to the normal permission flow (exit 0,
# no JSON) — this hook only ever tightens, never loosens.

source "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

INPUT="$(cat)"
SESSION_ID="$(jq -r '.session_id // "unknown"' <<<"$INPUT")"
CMD="$(jq -r '.tool_input.command // ""' <<<"$INPUT")"
export SESSION_ID

[[ -z "$CMD" ]] && exit 0

decide() { # decide <deny|escalate> <reason>
  emit_audit "$(base_event "guard.$1" "blocked" \
    | jq -c --arg c "$(printf '%s' "$CMD" | redact | head -c 300)" --arg r "$2" \
        '. + {level:"warn", action:$c, reason:$r}')"
  jq -nc --arg d "$1" --arg r "$2" \
    '{hookSpecificOutput:{hookEventName:"PreToolUse",
                          permissionDecision:$d,
                          permissionDecisionReason:$r}}'
  exit 0
}

# --- Tier 1: hard deny -----------------------------------------------------

# Root/system-path recursive deletion.
grep -Eq '\brm[[:space:]]+(-[[:alnum:]]*[rR][[:alnum:]]*[[:space:]]+)+(-[[:alnum:]]+[[:space:]]+)*(/|/\*|/(etc|var|usr|boot|opt|home|srv|root)(/\*)?[[:space:]]*$)' <<<"$CMD" \
  && decide deny "Recursive delete of a system path. Run it by hand if you truly mean it."

# Block-device destruction.
grep -Eq '\b(mkfs(\.[a-z0-9]+)?|fdisk|parted|wipefs)\b|\bdd\b[^|]*\bof=/dev/|>[[:space:]]*/dev/(sd|nvme|vd)' <<<"$CMD" \
  && decide deny "Writes directly to a block device — this destroys the disk."

# Firewall teardown on a public VPS.
grep -Eq '\bufw[[:space:]]+(disable|reset)\b|\biptables[[:space:]]+(-F|--flush)\b|\bnft[[:space:]]+flush[[:space:]]+ruleset\b|\bsystemctl[[:space:]]+(stop|disable)[[:space:]]+(ufw|nftables|firewalld)\b' <<<"$CMD" \
  && decide deny "Disables the host firewall on an internet-facing server."

# SSH self-lockout.
grep -Eq '\bsystemctl[[:space:]]+(stop|disable|mask)[[:space:]]+(ssh|sshd)\b' <<<"$CMD" \
  && decide deny "Stopping sshd can lock you out of the VPS with no console."

# World-writable system tree.
grep -Eq '\bchmod[[:space:]]+(-R[[:space:]]+)?(777|a\+rwx)[[:space:]]+/(etc|opt|var|usr)?[[:space:]]*$' <<<"$CMD" \
  && decide deny "Recursive 777 on a system path."

# Tampering with our own audit trail.
grep -Eq '(rm|truncate|shred|>[[:space:]]*)[^|]*docs/context/audit' <<<"$CMD" \
  && decide deny "The audit log is append-only. It is not edited or deleted from a turn."

# --- Tier 2: force a prompt ------------------------------------------------

grep -Eq '\bdocker[[:space:]]+(system[[:space:]]+prune|volume[[:space:]]+rm|volume[[:space:]]+prune)\b|\bdocker[[:space:]]+compose[[:space:]]+down\b[^|]*(-v|--volumes)' <<<"$CMD" \
  && decide escalate "Deletes Docker volumes — Guacamole's Postgres and Grafana's DB live in volumes. Confirm you have a restore-tested backup."

grep -Eq '\b(reboot|shutdown|halt|poweroff)\b|\bsystemctl[[:space:]]+(reboot|poweroff)\b' <<<"$CMD" \
  && decide escalate "Reboots the production VPS. Confirm the reboot-recovery checklist has been run."

grep -Eq '\bgit[[:space:]]+push\b[^|]*(--force|-f)\b|\bgit[[:space:]]+reset[[:space:]]+--hard\b|\bgit[[:space:]]+clean\b[^|]*-[a-z]*f' <<<"$CMD" \
  && decide escalate "Destroys uncommitted or pushed history."

grep -Eq 'curl[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh|wget[^|]*\|[[:space:]]*(sudo[[:space:]]+)?(ba)?sh' <<<"$CMD" \
  && decide escalate "Pipes a remote script straight into a shell. Pin and inspect the script first."

grep -Eq '>[[:space:]]*/etc/(ssh/sshd_config|passwd|shadow|sudoers)|\btee[[:space:]]+(-a[[:space:]]+)?/etc/(ssh/sshd_config|sudoers)' <<<"$CMD" \
  && decide escalate "Edits an auth-critical system file. Take a backup copy first and keep a second session open."

exit 0
