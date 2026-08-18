# proxy-nginx

The single public gateway. TLS terminates here; every backend sits behind it on
internal Docker networks. See `docs/PLAN.md` §7.

**Phase 3 state:** bound to the Tailscale interface only
(`100.64.0.10:80` and `:443`). Nothing is reachable from the internet.

## Layout

```
nginx.conf            global: JSON log format, timeouts, gzip
conf.d/
  00-default.conf     catch-all — unknown/absent Host gets 444
  01-health.conf      :8080 internal — healthz + stub_status (NOT published)
  10-redirect.conf    :80 -> :443, plus the ACME webroot for Phase 11
  20-tailnet.conf     the tailnet origin; site routes land here per phase
snippets/             ssl, security-headers, proxy-common, rate-limit
certs/                TLS material — gitignored
html/                 placeholder index until Phase 4
logs/                 access.log (JSON) + error.log — gitignored
```

`conf.d/*.conf` loads in lexical order and the first matching `server` wins for
a given Host, so the numbering makes evaluation order explicit rather than
accidental.

## Certificates

`certs/tls.crt` and `certs/tls.key` are currently a **self-signed placeholder**.
They exist so the TLS path is exercised now.

Once HTTPS Certificates is enabled at <https://login.tailscale.com/admin/dns>:

```bash
sudo tailscale cert \
  --cert-file certs/tls.crt --key-file certs/tls.key \
  onebox-prod.tailnet-example.ts.net
sudo chown prodadmin:prodadmin certs/tls.*
docker compose exec nginx nginx -s reload
```

Same paths, so **no config change**. Re-enable OCSP stapling in
`snippets/ssl.conf` at that point (it is commented out because stapling a
self-signed cert logs a resolver error on every start).

## Operating

```bash
docker compose config -q                    # validate compose
docker compose exec nginx nginx -t          # validate nginx
docker compose exec nginx nginx -s reload   # apply config, no downtime
docker compose up -d                        # apply compose changes
../scripts/port-audit.sh                    # after ANY change
```

Always `nginx -t` before reload. A bad config on reload is refused and the old
one keeps serving; a bad config on *restart* leaves you with nothing.

## Two traps found the hard way in Phase 3

**`return` bypasses `limit_req`.** `return` is handled by the rewrite module,
which runs before the preaccess phase where rate limiting is evaluated. A
`location` that ends in `return 200` silently ignores its own `limit_req`. The
placeholder root therefore serves a real file instead. If you ever "simplify" a
location to a `return`, you have removed its rate limit.

**The healthcheck needs its own listener.** It connects to `127.0.0.1`, whose
Host header matches no `server_name`, so it fell through to `00-default`'s
`return 444` and could never pass. Hence `01-health.conf` on `:8080`, which is
deliberately not published — weakening the catch-all would defeat its purpose.

## Adding a route

Add one `conf.d/NN-<name>.conf`, join `proxy-net`, `nginx -t`, reload. No
existing file is edited, so a new service cannot break an unrelated one.

New public paths must not collide with `/webrdp` or `/monitoring` — Kasm's zone
config forbids overlapping proxy paths (§15b).
