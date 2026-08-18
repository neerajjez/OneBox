---
name: session-continuity
description: Use when saving or restoring this project's working context — at the end of a work session, before /clear or /compact, when context is running low, when handing off to a new Claude session or a different Claude account or machine, when the user says "checkpoint", "handoff", "save context", "resume", "where were we", or when starting a session and the state files look stale. Keeps docs/context/ authoritative so no project knowledge lives only in the conversation.
---

# Session continuity

Conversation context is disposable. `docs/context/` is not. This skill keeps
that true, so a new session — on a different machine or a different Claude
account — resumes with everything except the chat scrollback, and loses nothing
that matters.

## The model

| Layer | Path | Lifetime | Portable |
|---|---|---|---|
| Conversation | Claude's context window | This session | No |
| Raw transcript | `docs/context/sessions/<id>.md` | Forever, append-only | Yes (in git) |
| Audit trail | `docs/context/audit/*.jsonl` | Forever, append-only | Yes (in git) |
| **Curated state** | `docs/context/STATE.md` | Current truth | Yes (in git) |
| **Decision log** | `docs/context/DECISIONS.md` | Forever | Yes (in git) |
| Environment facts | `docs/context/ENVIRONMENT.md` | Until re-verified | Yes (in git) |
| Ledger | `instructions.md` | Forever | Yes (in git) |
| Account memory | `~/.claude/projects/<slug>/memory/` | Per account | **No — pointers only** |

The hooks in `.claude/hooks/` write the raw layers automatically every turn.
They cannot write the curated layers, because those require judgment about what
mattered and why. That is this skill's job.

**Rule: never put project knowledge only in `~/.claude/…/memory/`.** That
directory is tied to one account on one machine. It holds pointers into
`docs/context/`, nothing more.

## Checkpoint — run at the end of a work session, before `/clear`, or when context runs low

1. **Update `docs/context/STATE.md`.** It answers, for someone who has never
   seen the conversation:
   - What phase are we in, and what is the last thing that actually completed?
   - What is running on the box right now? What is deployed and healthy?
   - What is half-done, and what exactly is the next action?
   - What is blocked, and on what?
   Overwrite freely — this file is current truth, not history.

2. **Append to `docs/context/DECISIONS.md`** for anything decided this session.
   One entry per decision, in the ADR shape already in the file. A decision
   without its alternatives and its reasoning will be re-litigated in three
   weeks; that re-litigation is the cost this file exists to avoid.

3. **Update `docs/context/ENVIRONMENT.md`** if any hard fact about the host was
   observed or changed — versions, ports, disk, arch, installed packages.
   Include the command that produced it and the date.

4. **Curate `instructions.md`.** The hooks append index rows automatically;
   update the narrative sections (current position, open questions, next
   session's first move).

5. **Run the checkpoint script** to sync pointers and verify integrity:

   ```bash
   .claude/skills/session-continuity/scripts/checkpoint.sh
   ```

6. **Commit.** `git add -A && git commit -m "checkpoint: <what changed>"`.
   Uncommitted state is state that a disk failure deletes.

## Resume — run at the start of a session, or when asked "where were we"

The `SessionStart` hook already injects a summary. Go deeper when the work is
non-trivial:

1. Read `docs/context/STATE.md` in full, then `DECISIONS.md`.
2. Re-verify anything in `ENVIRONMENT.md` that the plan depends on — files
   drift, servers change. Trust but check.
3. Read the tail of the most recent `docs/context/sessions/*.md` for the last
   few turns of nuance the curated files dropped.
4. State back to the user, in three or four lines, where things stand and what
   the next action is. Then wait for confirmation before acting on production.

## Handoff to another account or machine

```bash
.claude/skills/session-continuity/scripts/export-bundle.sh
```

Produces a timestamped tarball of everything portable: `docs/context/`,
`.claude/` (rules, skills, hooks, settings), `CLAUDE.md`, `instructions.md`,
`plan.md`, and all project config. It deliberately excludes `.env`, keys, and
certs — those move through the secrets channel, never through a context bundle.

On the new machine:

```bash
tar xzf <bundle>.tar.gz -C <new-project-dir>
cd <new-project-dir> && chmod +x .claude/hooks/*.sh
claude   # SessionStart hook rehydrates automatically
```

Then tell the new session: *"Read docs/context/STATE.md and DECISIONS.md, then
tell me where we are."* If it can answer correctly, the handoff worked. If it
cannot, the checkpoint was incomplete — fix the files, not the prompt.

## What good state files look like

Concrete and falsifiable, never aspirational:

- Good: *"Phase 3 nginx container is up on `proxy-net`, serving 443 with a
  staging Let's Encrypt cert. `/monitoring/` returns 502 because Grafana is not
  deployed yet — expected. Next: Phase 4, test website."*
- Bad: *"Working on nginx setup. Making good progress."*

Every claim about the running system should be one command away from being
checked. Where a claim is unverified, say so and say what would verify it.

## When not to use this skill

Mid-task, for a small change, with plenty of context left. Checkpointing costs
tokens and a commit; do it at real boundaries, not every turn. The hooks are
already capturing the raw record continuously — nothing is at risk in between.
