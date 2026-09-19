export type DispatchStatus =
  | 'queued'|'leased'|'dispatching'|'succeeded'
  | 'retry_wait'|'dead_letter'|'cancelled';

export type PayloadDelivery =
  | 'env'|'argv'|'stdin_json'|'env_plus_stdin_json';

export type RunnerKind =
  | 'node_js'|'tsx_file'|'npm_script'|'external_queue';

export interface ClaimedJobV2 {
  job_id:string;
  lease_token:string;
  lease_expires_at:string;
  compilation_id:string;
  adapter_id:string;
  dispatch_binding_id:string;
  adapter_payload_json:{
    transport:string;
    compile_mode:string;
    parameters:Record<string,unknown>;
    collection?:Record<string,unknown>;
    constraints?:Record<string,unknown>;
  };
  normalized_job_json:Record<string,unknown>;
  estimated_cost_usd:string|number;
  attempt_no:number;
}
