-- Register the locally-built VS Code + SSH workspace as a NEW Kasm image.
-- The stock 'Visual Studio Code' record is left untouched so it stays a
-- rollback path if the local image ever fails to provision.
BEGIN;

CREATE TEMP TABLE t AS
  SELECT * FROM images
  WHERE image_id = '22746e61-cc2a-431e-9a97-02cd5c5977f4';

UPDATE t SET
  image_id        = uuid_generate_v4(),
  friendly_name   = 'Visual Studio Code (SSH)',
  name            = 'local/kasm-vs-code:1.17.0-ssh',
  docker_registry = NULL,
  available       = true,
  enabled         = true,
  description     = 'VS Code with an SSH client. Remote-SSH can reach this host at 172.20.0.1 as prodadmin.';

INSERT INTO images SELECT * FROM t;

-- Grant it to exactly the groups that already had the stock image, so this
-- changes availability for nobody who did not already have VS Code.
INSERT INTO group_images (group_image_id, group_id, image_id)
  SELECT uuid_generate_v4(), gi.group_id, (SELECT image_id FROM t)
  FROM group_images gi
  WHERE gi.image_id = '22746e61-cc2a-431e-9a97-02cd5c5977f4';

COMMIT;

SELECT friendly_name, name, enabled, available FROM images ORDER BY friendly_name;
