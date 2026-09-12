BEGIN;

DO $$
DECLARE
  extension_schema text;
BEGIN
  SELECT n.nspname
  INTO extension_schema
  FROM pg_extension e
  JOIN pg_namespace n ON n.oid = e.extnamespace
  WHERE e.extname = 'pgcrypto';

  IF extension_schema IS DISTINCT FROM 'extensions' THEN
    RAISE EXCEPTION
      'Expected pgcrypto in extensions schema, found %',
      coalesce(extension_schema, '<missing>');
  END IF;
END
$$;

CREATE OR REPLACE FUNCTION retail.r1a_sha256_jsonb(p_doc jsonb)
RETURNS text
LANGUAGE sql
IMMUTABLE
STRICT
PARALLEL SAFE
SET search_path = pg_catalog, extensions
AS $$
  SELECT pg_catalog.encode(
    extensions.digest(
      pg_catalog.convert_to(p_doc::text, 'UTF8'),
      'sha256'
    ),
    'hex'
  )
$$;

COMMENT ON FUNCTION retail.r1a_sha256_jsonb(jsonb) IS
  'Canonical R1A SHA-256 function with Supabase pgcrypto schema qualification.';

COMMIT;
