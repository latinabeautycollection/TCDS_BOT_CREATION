BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;

CREATE TABLE zsl.zsl2_postal_territorial_area_evidence_v214(
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  source_key text NOT NULL CHECK(source_key='HUD_USPS_ZIP_COUNTY'),
  release_id uuid NOT NULL,
  ingest_run_id uuid NOT NULL,
  raw_record_id uuid NOT NULL,
  source_record_sha256 text NOT NULL CHECK(source_record_sha256 ~ '^[0-9a-f]{64}$'),
  postal_location_id uuid NOT NULL REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  postal_code text NOT NULL CHECK(postal_code ~ '^[0-9]{5}$'),
  state_code text NOT NULL,
  area_code text NOT NULL,
  res_ratio numeric(12,9),
  bus_ratio numeric(12,9),
  oth_ratio numeric(12,9),
  tot_ratio numeric(12,9),
  evidence_document jsonb NOT NULL,
  evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(normalization_run_id,source_key,raw_record_id),
  CHECK((state_code='AS' AND area_code='60') OR
        (state_code='FM' AND area_code='64') OR
        (state_code='MH' AND area_code='68') OR
        (state_code='PW' AND area_code='70'))
);
CREATE INDEX ix_zsl2_postal_territorial_area_run_v214
  ON zsl.zsl2_postal_territorial_area_evidence_v214(normalization_run_id,source_key);

DROP TRIGGER IF EXISTS trg_zsl2_postal_territorial_area_immutable_v214
  ON zsl.zsl2_postal_territorial_area_evidence_v214;
CREATE TRIGGER trg_zsl2_postal_territorial_area_immutable_v214
  BEFORE UPDATE OR DELETE ON zsl.zsl2_postal_territorial_area_evidence_v214
  FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_v214_evidence_immutable();

REVOKE ALL ON zsl.zsl2_postal_territorial_area_evidence_v214 FROM PUBLIC;
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_normalizer') THEN
   GRANT SELECT,INSERT ON zsl.zsl2_postal_territorial_area_evidence_v214 TO zsl2_normalizer;
 END IF;
 IF EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl2_certifier') THEN
   GRANT SELECT ON zsl.zsl2_postal_territorial_area_evidence_v214 TO zsl2_certifier;
 END IF;
END $$;
COMMIT;
