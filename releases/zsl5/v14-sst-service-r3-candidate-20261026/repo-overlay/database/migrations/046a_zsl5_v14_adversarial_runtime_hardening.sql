-- TCDS 046a: adversarial runtime hardening for national tax authority
BEGIN;
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl_tax_certifier') THEN
  CREATE ROLE zsl_tax_certifier NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION NOBYPASSRLS;
 END IF;
END $$;
GRANT USAGE ON SCHEMA zsl_tax_acq TO zsl_tax_certifier;


CREATE TABLE IF NOT EXISTS zsl.zsl5_required_tcds_categories_v14(
  tcds_category_code text PRIMARY KEY,
  ordinal integer NOT NULL UNIQUE,
  requires_refinement boolean NOT NULL DEFAULT false,
  enabled boolean NOT NULL DEFAULT true
);
INSERT INTO zsl.zsl5_required_tcds_categories_v14(tcds_category_code,ordinal,requires_refinement) VALUES
('LAPTOPS',1,false),('PHONES',2,false),('NETWORKING',3,false),('AUTOMOTIVE_TOOLS',4,false),('GARDENING_TOOLS',5,false),
('GAME_CONSOLES',6,false),('MUSIC_EQUIPMENT',7,false),('DRONES',8,false),('CAMERAS',9,false),('ELECTRONICS',10,true)
ON CONFLICT(tcds_category_code) DO UPDATE SET ordinal=excluded.ordinal,requires_refinement=excluded.requires_refinement,enabled=true;

CREATE TABLE IF NOT EXISTS zsl_tax_acq.source_freshness_policies(
  family text PRIMARY KEY REFERENCES zsl_tax_acq.family_registry(family),
  review_interval_days integer NOT NULL CHECK(review_interval_days BETWEEN 1 AND 730),
  warning_days integer NOT NULL CHECK(warning_days BETWEEN 0 AND 730),
  policy_document jsonb NOT NULL CHECK(jsonb_typeof(policy_document)='object'),
  policy_sha256 text NOT NULL CHECK(policy_sha256~'^[0-9a-f]{64}$'),
  active boolean NOT NULL DEFAULT true
);
INSERT INTO zsl_tax_acq.source_freshness_policies(family,review_interval_days,warning_days,policy_document,policy_sha256)
SELECT f.family,
 CASE WHEN f.family IN('STATE_RATE','LOCAL_RATE','TAX_JURISDICTION_ASSIGNMENT','TAX_HOLIDAY') THEN 120 ELSE 365 END,
 CASE WHEN f.family IN('STATE_RATE','LOCAL_RATE','TAX_JURISDICTION_ASSIGNMENT','TAX_HOLIDAY') THEN 30 ELSE 60 END,
 jsonb_build_object('policy','REVALIDATION_REQUIRED','family',f.family),
 encode(extensions.digest(convert_to(jsonb_build_object('policy','REVALIDATION_REQUIRED','family',f.family)::text,'UTF8'),'sha256'),'hex')
FROM zsl_tax_acq.family_registry f WHERE f.enabled
ON CONFLICT(family) DO NOTHING;

CREATE TABLE IF NOT EXISTS zsl_tax_acq.publication_freshness_attestations(
  publication_id uuid NOT NULL REFERENCES zsl_tax_acq.national_publication_runs(publication_id) ON DELETE RESTRICT,
  state_code char(2) NOT NULL REFERENCES zsl_tax_acq.jurisdiction_registry(state_code),
  family text NOT NULL REFERENCES zsl_tax_acq.family_registry(family),
  status text NOT NULL CHECK(status IN('PASS','FAIL')),
  reviewed_at timestamptz NOT NULL,
  next_review_due timestamptz NOT NULL,
  evidence jsonb NOT NULL CHECK(jsonb_typeof(evidence)='object'),
  evidence_sha256 text NOT NULL CHECK(evidence_sha256~'^[0-9a-f]{64}$'),
  reviewed_by text NOT NULL CHECK(btrim(reviewed_by)<>''),
  PRIMARY KEY(publication_id,state_code,family),
  CHECK(next_review_due>reviewed_at)
);

CREATE OR REPLACE VIEW zsl_tax_acq.v_publication_freshness_readiness AS
SELECT p.publication_id,
       1071::bigint expected_cells,
       count(a.*) FILTER(WHERE a.status='PASS' AND a.next_review_due>now())::bigint current_cells,
       count(a.*) FILTER(WHERE a.status='FAIL' OR a.next_review_due<=now())::bigint stale_or_failed_cells,
       (count(a.*) FILTER(WHERE a.status='PASS' AND a.next_review_due>now())=1071) AS ready
FROM zsl_tax_acq.national_publication_runs p
LEFT JOIN zsl_tax_acq.publication_freshness_attestations a ON a.publication_id=p.publication_id
GROUP BY p.publication_id;

