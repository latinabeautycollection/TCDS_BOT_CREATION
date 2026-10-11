\set ON_ERROR_STOP on
-- Run as a privileged staging migrator able to SET ROLE. Every forbidden statement must fail.
DO $$DECLARE ok boolean:=true; BEGIN
 IF has_table_privilege('zsl2_certifier','zsl.zsl2_authority_events','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'RBAC_FAIL:zsl2_certifier authority ledger direct write'; END IF;
 IF has_table_privilege('zsl2_normalizer','zsl.zsl2_certification_runs','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'RBAC_FAIL:zsl2_normalizer certification direct write'; END IF;
 IF has_table_privilege('zsl2_reader','zsl.locations','INSERT,UPDATE,DELETE') THEN RAISE EXCEPTION 'RBAC_FAIL:zsl2_reader canonical mutation'; END IF;
END $$;
