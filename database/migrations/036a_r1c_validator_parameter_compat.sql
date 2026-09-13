BEGIN;

DO $$
BEGIN
  IF to_regclass('retail.r1c_schema_state') IS NULL
     OR NOT EXISTS (
       SELECT 1
       FROM retail.r1c_schema_state
       WHERE singleton = true
         AND schema_version = '2.0.0'
     ) THEN
    RAISE EXCEPTION 'R1C V2 schema 2.0.0 is required';
  END IF;

  IF to_regprocedure(
       'retail.r1c_validate_input_contract(jsonb,text,jsonb)'
     ) IS NULL THEN
    RAISE EXCEPTION 'Existing R1C input-contract validator is missing';
  END IF;
END
$$;

DROP FUNCTION retail.r1c_validate_input_contract(jsonb,text,jsonb);

CREATE FUNCTION retail.r1c_validate_input_contract(
  p_contract jsonb,
  p_compile_mode text,
  p_effective_required_fields jsonb
)
RETURNS void
LANGUAGE plpgsql IMMUTABLE
AS $$
DECLARE
  v_transport text;
  v_field text;
  v_mode_field text;
  v_allowed_fields constant text[] := ARRAY[
    'query','category','product_url','store_id',
    'postal_code','region','result_limit'
  ];
BEGIN
  IF p_contract IS NULL OR jsonb_typeof(p_contract) <> 'object' THEN
    RAISE EXCEPTION 'Input contract must be a JSON object';
  END IF;

  v_transport := NULLIF(p_contract->>'transport','');

  IF v_transport IS NULL
     OR v_transport NOT IN ('env','argv','json','query','hybrid') THEN
    RAISE EXCEPTION
      'Unsupported or missing input contract transport %',
      v_transport;
  END IF;

  IF NOT (p_contract ? 'compile_modes')
     OR jsonb_typeof(p_contract->'compile_modes') <> 'array'
     OR jsonb_array_length(p_contract->'compile_modes') = 0 THEN
    RAISE EXCEPTION 'compile_modes must be a non-empty array';
  END IF;

  IF COALESCE(
       (p_contract->'compile_modes') ? p_compile_mode,
       false
     ) IS NOT TRUE THEN
    RAISE EXCEPTION
      'Compile mode % not certified by input contract',
      p_compile_mode;
  END IF;

  IF NOT (p_contract ? 'field_map')
     OR jsonb_typeof(p_contract->'field_map') <> 'object'
     OR jsonb_object_length(p_contract->'field_map') = 0 THEN
    RAISE EXCEPTION 'field_map must be a non-empty object';
  END IF;

  IF p_effective_required_fields IS NULL
     OR jsonb_typeof(p_effective_required_fields) <> 'array' THEN
    RAISE EXCEPTION 'effective_required_fields must be an array';
  END IF;

  FOR v_field IN
    SELECT key
    FROM jsonb_each(p_contract->'field_map')
  LOOP
    IF NOT (v_field = ANY(v_allowed_fields)) THEN
      RAISE EXCEPTION
        'Unknown canonical field in field_map: %',
        v_field;
    END IF;

    IF NULLIF(
         p_contract #>> ARRAY['field_map',v_field],
         ''
       ) IS NULL THEN
      RAISE EXCEPTION
        'Empty target mapping for canonical field %',
        v_field;
    END IF;
  END LOOP;

  FOR v_field IN
    SELECT jsonb_array_elements_text(
      p_effective_required_fields
    )
  LOOP
    IF NOT (v_field = ANY(v_allowed_fields)) THEN
      RAISE EXCEPTION
        'Unknown required canonical field %',
        v_field;
    END IF;

    IF NULLIF(
         p_contract #>> ARRAY['field_map',v_field],
         ''
       ) IS NULL THEN
      RAISE EXCEPTION
        'Required field % lacks certified mapping',
        v_field;
    END IF;
  END LOOP;

  v_mode_field := CASE p_compile_mode
    WHEN 'keyword' THEN 'query'
    WHEN 'category' THEN 'category'
    WHEN 'product_url' THEN 'product_url'
    WHEN 'store_inventory' THEN 'store_id'
    ELSE NULL
  END;

  IF v_mode_field IS NULL THEN
    RAISE EXCEPTION 'Unknown compile mode %', p_compile_mode;
  END IF;

  IF NULLIF(
       p_contract #>> ARRAY['field_map',v_mode_field],
       ''
     ) IS NULL THEN
    RAISE EXCEPTION
      'Compile mode % requires field_map.%',
      p_compile_mode,
      v_mode_field;
  END IF;

  IF EXISTS (
    SELECT 1
    FROM (
      SELECT value, count(*) AS occurrences
      FROM jsonb_each_text(p_contract->'field_map')
      GROUP BY value
      HAVING count(*) > 1
    ) duplicates
  ) THEN
    RAISE EXCEPTION
      'Input contract maps multiple canonical fields to same adapter field';
  END IF;

  IF p_contract ? 'keyword_env'
     OR p_contract ? 'store_id_env'
     OR p_contract ? 'postal_code_env'
     OR p_contract ? 'region_env'
     OR p_contract ? 'result_limit_env' THEN
    RAISE EXCEPTION
      'Legacy *_env mappings prohibited; use canonical field_map';
  END IF;
END
$$;

COMMENT ON FUNCTION
  retail.r1c_validate_input_contract(jsonb,text,jsonb)
IS
  'Supabase/PostgreSQL compatibility replacement aligning the R1C V2 argument name and implementation with the signed R1C V3 validator.';

COMMIT;
