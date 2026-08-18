# Kasm 1.17.0 CE — every successful login returns 500

**Status:** worked around and login now functions. Worth reporting upstream.

## Symptom

`POST /api/public/authenticate` with **valid** credentials returns
`<H1>Internal Error</H1>` (HTTP 500). With **invalid** credentials it correctly
returns 403 — so the deployment looks fine until you get the password right.

```
AttributeError: 'PublicAPI' object has no attribute 'hubspot_api_key'
  File "api_server/client_api.py", line 973, in authenticate
  File "api_server/client_api.py", line 2691, in _generate_auth_resp
```

Reproduces on a clean 1.17.0 Community install on aarch64/Ubuntu 24.04.

## Root cause

Established by disassembling the shipped `.pyc` files.

1. `ClientApi.__init__` (`client_api.pyc`, line 387) **does** set the attribute,
   twice — first a default, then from the settings table:
   ```
   LOAD_GLOBAL _B ; STORE_ATTR hubspot_api_key          # default
   ...
   self.hubspot_api_key = self._db.config['subscription']['hubspot_api_key'].value
   ```
2. `PublicAPI.__init__` (`public_api.pyc`, line 53) calls `super().__init__(config)`,
   but `PublicAPI` extends **`AdminApi`**, not `ClientApi`. `AdminApi.__init__`
   never sets the attribute.
3. `_generate_auth_resp` (`client_api.pyc`, line 2684) evaluates
   `if self.hubspot_api_key:` on every successful login.

So it is an **inheritance bug**: the attribute is initialised in a class that is
not in this object's MRO, while a method reached from that object requires it.

A contributing factor: the migration that seeds the `hubspot_api_key` *setting*
(`57d837889d39`) is conditional on a `subscription` settings category already
existing, which a fresh Community install never creates. But that is a red
herring — even with the row present the attribute is not set, because
`ClientApi.__init__` is never called for this object.

## What does NOT fix it

Each of these was tried and reverted:

| Attempt | Why it fails |
|---|---|
| `INSERT` the setting with plaintext SQL | `settings.value` is a `sqlalchemy_utils` EncryptedType keyed on `INSTALLATION_ID`; plaintext crash-loops the API on decrypt |
| `INSERT` with `value = NULL` | Row exists, attribute still unset |
| `INSERT` via Kasm's own ORM (correct encryption) | Row correct and decryptable — attribute still unset, because `ClientApi.__init__` never runs |
| Add `hubspot_api_key` to `server:` in `api.app.config.yaml` | That section feeds `ClientApi`, which is not in the MRO |
| `db_upgrade` / alembic | No-op; the DB is already at head (`2231c5b99d47`) with all 76 settings seeded |

## The workaround in use

`kasm/patches/sitecustomize.py`, mounted read-only into `kasm_api` at
`/usr/local/lib/python3.12/site-packages/sitecustomize.py`. Python imports
`sitecustomize` automatically at interpreter startup; it wraps
`builtins.__build_class__` and gives `PublicAPI` / `AdminApi` / `ClientApi` a
falsy class-level `hubspot_api_key` if they lack one.

`if self.hubspot_api_key:` then evaluates False and the HubSpot branch is
skipped — the correct behaviour for a deployment that does not use HubSpot.

It fails silently by design: this runs in the startup path of a production
service, and a raising `sitecustomize` would stop Kasm booting entirely, which
is worse than the bug.

**Verified after the patch:** valid credentials return a 518-char JWT,
authenticated API calls succeed, invalid credentials still return 403.

## Reverting

Remove the volume mount from `/opt/kasm/current/docker/docker-compose.yaml` and
`sudo /opt/kasm/bin/restart`. Delete this patch entirely once upstream fixes
the inheritance — re-check after **every** Kasm upgrade.

## For an upstream report

> On a clean 1.17.0 Community install, any successful login returns 500 with
> `AttributeError: 'PublicAPI' object has no attribute 'hubspot_api_key'`.
> `PublicAPI` extends `AdminApi`, but `hubspot_api_key` is only initialised in
> `ClientApi.__init__`, while `_generate_auth_resp` — reachable from
> `PublicAPI.authenticate` — reads it unconditionally. Invalid credentials
> return 403 correctly, so the fault only appears once credentials are right.
