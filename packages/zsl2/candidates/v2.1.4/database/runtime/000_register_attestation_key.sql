\set ON_ERROR_STOP on
-- Run only as the privileged migration owner. Supply -v key_id='...' -v hmac_secret='...'.
-- The secret must come from the deployment secret manager; do not commit it to source control.
INSERT INTO zsl.zsl2_runtime_attestation_keys(key_id,hmac_secret,active)
VALUES(:'key_id',:'hmac_secret',true)
ON CONFLICT(key_id) DO UPDATE SET hmac_secret=excluded.hmac_secret,active=true,retired_at=null;