-- Latest-result semantics prevent stale historical PASS/FAIL rows from permanently biasing readiness.
CREATE OR REPLACE VIEW zsl_tax_acq.v_runtime_test_latest AS
SELECT DISTINCT ON(build_run_id,case_id) *
FROM zsl_tax_acq.runtime_test_results
ORDER BY build_run_id,case_id,executed_at DESC,test_result_id DESC;

CREATE OR REPLACE VIEW zsl_tax_acq.v_runtime_certification_readiness AS
SELECT b.build_run_id,
 (SELECT count(distinct state_code) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='GOLDEN' AND r.status='PASS') AS golden_states_passed,
 (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='GOLDEN' AND r.status='FAIL') AS golden_failures,
 (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='GOLDEN' AND r.status='NOT_EXECUTED') AS golden_not_executed,
 (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='ADVERSARIAL' AND r.status='FAIL') AS adversarial_failures,
 (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='ADVERSARIAL' AND r.status='NOT_EXECUTED') AS adversarial_not_executed,
 ((SELECT count(distinct state_code) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class='GOLDEN' AND r.status='PASS')=51
  AND (SELECT count(*) FROM zsl_tax_acq.v_runtime_test_latest r WHERE r.build_run_id=b.build_run_id AND r.test_class IN('GOLDEN','ADVERSARIAL') AND r.status<>'PASS')=0) AS ready
FROM zsl.zsl5_build_runs b WHERE b.engine_version='zsl5-v1.4.0';

CREATE OR REPLACE VIEW zsl_tax_acq.v_tax_security_posture AS
SELECT
 NOT EXISTS(
   SELECT 1 FROM information_schema.role_table_grants
   WHERE grantee='PUBLIC' AND table_schema IN('zsl','zsl_tax_acq')
     AND privilege_type IN('INSERT','UPDATE','DELETE','TRUNCATE')
     AND (table_name LIKE 'zsl5_%' OR table_name LIKE 'national_%' OR table_name LIKE 'runtime_%')
 )
 AND NOT EXISTS(
   SELECT 1
   FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace,
        LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a
   WHERE n.nspname IN('zsl','zsl_tax_acq') AND p.prosecdef AND a.grantee=0 AND a.privilege_type='EXECUTE'
     AND (p.proname LIKE 'zsl5_%' OR p.proname LIKE '%tax%' OR p.proname LIKE '%runtime%')
 ) AS no_public_mutation;

CREATE OR REPLACE VIEW zsl_tax_acq.v_tax_runtime_incomplete_states AS
SELECT s.state_code,r.family_pass_count,r.local_gate_pass,r.resolution_gate_pass,r.fatal_conflict_count,r.ready
FROM zsl_tax_acq.jurisdiction_registry s
LEFT JOIN zsl_tax_acq.state_runtime_readiness r USING(state_code)
WHERE s.enabled AND coalesce(r.ready,false)=false
ORDER BY s.state_code;

CREATE OR REPLACE VIEW zsl_tax_acq.v_tax_runtime_source_failures AS
SELECT * FROM zsl_tax_acq.runtime_population_runs WHERE status='FAIL' ORDER BY started_at DESC;

CREATE OR REPLACE VIEW zsl_tax_acq.v_tax_runtime_activation_blockers AS
SELECT g.build_run_id,
       g.publication_status,g.family_certified,g.local_certified,g.resolution_certified,g.fatal_conflicts,
       g.source_binding_count,g.bindings_valid,g.golden_states_passed,g.golden_failures,g.golden_not_executed,
       g.adversarial_failures,g.adversarial_not_executed,
       (SELECT count(*) FROM zsl.zsl5_required_tcds_categories_v14 rc WHERE rc.enabled) AS required_category_count,
       (SELECT count(distinct m.tcds_category_code) FROM zsl.zsl5_tax_product_mappings_v14 m JOIN zsl.zsl5_required_tcds_categories_v14 rc USING(tcds_category_code) WHERE m.build_run_id=g.build_run_id AND m.enabled AND rc.enabled) AS mapped_category_count,
       coalesce(f.ready,false) AS freshness_ready
FROM zsl.zsl5_v14_runtime_authority_gate g
JOIN zsl.zsl5_national_publication_bindings_v14 b ON b.build_run_id=g.build_run_id
LEFT JOIN zsl_tax_acq.v_publication_freshness_readiness f ON f.publication_id=b.publication_id;

CREATE OR REPLACE FUNCTION zsl_tax_acq.runtime_test_case_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.status='APPROVED' AND NEW IS DISTINCT FROM OLD THEN RAISE EXCEPTION 'APPROVED_RUNTIME_TEST_CASE_IMMUTABLE'; END IF;
  RETURN NEW;
