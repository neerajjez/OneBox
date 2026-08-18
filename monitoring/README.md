# monitoring

Prometheus + Grafana + Alertmanager + nginx-exporter. `node_exporter` runs on
the **host** as a systemd unit (`host/systemd/node_exporter.service`), not in a
container — see `docs/PLAN.md` §10.

Grafana: `https://<host>/monitoring/` — never a published port.

## Two things that are easy to get backwards

**Grafana's metrics path.** `serve_from_sub_path=true` prefixes *every* Grafana
path, `/metrics` included. Prometheus must scrape `/monitoring/metrics`;
scraping `/metrics` gets a redirect to the public root URL and the target goes
down.

**proxy_pass trailing slash.** `/monitoring/` uses `proxy_pass http://grafana:3000`
with **no** trailing slash, so the `/monitoring` prefix is passed through —
Grafana expects it. Kasm at `/webrdp/` does the opposite and strips it (§15b).
Same-looking config, opposite behaviour.

## node_exporter reachability

Prometheus is on `backend-net`, which is `internal: true` — no egress, no
default route. It can still reach that network's own gateway, so node_exporter
binds to `172.19.0.1` (plus loopback), never `0.0.0.0`.

Two things make that work, and both are load-bearing:

1. `backend-net` has a **pinned subnet** (`172.19.0.0/24`), so the gateway
   address cannot drift when the network is recreated.
2. A **narrow host firewall rule** allows `172.19.0.0/24 -> 172.19.0.1:9100`.
   Without it the host REJECTs the scrape and the target reports
   "no route to host", which looks like a Docker problem and is not.

## Operating

```bash
docker compose config -q
docker run --rm --entrypoint promtool -v "$PWD/prometheus:/p:ro" \
  prom/prometheus:v3.1.0 check config /p/prometheus.yml
docker run --rm --entrypoint promtool -v "$PWD/prometheus:/p:ro" \
  prom/prometheus:v3.1.0 check rules /p/rules/alerts.yml
docker compose up -d
```

Dashboards are provisioned from `grafana/dashboards/*.json` with
`allowUiUpdates: false`. Edit the JSON in git, not the UI — a hand-edited
dashboard is lost when the container is replaced.

Retention is **15 days** (O-007). Alert thresholds are tuned for this host and
differ from the original brief; the reasoning is inline in
`prometheus/rules/alerts.yml`.
