# Kasm MFA — enrolment and recovery runbook

`docs/PLAN.md` §16 / §28. **Recovery is proven before enforcement, never after.**

## Status

| | |
|---|---|
| TOTP available in CE | **Yes** — `allow_totp_2fa = True` |
| WebAuthn available in CE | **Yes** — `allow_webauthn_2fa = True` (future enhancement, §28b) |
| Self-enrolment allowed | Yes — `allow_2fa_self_enrollment = True` |
| Enforcement knob | `require_2fa` group setting |
| **Currently enforced** | **NO — deliberately.** See below. |
| Break-glass admin | `breakglass@kasm.local`, Administrators, verified logging in |
| Recovery path | **Tested 2026-08-16 — works** |

## Enforcement was tested once, inconclusively

`require_2fa=True` was set on the Administrators group to learn whether an
UNENROLLED user gets an enrolment flow (safe) or a hard denial (lockout).
`kasm_api` exited during the test and the answer was never obtained. The
setting was reverted immediately and login was verified restored.

It was not retried: repeatedly destabilising the authentication service of the
only remote-access gateway to satisfy curiosity is a bad trade. **The practical
consequence is unchanged — enrol first, enforce second.** Since the behaviour
for unenrolled users is unknown, treat enforcement as potentially locking.
Follow the order below and keep a working session open while you do it.

## Why enforcement is not switched on yet

Nobody has enrolled a TOTP device. Turning on `require_2fa` before an
authenticator is enrolled risks locking the administrator out of the only
remote-access gateway — the exact trade §28c forbids ("security must not come
at the cost of unrecoverable access").

Enrolment needs a browser and a phone, so it is yours to do. The order below is
not optional.

## Enrolment, in order

1. Log in at `https://<host>/webrdp/` as `admin@kasm.local`
   (password in `kasm/.env`).
2. Profile → enrol a TOTP authenticator. Scan the QR with your app.
3. **Save the recovery codes somewhere off this server** — encrypted, and
   somewhere the VPS dying does not take with it. Codes stored on the box are
   useless in the scenario they exist for.
4. Log out and log back in with TOTP. Confirm it works **before** step 5.
5. Enrol `breakglass@kasm.local` with a *different* authenticator, ideally on a
   different device.
6. Only now enforce:

```bash
docker exec kasm_db psql -U kasmapp -d kasm -c \
  "insert into group_settings (group_id, name, value)
   select group_id,'require_2fa','True' from groups where name='Administrators'
   on conflict do nothing;"
sudo /opt/kasm/bin/restart
```

7. Verify in a **private browser window** that login now demands TOTP, while
   your existing session stays open. If it fails, you still have the open
   session to undo it.

## Recovery — tested, works

**Tested 2026-08-16:** enrolment simulated, reset applied, login confirmed
afterwards.

### Lost the TOTP device

Reset that user's enrolment from the host over SSH (Tailscale), which is
independent of Kasm entirely:

```bash
docker exec kasm_db psql -U kasmapp -d kasm -c \
  "update users set secret=NULL where username='admin@kasm.local';"
```

The user is then prompted to enrol again at next login.

### Locked out of every Kasm account

Kasm is not the recovery path — it is the thing that broke. In order:

1. **SSH over Tailscale** to the host, run the reset above.
2. If Tailscale is down: **OCI serial console**, then the same command.
3. If the database is unrecoverable: restore it
   (`scripts/restore-test.sh` proves the dump is usable), then reset.

Recovery deliberately never depends on the Kasm web UI, a single TOTP device,
or a credential stored only on the VPS.

### Disable enforcement entirely

```bash
docker exec kasm_db psql -U kasmapp -d kasm -c \
  "delete from group_settings where name='require_2fa';"
sudo /opt/kasm/bin/restart
```

## Re-test quarterly

Re-run the recovery test and record the date in `docs/context/DECISIONS.md`.
A recovery path is only known-good on the day it was last exercised.
