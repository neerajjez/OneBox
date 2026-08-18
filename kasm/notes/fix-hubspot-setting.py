"""Work around a Kasm 1.17.0 CE defect that makes every successful login 500.

    AttributeError: 'PublicAPI' object has no attribute 'hubspot_api_key'

The setting is seeded by migration 57d837889d39, but that migration is
CONDITIONAL on a 'subscription' settings category already existing — which a
fresh Community install never creates. The login response builder references
the attribute unconditionally, so authentication succeeds and then crashes.

Raw SQL cannot fix it: settings.value is a sqlalchemy_utils EncryptedType whose
key derives from INSTALLATION_ID. A plaintext value crash-loops the API on
decrypt; NULL leaves the attribute unset. So the row must be written through
Kasm's own ORM.

Runs INSIDE the kasm_api container. Reads installation_id from the database
itself, so the key never appears on a command line or in a shell history.

    docker cp fix-hubspot-setting.py kasm_api:/tmp/
    docker exec kasm_api python3 /tmp/fix-hubspot-setting.py
"""

import os
import sys
import warnings

warnings.filterwarnings("ignore")
sys.path.insert(0, "/src")

import yaml
from sqlalchemy import create_engine, text
from sqlalchemy.orm import sessionmaker

CONFIG = "/opt/kasm/current/conf/app/api/api.app.config.yaml"

db = yaml.safe_load(open(CONFIG))["database"]
url = (f"postgresql://{db['username']}:{db['password']}"
       f"@{db['host']}:{db.get('port', 5432)}/{db['name']}")
engine = create_engine(url)

# The encryption key. Fetched here rather than passed in, so it never leaves
# the container.
with engine.connect() as c:
    row = c.execute(text("select installation_id from installation limit 1")).fetchone()
if not row:
    sys.exit("no installation_id row — is this a complete install?")
os.environ["INSTALLATION_ID"] = str(row[0])

# Import only AFTER the env var is set; the model reads it at class-definition
# time to build the encryption key.
from api_server.data.model import ConfigSetting  # noqa: E402

Session = sessionmaker(bind=engine)
s = Session()
try:
    # Prove the key is correct by decrypting something that already exists.
    # If this raises, writing would produce rows nothing can read.
    probe = s.query(ConfigSetting).first()
    _ = probe.value
    print(f"  decrypt probe ok: {probe.name}")

    if s.query(ConfigSetting).filter_by(name="hubspot_api_key").first():
        print("  hubspot_api_key already present — nothing to do")
    else:
        s.add(ConfigSetting(
            name="hubspot_api_key",
            title="Hubspot API Key",
            value="unused",
            value_type="string",
            category="subscription",
            description=("Unused. Workaround for a Kasm 1.17.0 CE defect: the login "
                         "path references this attribute but the seeding migration "
                         "is conditional on a category CE never creates."),
            sanitize=True,
            services_restart=False,
        ))
        s.commit()
        print("  INSERTED hubspot_api_key via the ORM (value encrypted correctly)")
finally:
    s.close()
