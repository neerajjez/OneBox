# Operating manual

The build-specific turn ledger from the original deployment is not included in
this public copy — it was 46 rows of one machine's history and would only be
misleading here.

What replaced it:

- **`CONTRIBUTING.md`** — the pre-flight and post-flight procedure, the
  ten-point service contract, and commit discipline.
- **`docs/context/DECISIONS.md`** — every decision with its alternatives and
  consequences. The most useful file in the repository.
- **`docs/context/STATE.md`** — current truth. Overwrite it freely; history
  belongs in `DECISIONS.md`.
- **`docs/context/ENVIRONMENT.md`** — verified host facts, and a record of the
  claims that turned out to be **wrong** and how they were settled. Keep that
  section. Knowing which method actually answers a question is worth more than
  the answer.

## If you use an AI assistant

`.claude/hooks/` appends a row to this file after every exchange and writes a
canonical JSON event to `docs/context/audit/`. Both are optional. The part worth
keeping regardless of tooling is the discipline underneath: **decisions live in
the repository, not in a conversation.**
