# Setup — bare server to live platform

A linear runbook. Do the steps in order; each one depends on the ones above it.

**Roughly 60–90 minutes**, most of it waiting on package installs and DNS.

> Every step tells you what to run, what it does, and **how to know it worked**.
> Do not skip the verification lines. On this kind of system the difference
> between "running" and "serving" is where the outages live.

---

## Before you start

You need these ready. Getting them mid-way is what turns an hour into an evening.

| | Why | Cost |
|---|---|---|
| Ubuntu 22.04/24.04 server, 2 vCPU / 8 GB+ | the box | varies |
| A domain with **Cloudflare as DNS** | DNS-01 certificates need Cloudflare API access | ~$10/yr |
| Cloudflare API token (`Zone:DNS:Edit` + `Zone:Zone:Read`, scoped to your zone) | issues and renews TLS | free |
| Tailscale account | admin access; SSH and RDP never touch the public internet | free |
| S3-compatible bucket | off-site backups | free tier |
| Brevo account (or any SMTP relay) | alert email | free tier |

Two disks, or one large one. `/` fills faster than you expect, and a full root
disk takes down sshd and Docker **together**.

---

## 1 · Create the server

Whatever your provider is. Open **22/tcp** to your current IP so you can get in
the first time — you will close it again in step 5.

**Verify:** you can `ssh` to it.

---

## 2 · Get the repo onto the box

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/yourusername/onebox.git
cd onebox
```

**Verify:** `ls bootstrap/bootstrap-ubuntu.sh` exists.

---

## 3 · Bootstrap

**What it does:** installs Docker (official APT repo), Tailscale, XFCE + XRDP,
hardened SSH, fail2ban, unattended security upgrades. Creates your admin user.
Idempotent — safe to rerun.

```bash
sudo BOOTSTRAP_PASSWORD='<a-real-password>' ./bootstrap/bootstrap-ubuntu.sh
```

*~15–25 min, mostly apt.*

**Verify:** the summary block prints, and:

```bash
docker version && systemctl is-active ssh xrdp fail2ban
```

> **It rewrites `sshd_config` and runs that step LAST**, so if SSH breaks
> everything else is already installed. Keep your current session open until
> step 5 confirms you can log in again.
>
> It refuses to run on a host that already looks provisioned. That guard is
> deliberate — override only if you mean it.

---

## 4 · Join Tailscale

**What it does:** puts the box on your private mesh. Not automated by the
bootstrap script, because silently joining a mesh network is not a script's
decision to make.

```bash
sudo tailscale up          # follow the printed URL
tailscale ip -4            # note this address
```

**Verify:** `tailscale status` shows the host, and you can ping it from your laptop.

---

## 5 · Move admin access to Tailscale, then close public SSH

**What it does:** removes your last dependence on a public SSH port.

Open a **new** terminal on your laptop — do not close the old one:

```bash
ssh prodadmin@<tailscale-ip>
```

**Verify:** you get a shell. **Only then**, in your cloud firewall, remove the
public 22/tcp rule.

> This is the lockout-capable step. Second session open, verified in a third,
> and only then close anything.

---

## 6 · Configure

**What it does:** one file supplies every credential and tunable; the renderer
generates each project's `.env` from it.

```bash
cp .env.example .env
chmod 600 .env
nano .env                  # DOMAIN, passwords, API token, bucket, TAILSCALE_IP
sudo ./scripts/render-env.sh
```

*~10 min of reading. Every variable explains why its default is what it is.*

**Verify:** the renderer prints `ok` for each generated file and no `ERROR`.
It fails loudly on unset required values rather than deploying a service with a
blank password.

---

## 7 · Create the Docker networks

**What it does:** two networks — `proxy-net` for things nginx talks to,
`backend-net` internal with **no egress** for service-to-service traffic.

```bash
docker network create proxy-net
docker network create --internal --subnet 10.89.0.0/24 --gateway 10.89.0.1 backend-net
```

**Verify:** `docker network ls | grep -E 'proxy-net|backend-net'` shows both.

> The subnet is pinned on purpose. `node_exporter` binds that gateway address so
> Prometheus can scrape it, and Docker reassigns bridge subnets on recreation —
> an unpinned subnet silently breaks the scrape weeks later.
>
> Both are **external** so projects can be brought up and down independently
> without Compose destroying a network another project is using.

---

## 8 · Start nginx with a placeholder certificate

**What it does:** nginx will not start without a certificate, and the real one
cannot be issued until nginx exists to serve the domain. Break the loop with a
self-signed cert you throw away in step 10.

```bash
mkdir -p proxy-nginx/certs
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout proxy-nginx/certs/tls.key -out proxy-nginx/certs/tls.crt \
  -subj "/CN=$(grep '^DOMAIN=' .env | cut -d= -f2)"