END $$;
DROP TRIGGER IF EXISTS trg_runtime_test_case_guard ON zsl_tax_acq.runtime_test_cases;
CREATE TRIGGER trg_runtime_test_case_guard BEFORE UPDATE OR DELETE ON zsl_tax_acq.runtime_test_cases FOR EACH ROW EXECUTE FUNCTION zsl_tax_acq.runtime_test_case_guard();

CREATE OR REPLACE FUNCTION zsl_tax_acq.approve_runtime_test_case(p_case_id text,p_expected jsonb,p_independent_evidence jsonb,p_actor text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path=pg_catalog,zsl_tax_acq,extensions AS $$
DECLARE h text;
BEGIN
 IF NOT pg_has_role(session_user,'zsl_tax_certifier','member') AND session_user<>'postgres' THEN RAISE EXCEPTION 'TAX_CERTIFIER_ROLE_REQUIRED'; END IF;
 IF jsonb_typeof(p_expected)<>'object' OR jsonb_typeof(p_independent_evidence)<>'object' THEN RAISE EXCEPTION 'INVALID_TEST_EVIDENCE'; END IF;
 IF coalesce(p_independent_evidence->>'authority_url','') !~ '^https://' OR coalesce(p_independent_evidence->>'artifact_sha256','') !~ '^[0-9a-f]{64}$' THEN RAISE EXCEPTION 'INDEPENDENT_EVIDENCE_NOT_SEALED'; END IF;
 h:=encode(extensions.digest(convert_to(p_independent_evidence::text,'UTF8'),'sha256'),'hex');
 UPDATE zsl_tax_acq.runtime_test_cases SET status='APPROVED',expected_document=p_expected,independent_evidence=p_independent_evidence,independent_evidence_sha256=h,approved_by=p_actor,approved_at=now() WHERE case_id=p_case_id AND status='EVIDENCE_REQUIRED';
 IF NOT FOUND THEN RAISE EXCEPTION 'TEST_CASE_NOT_PENDING_OR_NOT_FOUND'; END IF;
END $$;

CREATE OR REPLACE FUNCTION zsl.zsl5_v14_reject_mutation() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN RAISE EXCEPTION 'ZSL5_V14_IMMUTABLE_HISTORY'; END $$;
DO $$ DECLARE t text; BEGIN FOREACH t IN ARRAY ARRAY['zsl5_quote_transactions_v14','zsl5_quote_line_items_v14','zsl5_quote_adjustments_v14','zsl5_tax_quote_evidence_v14'] LOOP
 EXECUTE format('DROP TRIGGER IF EXISTS %I ON zsl.%I','trg_'||t||'_immutable',t);
 EXECUTE format('CREATE TRIGGER %I BEFORE UPDATE OR DELETE ON zsl.%I FOR EACH ROW EXECUTE FUNCTION zsl.zsl5_v14_reject_mutation()','trg_'||t||'_immutable',t);
END LOOP; END $$;


DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl_tax_runtime_tester') THEN CREATE ROLE zsl_tax_runtime_tester NOLOGIN; END IF;
 IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname='zsl_tax_freshness_reviewer') THEN CREATE ROLE zsl_tax_freshness_reviewer NOLOGIN; END IF;
END $$;
GRANT USAGE ON SCHEMA zsl,zsl_tax_acq TO zsl_tax_runtime_tester,zsl_tax_freshness_reviewer;
REVOKE INSERT,UPDATE,DELETE,TRUNCATE ON zsl_tax_acq.publication_freshness_attestations,zsl_tax_acq.runtime_test_cases,zsl_tax_acq.runtime_test_results FROM PUBLIC;
GRANT SELECT ON zsl_tax_acq.publication_freshness_attestations,zsl_tax_acq.source_freshness_policies TO zsl_tax_freshness_reviewer;
GRANT INSERT ON zsl_tax_acq.publication_freshness_attestations TO zsl_tax_freshness_reviewer;
GRANT SELECT ON zsl_tax_acq.runtime_test_cases,zsl_tax_acq.v_runtime_test_latest,zsl_tax_acq.v_runtime_certification_readiness TO zsl_tax_runtime_tester;
GRANT INSERT ON zsl_tax_acq.runtime_test_results TO zsl_tax_runtime_tester;
GRANT SELECT ON zsl.zsl5_build_runs,zsl.zsl5_source_bindings,zsl.zsl5_tax_product_mappings_v14,zsl.zsl5_family_facts_v14,zsl.zsl5_applicability_assertions_v14,zsl.zsl5_national_publication_bindings_v14,zsl.zsl5_current_authority TO zsl_tax_runtime_tester;

REVOKE ALL ON FUNCTION zsl_tax_acq.approve_runtime_test_case(text,jsonb,jsonb,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION zsl_tax_acq.approve_runtime_test_case(text,jsonb,jsonb,text) TO zsl_tax_certifier;

COMMIT;
