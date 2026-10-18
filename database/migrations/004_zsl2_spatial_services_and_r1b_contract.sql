BEGIN;
SET LOCAL search_path = pg_catalog,zsl,public,extensions;
CREATE OR REPLACE FUNCTION zsl.locations_within_radius(
  p_lat numeric,p_lon numeric,p_radius_miles numeric,p_location_types text[] DEFAULT NULL
) RETURNS TABLE(location_id uuid,location_type text,display_name text,distance_miles numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl,public,extensions AS $$
 SELECT l.location_id,l.location_type,l.display_name,
        round((ST_Distance(lp.point, ST_SetSRID(ST_MakePoint(p_lon,p_lat),4326)::geography)/1609.344)::numeric,3)
 FROM zsl.locations l JOIN zsl.location_points lp USING(location_id)
 WHERE l.active
   AND (p_location_types IS NULL OR l.location_type=ANY(p_location_types))
   AND ST_DWithin(lp.point,ST_SetSRID(ST_MakePoint(p_lon,p_lat),4326)::geography,p_radius_miles*1609.344)
 ORDER BY ST_Distance(lp.point,ST_SetSRID(ST_MakePoint(p_lon,p_lat),4326)::geography),l.canonical_key
$$;

CREATE OR REPLACE FUNCTION zsl.location_relationship_graph(p_location_id uuid)
RETURNS TABLE(direction text,relationship_type text,other_location_id uuid,other_type text,other_name text,authority text,tot_ratio numeric)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
 SELECT 'PARENT',r.relationship_type,r.parent_location_id,l.location_type,l.display_name,r.authority,r.tot_ratio
 FROM zsl.location_relationships r JOIN zsl.locations l ON l.location_id=r.parent_location_id
 WHERE r.child_location_id=p_location_id AND r.active
 UNION ALL
 SELECT 'CHILD',r.relationship_type,r.child_location_id,l.location_type,l.display_name,r.authority,r.tot_ratio
 FROM zsl.location_relationships r JOIN zsl.locations l ON l.location_id=r.child_location_id
 WHERE r.parent_location_id=p_location_id AND r.active
$$;

-- ZSL does not approve retail search authority. It emits factual candidates only.
CREATE OR REPLACE VIEW zsl.r1b_location_candidates AS
SELECT l.location_id AS zsl_location_id,l.canonical_key,l.location_type,l.country_code,l.display_name,
       st.usps_code AS state_code,
       pc.postal_code,
       cb.cbsa_code,
       cb.official_name AS metro_name,
       lp.latitude,lp.longitude,
       CASE
         WHEN l.location_type='state' THEN 'state'
         WHEN l.location_type='cbsa' AND cb.name_authority_status='AUTHORITATIVE' THEN 'metro'
         WHEN l.location_type='postal_code' AND pc.operational_authority_status='USPS_VALIDATED' THEN 'postal_code'
         ELSE NULL
       END AS r1b_eligible_location_type,
       l.identity_sha256 AS zsl_identity_sha256
FROM zsl.locations l
LEFT JOIN zsl.states st ON st.location_id=l.location_id
LEFT JOIN zsl.postal_codes pc ON pc.location_id=l.location_id
LEFT JOIN zsl.cbsa_metros cb ON cb.location_id=l.location_id
LEFT JOIN zsl.location_points lp ON lp.location_id=l.location_id
WHERE l.active;

CREATE TABLE IF NOT EXISTS zsl.r1b_location_sync_proposals(
  proposal_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  zsl_location_id uuid NOT NULL REFERENCES zsl.locations(location_id) ON DELETE RESTRICT,
  proposed_r1b_location_type text NOT NULL CHECK(proposed_r1b_location_type IN('state','metro','postal_code')),
  proposed_location_code text NOT NULL,
  proposal_document jsonb NOT NULL CHECK(jsonb_typeof(proposal_document)='object'),
  proposal_sha256 text NOT NULL CHECK(proposal_sha256 ~ '^[0-9a-f]{64}$'),
  status text NOT NULL DEFAULT 'PROPOSED' CHECK(status IN('PROPOSED','ACCEPTED_TO_DRAFT','REJECTED','SUPERSEDED')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE(zsl_location_id,proposal_sha256)
);
COMMIT;