chmod 600 proxy-nginx/certs/tls.key

docker compose -f proxy-nginx/compose.yml up -d
```

**Verify:**

```bash
curl -sk https://127.0.0.1/healthz     # {"status":"ok","service":"nginx"}
```

A browser warning at this point is correct — the certificate is self-signed.

---

## 9 · Point DNS at the server

In Cloudflare, add an `A` record for your apex domain to the server's **public**
IP. Proxy status **on** (orange cloud). Set SSL/TLS mode to **Full**.

**Verify:**

```bash
dig +short A yourdomain.com          # Cloudflare's IPs, not yours — that is correct
curl -sI https://yourdomain.com/healthz
```

> Do not set **Full (Strict)** yet. Strict rejects a self-signed origin
> certificate, and you still have one until the next step.

---

## 10 · Issue the real certificate

**What it does:** Let's Encrypt via DNS-01, apex plus wildcard, auto-renewing.

```bash
sudo ./scripts/cert-issue.sh --staging     # rehearse first
sudo ./scripts/cert-issue.sh               # the real one
sudo systemctl enable --now certbot-renew.timer
```

*~2 min. The staging run costs nothing and Let's Encrypt rate-limits failures to
5/hour — rehearsing is strictly cheaper than getting it wrong.*

**Verify:**

```bash
echo | openssl s_client -connect 127.0.0.1:443 -servername yourdomain.com 2>/dev/null \
  | openssl x509 -noout -issuer -dates     # issuer = Let's Encrypt
sudo certbot renew --dry-run               # "all simulated renewals succeeded"
```

Now set Cloudflare SSL/TLS to **Full (Strict)**.

> **DNS-01, not HTTP-01, and that is a constraint.** Step 12 restricts inbound
> traffic to Cloudflare's IP ranges. Let's Encrypt validates HTTP-01 from its own
> IPs, so renewal would start failing ~60 days later with nothing linking it to
> the firewall change. DNS-01 needs no inbound path at all.
>
> The renewal rehearsal matters more than the issuance. Certificate automation
> that has never been exercised is a 60-day time bomb.

---

## 11 · Deploy monitoring

**What it does:** Prometheus, Grafana, Alertmanager, blackbox exporter,
nginx-exporter, and the alert email bridge.

```bash
docker compose -f monitoring/compose.yml up -d
docker compose -f alert-bridge/compose.yml up -d
```

*~3 min to pull images.*

**Verify:**

```bash
curl -sk -o /dev/null -w '%{http_code}\n' https://yourdomain.com/monitoring/   # 302
docker exec prometheus wget -qO- http://127.0.0.1:9090/api/v1/targets \
  | jq -r '[.data.activeTargets[]|select(.health=="up")]|length'              # all up
```

Log into Grafana at `/monitoring/` with the password from your `.env`.

Send yourself a test alert:

```bash
docker exec prometheus wget -qO- --header='Content-Type: application/json' \
  --post-data='{"status":"firing","receiver":"test","commonLabels":{"alertname":"SetupTest","severity":"warning"},"alerts":[{"status":"firing","labels":{"alertname":"SetupTest","severity":"warning"},"annotations":{"summary":"Setup test - ignore"},"startsAt":"2026-01-01T00:00:00Z"}]}' \
  http://alert-bridge:9095/alert
