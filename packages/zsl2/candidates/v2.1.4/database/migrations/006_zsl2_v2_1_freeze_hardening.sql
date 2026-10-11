BEGIN;
SET LOCAL search_path = pg_catalog,zsl,public,extensions;

-- Run-scoped membership prevents uncertified normalization writes from leaking into downstream authority.
CREATE TABLE IF NOT EXISTS zsl.zsl2_location_run_memberships(
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  location_id uuid NOT NULL REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  source_key text NOT NULL,
  release_id uuid NOT NULL,
  ingest_run_id uuid NOT NULL,
  source_record_sha256 text NOT NULL CHECK(source_record_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(normalization_run_id, location_id, source_key, source_record_sha256)
);
CREATE INDEX IF NOT EXISTS ix_zsl2_loc_membership_run ON zsl.zsl2_location_run_memberships(normalization_run_id,location_id);

CREATE TABLE IF NOT EXISTS zsl.zsl2_relationship_run_memberships(
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  relationship_id uuid NOT NULL REFERENCES zsl.location_relationships(relationship_id) ON DELETE RESTRICT,
  source_key text NOT NULL,
  release_id uuid NOT NULL,
  ingest_run_id uuid NOT NULL,
  source_record_sha256 text NOT NULL CHECK(source_record_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY(normalization_run_id, relationship_id, source_key, source_record_sha256)
);
CREATE INDEX IF NOT EXISTS ix_zsl2_rel_membership_run ON zsl.zsl2_relationship_run_memberships(normalization_run_id,relationship_id);

-- Mutable descriptive attributes and representative points are revisions, not identity.
CREATE TABLE IF NOT EXISTS zsl.zsl2_location_revisions(
  location_revision_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  location_id uuid NOT NULL REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  display_name text,
  authority_status text NOT NULL CHECK(authority_status IN ('AUTHORITATIVE','PROVISIONAL','PENDING_EXTERNAL_AUTHORITY','SUPERSEDED','RETIRED')),
  latitude numeric(9,6) CHECK(latitude IS NULL OR latitude BETWEEN -90 AND 90),
  longitude numeric(9,6) CHECK(longitude IS NULL OR longitude BETWEEN -180 AND 180),
  point geography(Point,4326),
  source_key text NOT NULL,
  source_release_id uuid NOT NULL,
  source_ingest_run_id uuid NOT NULL,
  source_record_sha256 text NOT NULL CHECK(source_record_sha256 ~ '^[0-9a-f]{64}$'),
  revision_document jsonb NOT NULL CHECK(jsonb_typeof(revision_document)='object'),
  revision_sha256 text NOT NULL CHECK(revision_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(normalization_run_id, location_id, source_key, source_record_sha256)
);
CREATE INDEX IF NOT EXISTS ix_zsl2_location_revisions_run ON zsl.zsl2_location_revisions(normalization_run_id,location_id);
CREATE INDEX IF NOT EXISTS gist_zsl2_location_revisions_point ON zsl.zsl2_location_revisions USING gist(point) WHERE point IS NOT NULL;

-- Immutable computed runtime checks. Certification cannot be obtained by supplying booleans from a caller.
CREATE TABLE IF NOT EXISTS zsl.zsl2_runtime_checks(
  runtime_check_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  check_name text NOT NULL,
  passed boolean NOT NULL,
  measured_value jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(measured_value)='object'),
  evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(normalization_run_id,check_name)
);

-- Explicit immutable authority activation/revocation events.
CREATE TABLE IF NOT EXISTS zsl.zsl2_authority_events(
  authority_event_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  certification_run_id uuid NOT NULL REFERENCES zsl.zsl2_certification_runs(certification_run_id) ON DELETE RESTRICT,
  event_type text NOT NULL CHECK(event_type IN ('ACTIVATED','REVOKED','SUPERSEDED')),
  reason text,
  evidence jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(evidence)='object'),
  evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_zsl2_authority_events_time ON zsl.zsl2_authority_events(created_at DESC,authority_event_id DESC);


-- HUD uses CBSA code 99999 for ZIP portions outside any CBSA. Preserve it as a factual observation,
-- never as a fabricated CBSA location. HUD may also report Metropolitan Division codes in divided metros.
ALTER TABLE zsl.cbsa_metros ADD COLUMN IF NOT EXISTS area_code_kind text NOT NULL DEFAULT 'HUD_CBSA_OR_METDIV_PENDING_OMB'
  CHECK(area_code_kind IN ('HUD_CBSA_OR_METDIV_PENDING_OMB','CBSA','METROPOLITAN_DIVISION'));

CREATE TABLE IF NOT EXISTS zsl.zsl2_postal_outside_cbsa_facts(
  fact_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  normalization_run_id uuid NOT NULL REFERENCES zsl.zsl2_normalization_runs(normalization_run_id) ON DELETE RESTRICT,
  postal_location_id uuid NOT NULL REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  res_ratio numeric(12,9),bus_ratio numeric(12,9),oth_ratio numeric(12,9),tot_ratio numeric(12,9),
  source_release_id uuid NOT NULL,
  source_ingest_run_id uuid NOT NULL,
  source_record_sha256 text NOT NULL CHECK(source_record_sha256 ~ '^[0-9a-f]{64}$'),
  evidence_document jsonb NOT NULL CHECK(jsonb_typeof(evidence_document)='object'),
  evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(normalization_run_id,source_record_sha256),
  CHECK((res_ratio IS NULL OR res_ratio BETWEEN 0 AND 1) AND (bus_ratio IS NULL OR bus_ratio BETWEEN 0 AND 1) AND
        (oth_ratio IS NULL OR oth_ratio BETWEEN 0 AND 1) AND (tot_ratio IS NULL OR tot_ratio BETWEEN 0 AND 1))
);
DROP TRIGGER IF EXISTS trg_zsl2_outside_cbsa_immutable ON zsl.zsl2_postal_outside_cbsa_facts;
CREATE TRIGGER trg_zsl2_outside_cbsa_immutable BEFORE UPDATE OR DELETE ON zsl.zsl2_postal_outside_cbsa_facts FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_prevent_mutation();
REVOKE ALL ON zsl.zsl2_postal_outside_cbsa_facts FROM PUBLIC;

-- HUD ratios are proportions and must be bounded.
ALTER TABLE zsl.location_relationships DROP CONSTRAINT IF EXISTS chk_zsl_ratio_bounds;
ALTER TABLE zsl.location_relationships ADD CONSTRAINT chk_zsl_ratio_bounds CHECK(
 (res_ratio IS NULL OR res_ratio BETWEEN 0 AND 1) AND
 (bus_ratio IS NULL OR bus_ratio BETWEEN 0 AND 1) AND
 (oth_ratio IS NULL OR oth_ratio BETWEEN 0 AND 1) AND
 (tot_ratio IS NULL OR tot_ratio BETWEEN 0 AND 1)
);


-- Deterministic current certified ingest per release, based on latest certification event for each ingest run.
CREATE OR REPLACE VIEW zsl.zsl2_current_source_certifications AS
WITH current_cert AS (
  SELECT DISTINCT ON (cr.ingest_run_id) cr.*
  FROM zsl.certification_runs cr
  ORDER BY cr.ingest_run_id,cr.created_at DESC,cr.certification_run_id DESC
), effective_run AS (
  SELECT DISTINCT ON (ir.release_id)
    ir.release_id,ir.ingest_run_id,cr.certification_run_id,cr.created_at
  FROM zsl.ingest_runs ir
  JOIN current_cert cr ON cr.ingest_run_id=ir.ingest_run_id AND cr.status='CERTIFIED'
  WHERE ir.state='RECONCILED'
  ORDER BY ir.release_id,ir.started_at DESC,ir.ingest_run_id DESC
)
SELECT s.source_key,sr.release_id,sr.release_key,sr.source_year,sr.source_quarter,sr.discovered_at,
       e.ingest_run_id,e.certification_run_id,e.created_at,'CERTIFIED'::text status
FROM zsl.source_registry s
JOIN zsl.source_releases sr ON sr.source_id=s.source_id
JOIN effective_run e ON e.release_id=sr.release_id;

-- Latest certification EVENT for a precise ZSL1 ingest run. Later REVOKED/SUPERSEDED invalidates earlier CERTIFIED.
CREATE OR REPLACE VIEW zsl.zsl2_zsl1_latest_ingest_certification AS
SELECT DISTINCT ON (cr.ingest_run_id)
  cr.ingest_run_id, cr.certification_run_id, cr.status, cr.created_at
FROM zsl.certification_runs cr
ORDER BY cr.ingest_run_id, cr.created_at DESC, cr.certification_run_id DESC;

CREATE OR REPLACE FUNCTION zsl.zsl2_bindings_still_valid(p_run uuid)
RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path=pg_catalog,zsl
AS $$
 SELECT NOT EXISTS (
   SELECT 1
   FROM zsl.zsl2_source_bindings b
   LEFT JOIN zsl.zsl2_zsl1_latest_ingest_certification c ON c.ingest_run_id=b.ingest_run_id
   WHERE b.normalization_run_id=p_run
     AND (c.certification_run_id IS DISTINCT FROM b.certification_run_id OR c.status IS DISTINCT FROM 'CERTIFIED')
 )
 AND EXISTS (SELECT 1 FROM zsl.zsl2_source_bindings b WHERE b.normalization_run_id=p_run)
$$;

-- Latest authority event globally. There is one effective canonical geography snapshot at a time.
CREATE OR REPLACE VIEW zsl.zsl2_current_authority AS
WITH latest AS (
 SELECT * FROM zsl.zsl2_authority_events
 ORDER BY created_at DESC, authority_event_id DESC
 LIMIT 1
), latest_cert AS (
 SELECT DISTINCT ON (c.normalization_run_id) c.*
 FROM zsl.zsl2_certification_runs c
 ORDER BY c.normalization_run_id,c.created_at DESC,c.certification_run_id DESC
)
SELECT l.normalization_run_id,l.certification_run_id,l.created_at AS activated_at
FROM latest l
JOIN latest_cert c ON c.certification_run_id=l.certification_run_id
WHERE l.event_type='ACTIVATED' AND c.status='CERTIFIED'
  AND zsl.zsl2_bindings_still_valid(l.normalization_run_id);

-- Run-scoped certified surfaces. No un-certified future normalization can leak here.
CREATE OR REPLACE VIEW zsl.certified_canonical_locations AS
SELECT
  l.location_id,l.location_type,l.country_code,l.canonical_key,
  COALESCE(r.display_name,l.display_name) AS display_name,
  COALESCE(r.authority_status,l.authority_status) AS authority_status,
  l.active,l.identity_document,l.identity_sha256,l.valid_from,l.valid_to,l.created_at,
  a.normalization_run_id,a.certification_run_id,
  r.latitude,r.longitude,r.point
FROM zsl.zsl2_current_authority a
JOIN (SELECT DISTINCT normalization_run_id,location_id FROM zsl.zsl2_location_run_memberships) m ON m.normalization_run_id=a.normalization_run_id
JOIN zsl.locations l ON l.location_id=m.location_id
LEFT JOIN LATERAL (
  SELECT rr.* FROM zsl.zsl2_location_revisions rr
  WHERE rr.normalization_run_id=a.normalization_run_id AND rr.location_id=l.location_id
  ORDER BY rr.created_at DESC,rr.location_revision_id DESC LIMIT 1
) r ON true
WHERE l.active
UNION ALL
SELECT l.location_id,l.location_type,l.country_code,l.canonical_key,l.display_name,l.authority_status,l.active,l.identity_document,l.identity_sha256,l.valid_from,l.valid_to,l.created_at,
       a.normalization_run_id,a.certification_run_id,null::numeric latitude,null::numeric longitude,null::geography(Point,4326) point
FROM zsl.zsl2_current_authority a
JOIN zsl.locations l ON l.canonical_key='US:NATIONAL' AND l.active;

CREATE OR REPLACE VIEW zsl.certified_canonical_relationships AS
SELECT r.*,a.normalization_run_id,a.certification_run_id
FROM zsl.zsl2_current_authority a
JOIN zsl.zsl2_relationship_run_memberships m ON m.normalization_run_id=a.normalization_run_id
JOIN zsl.location_relationships r ON r.relationship_id=m.relationship_id
WHERE r.active;

-- R1B candidates must be derived only from the effective certified snapshot.
CREATE OR REPLACE VIEW zsl.r1b_location_candidates AS
SELECT l.location_id AS zsl_location_id,l.canonical_key,l.location_type,l.country_code,l.display_name,
       st.usps_code AS state_code, pc.postal_code, cb.cbsa_code, cb.official_name AS metro_name,
       l.latitude,l.longitude,
       CASE
         WHEN l.location_type='state' THEN 'state'
         WHEN l.location_type='cbsa' AND cb.name_authority_status='AUTHORITATIVE' THEN 'metro'
         WHEN l.location_type='postal_code' AND pc.operational_authority_status='USPS_VALIDATED' THEN 'postal_code'
         ELSE NULL
       END AS r1b_eligible_location_type,
       l.identity_sha256 AS zsl_identity_sha256,
       l.normalization_run_id,l.certification_run_id
FROM zsl.certified_canonical_locations l
LEFT JOIN zsl.states st ON st.location_id=l.location_id
LEFT JOIN zsl.postal_codes pc ON pc.location_id=l.location_id
LEFT JOIN zsl.cbsa_metros cb ON cb.location_id=l.location_id;

ALTER TABLE zsl.r1b_location_sync_proposals ADD COLUMN IF NOT EXISTS normalization_run_id uuid;
ALTER TABLE zsl.r1b_location_sync_proposals ADD COLUMN IF NOT EXISTS certification_run_id uuid;
ALTER TABLE zsl.r1b_location_sync_proposals ADD COLUMN IF NOT EXISTS zsl_identity_sha256 text;
ALTER TABLE zsl.r1b_location_sync_proposals DROP CONSTRAINT IF EXISTS chk_zsl_r1b_prop_identity_sha;
ALTER TABLE zsl.r1b_location_sync_proposals ADD CONSTRAINT chk_zsl_r1b_prop_identity_sha CHECK(zsl_identity_sha256 IS NULL OR zsl_identity_sha256 ~ '^[0-9a-f]{64}$');

-- Immutability for evidence/membership/revisions/authority events.
DROP TRIGGER IF EXISTS trg_zsl2_loc_member_immutable ON zsl.zsl2_location_run_memberships;
CREATE TRIGGER trg_zsl2_loc_member_immutable BEFORE UPDATE OR DELETE ON zsl.zsl2_location_run_memberships FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_prevent_mutation();
DROP TRIGGER IF EXISTS trg_zsl2_rel_member_immutable ON zsl.zsl2_relationship_run_memberships;
CREATE TRIGGER trg_zsl2_rel_member_immutable BEFORE UPDATE OR DELETE ON zsl.zsl2_relationship_run_memberships FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_prevent_mutation();
DROP TRIGGER IF EXISTS trg_zsl2_revision_immutable ON zsl.zsl2_location_revisions;
CREATE TRIGGER trg_zsl2_revision_immutable BEFORE UPDATE OR DELETE ON zsl.zsl2_location_revisions FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_prevent_mutation();
DROP TRIGGER IF EXISTS trg_zsl2_runtime_checks_immutable ON zsl.zsl2_runtime_checks;
CREATE TRIGGER trg_zsl2_runtime_checks_immutable BEFORE UPDATE OR DELETE ON zsl.zsl2_runtime_checks FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_prevent_mutation();
DROP TRIGGER IF EXISTS trg_zsl2_authority_events_immutable ON zsl.zsl2_authority_events;
CREATE TRIGGER trg_zsl2_authority_events_immutable BEFORE UPDATE OR DELETE ON zsl.zsl2_authority_events FOR EACH ROW EXECUTE FUNCTION zsl.zsl2_prevent_mutation();

-- Public/anonymous execution and mutation are explicitly removed.
REVOKE ALL ON zsl.zsl2_location_run_memberships,zsl.zsl2_relationship_run_memberships,zsl.zsl2_location_revisions,zsl.zsl2_runtime_checks,zsl.zsl2_authority_events FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION zsl.zsl2_bindings_still_valid(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION zsl.zsl2_assert_required_sources_certified(text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION zsl.locations_within_radius(numeric,numeric,numeric,text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION zsl.location_relationship_graph(uuid) FROM PUBLIC;


-- Spatial services are current-authority only and validate parameters.
CREATE OR REPLACE FUNCTION zsl.locations_within_radius(
  p_lat numeric,p_lon numeric,p_radius_miles numeric,p_location_types text[] DEFAULT NULL
) RETURNS TABLE(location_id uuid,location_type text,display_name text,distance_miles numeric)
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl,extensions AS $$
BEGIN
 IF p_lat NOT BETWEEN -90 AND 90 OR p_lon NOT BETWEEN -180 AND 180 THEN RAISE EXCEPTION 'ZSL2_INVALID_COORDINATE'; END IF;
 IF p_radius_miles IS NULL OR p_radius_miles<=0 OR p_radius_miles>1000 THEN RAISE EXCEPTION 'ZSL2_INVALID_RADIUS'; END IF;
 RETURN QUERY
 SELECT l.location_id,l.location_type,l.display_name,
        round((ST_Distance(l.point, ST_SetSRID(ST_MakePoint(p_lon,p_lat),4326)::geography)/1609.344)::numeric,3)
 FROM zsl.certified_canonical_locations l
 WHERE l.point IS NOT NULL
   AND (p_location_types IS NULL OR l.location_type=ANY(p_location_types))
   AND ST_DWithin(l.point,ST_SetSRID(ST_MakePoint(p_lon,p_lat),4326)::geography,p_radius_miles*1609.344)
 ORDER BY ST_Distance(l.point,ST_SetSRID(ST_MakePoint(p_lon,p_lat),4326)::geography),l.canonical_key;
END $$;

CREATE OR REPLACE FUNCTION zsl.location_relationship_graph(p_location_id uuid)
RETURNS TABLE(direction text,relationship_type text,other_location_id uuid,other_type text,other_name text,authority text,tot_ratio numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
 SELECT 'PARENT',r.relationship_type,r.parent_location_id,l.location_type,l.display_name,r.authority,r.tot_ratio
 FROM zsl.certified_canonical_relationships r JOIN zsl.certified_canonical_locations l ON l.location_id=r.parent_location_id
 WHERE r.child_location_id=p_location_id
 UNION ALL
 SELECT 'CHILD',r.relationship_type,r.child_location_id,l.location_type,l.display_name,r.authority,r.tot_ratio
 FROM zsl.certified_canonical_relationships r JOIN zsl.certified_canonical_locations l ON l.location_id=r.child_location_id
 WHERE r.parent_location_id=p_location_id
$$;
REVOKE EXECUTE ON FUNCTION zsl.locations_within_radius(numeric,numeric,numeric,text[]) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION zsl.location_relationship_graph(uuid) FROM PUBLIC;

COMMIT;
