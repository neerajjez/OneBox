"""Runtime workaround for a Kasm 1.17.0 CE inheritance bug.

THE BUG (established from bytecode, see kasm/notes/hubspot-defect.md):

  * `ClientApi.__init__` (client_api.pyc:387) sets `self.hubspot_api_key` —
    first to a default, then from `self._db.config['subscription'][...]`.
  * `PublicAPI` (public_api.pyc) does NOT inherit from `ClientApi`; it extends
    `AdminApi`, whose `__init__` never sets the attribute.
  * `_generate_auth_resp` (client_api.pyc:2684) nonetheless evaluates
    `if self.hubspot_api_key:` on every SUCCESSFUL login.

Result: authentication succeeds, then the response builder raises
`AttributeError` and returns 500. Bad credentials correctly return 403, which
is why this only shows up once you have the password right.

Not fixable from outside the code: raw SQL cannot help (the settings value
column is encrypted and the attribute is not read from there for this class),
and adding the key to api.app.config.yaml only feeds `ClientApi`, which is not
in this object's MRO.

THE PATCH: give the class a falsy class-level default. `if self.hubspot_api_key`
then evaluates False and the HubSpot branch is skipped — which is the correct
behaviour for a deployment that does not use HubSpot.

Mounted read-only into the kasm_api container at
/usr/local/lib/python3.12/site-packages/sitecustomize.py. Python imports
`sitecustomize` automatically at interpreter startup. Remove the volume mount
to revert completely. Re-check after any Kasm upgrade — delete this the moment
upstream fixes the inheritance.
"""

import sys


def _patch(module):
    """Set a falsy class default on any API class missing the attribute."""
    for name in ("PublicAPI", "AdminApi", "ClientApi"):
        cls = getattr(module, name, None)
        if isinstance(cls, type) and not hasattr(cls, "hubspot_api_key"):
            try:
                cls.hubspot_api_key = None
            except Exception:
                pass


class _PatchOnImport:
    """Post-import hook: patch the api_server modules as they are loaded.

    Deliberately fails silently. This runs inside the interpreter startup path
    of a production service; a raising sitecustomize would prevent Kasm from
    starting at all, which is far worse than the bug it works around.
    """

    _targets = {
        "api_server.public_api",
        "api_server.admin_api",
        "api_server.client_api",
    }

    def find_module(self, fullname, path=None):   # legacy API, never claims
        return None

    def find_spec(self, fullname, path=None, target=None):
        if fullname in self._targets:
            # Let the normal machinery import it, then patch on the way out.
            sys.meta_path_hook_pending = fullname
        return None


def _install():
    try:
        sys.meta_path.insert(0, _PatchOnImport())
    except Exception:
        return

    # Also patch anything already imported, and re-check lazily via an audit
    # hook on class creation is overkill — a simple import-time sweep plus the
    # module-level sweep below covers the real startup order.
    for name in list(sys.modules):
        if name in _PatchOnImport._targets:
            _patch(sys.modules[name])


_install()


# The service imports api_server.* well after sitecustomize runs, so the sweep
# above will usually find nothing. The reliable hook is __build_class__: patch
# the class the moment it is defined.
try:
    import builtins

    _orig_build_class = builtins.__build_class__

    def _build_class(func, name, *bases, **kwargs):
        cls = _orig_build_class(func, name, *bases, **kwargs)
        if name in ("PublicAPI", "AdminApi", "ClientApi"):
            try:
                if "hubspot_api_key" not in cls.__dict__ and not hasattr(cls, "hubspot_api_key"):
                    cls.hubspot_api_key = None
            except Exception:
                pass
        return cls

    builtins.__build_class__ = _build_class
except Exception:
    pass