```

**Verify:** the email arrives. An alerting stack you have never seen deliver is
not an alerting stack.

---

## 12 · Lock the front door

**What it does:** restricts inbound 443 to Cloudflare's published ranges, in
both the cloud firewall and on the host.

First, in your **cloud firewall**, allow 443/tcp only from the 15 ranges in
`host/cloudflare/ips-v4.txt`. Then:

```bash
sudo ./scripts/apply-cf-firewall.sh
sudo ./scripts/cf-range-drift.sh
sudo systemctl enable --now cf-range-drift.timer
```

**Verify:** the site still works through Cloudflare, and

```bash
docker exec nginx sh -c 'tail -50 /var/log/nginx/access.log' \
  | jq -r .source_ip | sort -u        # only Cloudflare ranges
```

> **The host-side rule must live in `DOCKER-USER`, not `INPUT`.** nginx's ports
> are published by dockerd, so packets are DNAT'd and traverse `FORWARD → DOCKER`
> without ever touching `INPUT`. A rule in `INPUT` — or any UFW rule — would
> report the port as blocked while it stayed wide open.
>
> The drift check exists because that allowlist is a frozen copy of a list
> Cloudflare controls. If they add a range, edges there cannot reach you and
> *some* visitors get 522 — geography-dependent, and it will not reproduce from
> your machine.

---

## 13 · Backups

**What it does:** encrypted local sets nightly, encrypted copies off-site, and a
restore test that proves the archives are actually readable.

```bash
sudo ./scripts/backup.sh
sudo ./scripts/restore-test.sh
sudo ./scripts/backup-offsite.sh
sudo systemctl enable --now backup.timer backup-offsite.timer
```

**Verify:** `restore-test.sh` prints **RESTORE TEST PASSED**. Until it does, you
have archives, not backups.

> **Store `BACKUP_PASSPHRASE` somewhere that is not this server.** It protects
> backups *of* this host. If the only copy lives here, a disk failure takes both
> the data and the means to read it.

---

## 14 · Remote desktop (optional)

**What it does:** a full Linux desktop in the browser at `/webrdp/`.

```bash
sudo ./scripts/install-kasm.sh
```

*~10–15 min; the images are large.*

**Verify:** `/webrdp/` loads and a workspace launches. See `kasm/notes/` — the
`proxy_path` value is the part people get wrong.

> Skip this if you do not need it. Kasm is ~6 containers and the largest single
> consumer on the box.

---

## 15 · Final check

```bash
./scripts/port-audit.sh     # no unexpected listeners
./scripts/preflight.sh      # overall health gate
```

Then record reality in `docs/context/STATE.md`. It is a template; overwrite it.
It is the first file anyone reads, and a stale version is worse than none
because it gets trusted.

---

## Order at a glance

```
1  create server            public :22 open temporarily
2  clone repo
3  bootstrap                Docker, Tailscale, XRDP, hardened SSH
4  tailscale up             join the mesh
5  verify tailnet SSH       ← then close public :22
6  .env + render-env.sh     one file, all credentials
7  create networks          proxy-net + internal backend-net
8  nginx + placeholder TLS  breaks the cert/nginx chicken-and-egg
9  DNS at Cloudflare        proxied, SSL mode Full
10 real certificate         DNS-01 → then switch to Full (Strict)
11 monitoring + alerts      send yourself a test email
12 lock to Cloudflare       cloud firewall + DOCKER-USER
13 backups + restore test   not a backup until the test passes
14 Kasm                     optional
15 audit + write STATE.md
```

## If a step fails

Nothing here is destructive except step 3 (rewrites `sshd_config`) and step 12
(firewall). Both take backups first, and both are documented in
[`docs/context/DECISIONS.md`](docs/context/DECISIONS.md) with rollback.

Everything else can be rerun. The scripts are idempotent by design.
