#!/usr/bin/env bash
# Issue (or re-issue) the Let's Encrypt certificate for yourdomain.com.
#
# WHY DNS-01 AND NOT HTTP-01
# --------------------------
# This is not a preference — HTTP-01 cannot work here once the origin is locked
# down. Let's Encrypt validates HTTP-01 from its own validator IPs, which are
# not Cloudflare's. The moment ingress on 443/80 is restricted to Cloudflare's
# 15 published ranges (the whole point of putting Cloudflare in front), those
# validators are blocked and every renewal fails.
#
# DNS-01 proves control by writing a TXT record instead, so it needs no inbound
# connectivity at all. It also means port 80 never has to be opened, and it is
# the only method that can issue a wildcard.
#
# PREREQUISITE — a Cloudflare API token you must create by hand:
#   Cloudflare dashboard -> My Profile -> API Tokens -> Create Token
#   -> "Edit zone DNS" template, then scope it:
#        Permissions:  Zone / DNS / Edit
#                      Zone / Zone / Read
#        Zone Resources: Include / Specific zone / yourdomain.com
#   Do NOT use the Global API Key — it can do anything to every zone and cannot
#   be scoped or revoked independently.
#
#   Then:  sudo install -m 600 /dev/null /etc/letsencrypt/cloudflare.ini
#          sudo nano /etc/letsencrypt/cloudflare.ini      # see the .example file
#
# Usage:
#   scripts/cert-issue.sh --staging    # rehearse against LE staging FIRST
#   scripts/cert-issue.sh              # real certificate

set -uo pipefail

DOMAIN="yourdomain.com"
EMAIL="you@example.com"
CREDS="/etc/letsencrypt/cloudflare.ini"
HOOK="/mnt/data/projects/scripts/cert-deploy-hook.sh"

STAGING_ARG=""
if [[ "${1:-}" == "--staging" ]]; then
  STAGING_ARG="--staging"
  echo "==> STAGING mode: issues an untrusted cert, but exercises the whole path."
  echo "    Let's Encrypt rate-limits production to 5 failures/hour/account."
  echo "    Rehearsing here costs nothing; failing in production costs an hour."
fi

# --- preflight: fail with a useful message, not a certbot stack trace ---
fail() { printf '\033[31mBLOCKED\033[0m  %s\n' "$1" >&2; exit 1; }

command -v certbot >/dev/null 2>&1 || \
  fail "certbot not installed. Run: sudo apt-get install -y certbot python3-certbot-dns-cloudflare"

python3 -c 'import certbot_dns_cloudflare' 2>/dev/null || \
  fail "the dns-cloudflare plugin is missing. Run: sudo apt-get install -y python3-certbot-dns-cloudflare"

[[ -f "$CREDS" ]] || \
  fail "$CREDS does not exist. Create it from host/letsencrypt/cloudflare.ini.example (chmod 600)."

PERMS=$(stat -c '%a' "$CREDS")
[[ "$PERMS" == "600" ]] || \
  fail "$CREDS is mode $PERMS; it holds an API token and must be 600. Run: sudo chmod 600 $CREDS"

grep -q 'dns_cloudflare_api_token' "$CREDS" || \
  fail "$CREDS has no dns_cloudflare_api_token line. A Global API Key is not accepted here by choice."

[[ -x "$HOOK" ]] || fail "deploy hook $HOOK is not executable."

# The token must actually work, and it is far better to learn that now than
# halfway through issuance with a half-written TXT record left behind.
TOKEN=$(grep dns_cloudflare_api_token "$CREDS" | sed 's/.*=[[:space:]]*//')
VERIFY=$(curl -s -X GET "https://api.cloudflare.com/client/v4/user/tokens/verify" \
           -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
         | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("success"))' 2>/dev/null)
[[ "$VERIFY" == "True" ]] || \
  fail "Cloudflare rejected the API token. Check it is a scoped token with Zone:DNS:Edit + Zone:Zone:Read."

echo "==> token verified against the Cloudflare API"
echo "==> requesting $DOMAIN and *.$DOMAIN via DNS-01"

# --dns-cloudflare-propagation-seconds 30: the default 10 is optimistic when the
# authoritative answer has to reach LE's resolvers. A failed propagation burns a
# rate-limit slot, so waiting 20 extra seconds is the cheap side of the trade.
sudo certbot certonly \
  --non-interactive --agree-tos --email "$EMAIL" \
  --dns-cloudflare \
  --dns-cloudflare-credentials "$CREDS" \
  --dns-cloudflare-propagation-seconds 30 \
  --deploy-hook "$HOOK" \
  --cert-name "$DOMAIN" \
  -d "$DOMAIN" -d "*.$DOMAIN" \
  $STAGING_ARG

rc=$?
if (( rc != 0 )); then
  printf '\033[31mFAILED\033[0m  certbot exited %d — see /var/log/letsencrypt/letsencrypt.log\n' "$rc" >&2
  exit "$rc"
fi

echo
echo "==> issued. What nginx is actually serving right now:"
echo | timeout 10 openssl s_client -connect 127.0.0.1:443 -servername "$DOMAIN" 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates
