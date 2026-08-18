# Port audits

`scripts/port-audit.sh` writes a timestamped snapshot here after every change
that could alter exposure. Diff consecutive runs; a new non-loopback listener
that nobody deliberately added is an incident, not a curiosity.

`EXAMPLE-port-audit.txt` is one real run, kept so the format is obvious. The
rest of the original history was one machine's and has been removed.

The script fails if it finds an unexpected listener, so it works in CI or a
pre-flight gate rather than only as something a human reads.
