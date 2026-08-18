# Screenshots

Taken from a live deployment. **Redacted before publishing** — the real domain
and data-mount path were removed from the dashboard capture. Where you see a
solid block, that is a deliberate redaction, not a rendering fault.

| | What it shows |
|---|---|
| `01-test-site.png` | The placeholder site at `/`, confirming the delivery chain end to end: nginx, TLS termination, Docker networking, and request-ID propagation |
| `02-grafana-overview.png` | The Grafana overview at `/monitoring/` — host health, load per core, network, filesystem, all nine scrape targets up, nginx throughput |
| `05-kasm-workspaces.png` | The Kasm launcher at `/webrdp/`, offering Firefox, VS Code, a terminal and a full Ubuntu desktop |

## A note on the dashboard screenshot

Three panel groups in `02` were empty on first capture and are fixed here —
load per core, network, and Kasm health. Each had a different cause, and all
three failed *silently*:

- **Network** — node_exporter's `netdev` collector reads counters over a
  `NETLINK_ROUTE` socket, and the systemd unit's `RestrictAddressFamilies`
  omitted `AF_NETLINK`. `netclass` kept working via its sysfs fallback, so the
  failure looked partial rather than total.
- **Kasm** — one malformed line made node_exporter discard the *entire* textfile,
  taking every `kasm_*` metric with it.
- **Load per core** — a PromQL vector-matching failure. `node_load5` carries
  labels, `count()` returns none, so nothing paired and the result was empty
  rather than an error.

All three are written up in [`../context/DECISIONS.md`](../context/DECISIONS.md).
