\set ON_ERROR_STOP on
SELECT c.source_key,c.status,c.records_processed,c.lineage_processed,t.records_processed truth_records,t.lineage_processed truth_lineage,
       zsl.zsl2_source_snapshot_still_valid(c.normalization_run_id,c.source_key) snapshot_valid
FROM zsl.zsl2_normalization_checkpoints c
CROSS JOIN LATERAL zsl.zsl2_checkpoint_truth(c.normalization_run_id,c.source_key) t
WHERE c.normalization_run_id=:'run_id'::uuid
ORDER BY c.source_key;
