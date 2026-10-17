BEGIN;
SET LOCAL search_path=pg_catalog,zsl,public,extensions;
CREATE OR REPLACE VIEW zsl.zsl3_zsl1_latest_ingest_certification AS
SELECT DISTINCT ON(cr.ingest_run_id) cr.ingest_run_id,cr.certification_run_id,cr.status,cr.created_at
FROM zsl.certification_runs cr ORDER BY cr.ingest_run_id,cr.created_at DESC,cr.certification_run_id DESC;

CREATE OR REPLACE FUNCTION zsl.zsl3_bindings_still_valid(p_build uuid)
RETURNS boolean LANGUAGE sql STABLE SECURITY DEFINER SET search_path=pg_catalog,zsl AS $$
 SELECT EXISTS(SELECT 1 FROM zsl.zsl3_source_bindings b WHERE b.build_run_id=p_build)
 AND NOT EXISTS(
   SELECT 1 FROM zsl.zsl3_source_bindings b
   LEFT JOIN zsl.zsl3_zsl1_latest_ingest_certification c ON c.ingest_run_id=b.ingest_run_id
   WHERE b.build_run_id=p_build AND (c.certification_run_id IS DISTINCT FROM b.certification_run_id OR c.status IS DISTINCT FROM 'CERTIFIED')
 )
 AND EXISTS(
   SELECT 1 FROM zsl.zsl3_build_runs br
   JOIN zsl.zsl2_current_authority a ON a.normalization_run_id=br.zsl2_normalization_run_id AND a.certification_run_id=br.zsl2_certification_run_id
   WHERE br.build_run_id=p_build
 )
$$;

CREATE OR REPLACE VIEW zsl.zsl3_current_authority AS
SELECT s.build_run_id,s.certification_run_id,s.authority_event_id,s.updated_at AS activated_at,c.runtime_check_run_id
FROM zsl.zsl3_authority_state s
JOIN zsl.zsl3_certification_runs c ON c.certification_run_id=s.certification_run_id AND c.build_run_id=s.build_run_id AND c.status='CERTIFIED'
JOIN zsl.zsl3_runtime_check_runs r ON r.runtime_check_run_id=c.runtime_check_run_id AND r.build_run_id=s.build_run_id AND r.status='PASS'
JOIN zsl.zsl3_build_runs b ON b.build_run_id=s.build_run_id AND b.state='RECONCILED'
WHERE s.singleton AND zsl.zsl3_bindings_still_valid(s.build_run_id);

CREATE OR REPLACE VIEW zsl.current_geographic_economic_features AS
SELECT v.*,a.certification_run_id,a.runtime_check_run_id
FROM zsl.zsl3_current_authority a
JOIN zsl.zsl3_geographic_feature_snapshot_values v ON v.build_run_id=a.build_run_id;
COMMIT;
