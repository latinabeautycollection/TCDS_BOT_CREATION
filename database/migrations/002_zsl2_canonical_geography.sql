BEGIN;
SET LOCAL search_path = pg_catalog,zsl,public,extensions;
CREATE TABLE IF NOT EXISTS zsl.locations(
  location_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  location_type text NOT NULL CHECK(location_type IN ('national','state','county','place','cbsa','zcta','postal_code')),
  country_code char(2) NOT NULL DEFAULT 'US',
  canonical_key text NOT NULL UNIQUE CHECK(length(canonical_key) BETWEEN 3 AND 160),
  display_name text,
  authority_status text NOT NULL CHECK(authority_status IN ('AUTHORITATIVE','PROVISIONAL','PENDING_EXTERNAL_AUTHORITY','SUPERSEDED','RETIRED')),
  active boolean NOT NULL DEFAULT true,
  identity_document jsonb NOT NULL CHECK(jsonb_typeof(identity_document)='object'),
  identity_sha256 text NOT NULL CHECK(identity_sha256 ~ '^[0-9a-f]{64}$'),
  valid_from date,
  valid_to date,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK(valid_to IS NULL OR valid_from IS NULL OR valid_to>=valid_from)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_zsl_location_identity_sha ON zsl.locations(identity_sha256);
CREATE INDEX IF NOT EXISTS ix_zsl_locations_type_active ON zsl.locations(location_type,active);

CREATE TABLE IF NOT EXISTS zsl.location_identifiers(
  identifier_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  location_id uuid NOT NULL REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  authority text NOT NULL,
  identifier_type text NOT NULL,
  identifier_value text NOT NULL,
  is_primary boolean NOT NULL DEFAULT false,
  valid_from date,
  valid_to date,
  source_release_id uuid,
  source_ingest_run_id uuid,
  record_sha256 text CHECK(record_sha256 IS NULL OR record_sha256 ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK(valid_to IS NULL OR valid_from IS NULL OR valid_to>=valid_from)
);
CREATE UNIQUE INDEX IF NOT EXISTS uq_zsl_location_identifier_version ON zsl.location_identifiers(authority,identifier_type,identifier_value,COALESCE(valid_from,'0001-01-01'::date));
CREATE INDEX IF NOT EXISTS ix_zsl_identifier_location ON zsl.location_identifiers(location_id);

CREATE TABLE IF NOT EXISTS zsl.location_points(
  location_id uuid PRIMARY KEY REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  latitude numeric(9,6) NOT NULL CHECK(latitude BETWEEN -90 AND 90),
  longitude numeric(9,6) NOT NULL CHECK(longitude BETWEEN -180 AND 180),
  point geography(Point,4326) NOT NULL,
  point_source text NOT NULL,
  source_release_id uuid,
  source_record_sha256 text CHECK(source_record_sha256 IS NULL OR source_record_sha256 ~ '^[0-9a-f]{64}$'),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS gist_zsl_location_points ON zsl.location_points USING gist(point);

CREATE TABLE IF NOT EXISTS zsl.location_geometries(
  geometry_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  location_id uuid NOT NULL REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  geometry_role text NOT NULL CHECK(geometry_role IN ('BOUNDARY','SERVICE_AREA')),
  geom geometry(MultiPolygon,4326) NOT NULL,
  authority text NOT NULL,
  source_release_id uuid,
  source_record_sha256 text CHECK(source_record_sha256 IS NULL OR source_record_sha256 ~ '^[0-9a-f]{64}$'),
  authoritative boolean NOT NULL DEFAULT false,
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(location_id,geometry_role,authority,source_release_id)
);
CREATE INDEX IF NOT EXISTS gist_zsl_location_geometries ON zsl.location_geometries USING gist(geom);


INSERT INTO zsl.locations(location_type,country_code,canonical_key,display_name,authority_status,identity_document,identity_sha256)
VALUES('national','US','US:NATIONAL','United States','AUTHORITATIVE',
       '{"authority":"ZSL2","country_code":"US","type":"NATIONAL"}'::jsonb,
       zsl.zsl2_sha256_jsonb('{"authority":"ZSL2","country_code":"US","type":"NATIONAL"}'::jsonb))
ON CONFLICT(canonical_key) DO NOTHING;

CREATE TABLE IF NOT EXISTS zsl.states(
  location_id uuid PRIMARY KEY REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  state_fips char(2) NOT NULL UNIQUE CHECK(state_fips ~ '^[0-9]{2}$'),
  usps_code char(2) NOT NULL UNIQUE CHECK(usps_code ~ '^[A-Z]{2}$'),
  official_name text NOT NULL
);
CREATE TABLE IF NOT EXISTS zsl.counties(
  location_id uuid PRIMARY KEY REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  county_fips char(5) NOT NULL UNIQUE CHECK(county_fips ~ '^[0-9]{5}$'),
  state_fips char(2) NOT NULL,
  official_name text NOT NULL
);
CREATE TABLE IF NOT EXISTS zsl.places(
  location_id uuid PRIMARY KEY REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  place_geoid char(7) NOT NULL UNIQUE CHECK(place_geoid ~ '^[0-9]{7}$'),
  state_fips char(2) NOT NULL,
  official_name text NOT NULL
);
CREATE TABLE IF NOT EXISTS zsl.zctas(
  location_id uuid PRIMARY KEY REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  zcta5 char(5) NOT NULL UNIQUE CHECK(zcta5 ~ '^[0-9]{5}$'),
  geoidfq text
);
CREATE TABLE IF NOT EXISTS zsl.cbsa_metros(
  location_id uuid PRIMARY KEY REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  cbsa_code char(5) NOT NULL UNIQUE CHECK(cbsa_code ~ '^[0-9]{5}$'),
  official_name text,
  name_authority_status text NOT NULL DEFAULT 'PENDING_CENSUS_OMB' CHECK(name_authority_status IN('PENDING_CENSUS_OMB','AUTHORITATIVE','SUPERSEDED'))
);
CREATE TABLE IF NOT EXISTS zsl.postal_codes(
  location_id uuid PRIMARY KEY REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  postal_code char(5) NOT NULL UNIQUE CHECK(postal_code ~ '^[0-9]{5}$'),
  operational_authority_status text NOT NULL DEFAULT 'PENDING_USPS_ZSL3' CHECK(operational_authority_status IN('HUD_OBSERVED_PENDING_USPS','PENDING_USPS_ZSL3','USPS_VALIDATED','RETIRED'))
);

CREATE TABLE IF NOT EXISTS zsl.location_relationships(
  relationship_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  parent_location_id uuid NOT NULL REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  child_location_id uuid NOT NULL REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  relationship_type text NOT NULL CHECK(relationship_type IN('CONTAINS','OVERLAPS','POSTAL_TO_COUNTY','POSTAL_TO_CBSA','ZCTA_ANALOG','STATE_OF','COUNTY_OF')),
  authority text NOT NULL,
  res_ratio numeric(12,9), bus_ratio numeric(12,9), oth_ratio numeric(12,9), tot_ratio numeric(12,9),
  source_release_id uuid,
  source_ingest_run_id uuid,
  source_record_sha256 text CHECK(source_record_sha256 IS NULL OR source_record_sha256 ~ '^[0-9a-f]{64}$'),
  evidence_document jsonb NOT NULL DEFAULT '{}'::jsonb CHECK(jsonb_typeof(evidence_document)='object'),
  evidence_sha256 text NOT NULL CHECK(evidence_sha256 ~ '^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK(parent_location_id<>child_location_id),
  UNIQUE(parent_location_id,child_location_id,relationship_type,authority,source_release_id)
);
CREATE INDEX IF NOT EXISTS ix_zsl_rel_parent ON zsl.location_relationships(parent_location_id,relationship_type) WHERE active;
CREATE INDEX IF NOT EXISTS ix_zsl_rel_child ON zsl.location_relationships(child_location_id,relationship_type) WHERE active;
COMMIT;
