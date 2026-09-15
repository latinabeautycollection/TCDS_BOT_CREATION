import { Pool } from 'pg';
import { readFile,stat } from 'node:fs/promises';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { shaFile,shaPackageTree,walkTree } from './artifact-hash';

const pool=new Pool({connectionString:process.env.DATABASE_URL});
const repoRoot=path.resolve(process.env.REPO_ROOT??process.cwd());
const actor=process.env.R1B_ACTOR_NAME??'R1B Existing Scraper Inventory';

function chooseEntrypoint(files:string[],root:string,pkg:any|null){
  const candidates=[pkg?.main,'src/index.ts','src/main.ts','src/worker.ts','index.ts','main.ts']
    .filter(Boolean) as string[];
  for(const x of candidates){
    const a=path.resolve(root,x);
    if(files.includes(a)) return a;
  }
  return files.find(f=>/\.(ts|js|mjs|cjs)$/.test(f))??null;
}

async function resolvePlatform(c:any,e:any){
  const candidates:Array<string>=e.platform_code_candidates??[];
  for(const code of candidates){
    const p=await c.query(
      `select id,platform_code from retail.retail_platforms where platform_code=$1`,
      [code]
    );
    if(p.rowCount) return p.rows[0];
  }
  return null;
}

async function main(){
  const correlationId=randomUUID();
  const run=await pool.query(`
    insert into arb.process_runs(
      process_name,process_stage,status,correlation_id,
      actor_type,actor_id,actor_name,
      worker_name,worker_instance_id,code_version,ruleset_version,
      entity_type,idempotency_key
    ) values(
      'RETAIL_R1B_SCRAPER_INVENTORY','EXECUTE','STARTED',$1,
      'service_account','r1b-scraper-inventory',$2,
      'r1b-scraper-inventory',$3,$4,'r1b-v4.0.0',
      'retail.retail_scraper_assets',$5
    ) returning run_id
  `,[correlationId,actor,
     process.env.WORKER_INSTANCE_ID??'r1b-v4-1',
     process.env.CODE_VERSION??process.env.GIT_SHA??'unknown',
     `RETAIL_R1B_SCRAPER_INVENTORY:${correlationId}`]);
  const runId=run.rows[0].run_id;

  const c=await pool.connect();
  try{
    await c.query('begin');
    await c.query(`select set_config('app.actor_type','service_account',true)`);
    await c.query(`select set_config('app.actor_id','r1b-scraper-inventory',true)`);
    await c.query(`select set_config('app.actor_name',$1,true)`,[actor]);
    await c.query(`select set_config('app.process_run_id',$1,true)`,[runId]);
    await c.query(`select set_config('app.correlation_id',$1,true)`,[correlationId]);

    let gitCommit:string|null=null;
    try{
      gitCommit=execFileSync('git',['rev-parse','HEAD'],{cwd:repoRoot,encoding:'utf8'}).trim();
    }catch{}

    const expected=await c.query(`
      select * from retail.r1b_expected_scraper_inventory order by expected_slot
    `);
    const results:any[]=[];

    for(const e of expected.rows){
      if(e.expectation_status==='missing_identity'){
        results.push({slot:e.expected_slot,status:'MISSING_IDENTITY'});
        continue;
      }

      const platform=await resolvePlatform(c,e);
      if(!platform){
        results.push({
          slot:e.expected_slot,platform:e.platform_code,
          status:'PLATFORM_NOT_REGISTERED',
          candidates:e.platform_code_candidates
        });
        continue;
      }

      const impl=path.resolve(repoRoot,e.implementation_root);
      let s;
      try{s=await stat(impl);}catch{
        results.push({
          slot:e.expected_slot,platform:e.platform_code,
          status:'IMPLEMENTATION_MISSING',path:impl
        });
        continue;
      }

      const authorityType=s.isFile()?'file':'package_tree';
      let files:string[];
      let treeHash:string;
      if(s.isFile()){
        files=[impl];
        treeHash=await shaFile(impl);
      }else{
        const t=await shaPackageTree(impl);
        files=t.files;
        treeHash=t.sha256;
      }

      const pkgFile=s.isDirectory()?path.join(impl,'package.json'):null;
      let pkg:any=null,pkgSha:string|null=null;
      if(pkgFile){
        try{
          const bytes=await readFile(pkgFile);
          pkg=JSON.parse(bytes.toString('utf8'));
          pkgSha=await shaFile(pkgFile);
        }catch{}
      }

      const entry=chooseEntrypoint(files,s.isDirectory()?impl:path.dirname(impl),pkg);
      const entrySha=entry?await shaFile(entry):null;
      const tests=files.filter(f=>
        /(^|\/)(test|tests|__tests__)(\/|$)|\.(test|spec)\.[cm]?[jt]s$/.test(f.replaceAll('\\','/'))
      );
      const sql=files.filter(f=>f.endsWith('.sql'));
      const sources=files.filter(f=>/\.(ts|js|mjs|cjs)$/.test(f));
      const scripts=pkg?.scripts??{};
      const execution=scripts.start?'npm run start':
        scripts.worker?'npm run worker':
        scripts.ingest?'npm run ingest':null;

      const evidence={
        git_commit_sha:gitCommit,
        implementation_root:e.implementation_root,
        implementation_authority_type:authorityType,
        package_tree_sha256:treeHash,
        entrypoint_ref:entry?path.relative(repoRoot,entry).replaceAll(path.sep,'/'):null,
        entrypoint_sha256:entrySha,
        package_json_sha256:pkgSha,
        source_file_count:sources.length,
        test_file_count:tests.length,
        sql_file_count:sql.length
      };

      const asset=await c.query(`
        insert into retail.retail_scraper_assets(
          platform_id,asset_code,implementation_root,implementation_kind,
          implementation_authority_type,
          repository_url,repository_branch,git_commit_sha,
          package_tree_sha256,entrypoint_ref,entrypoint_sha256,
          package_json_ref,package_json_sha256,
          execution_command,test_command,build_command,
          source_files_json,test_files_json,sql_files_json,
          discovery_status,verification_evidence_json,
          verified_by,verified_at,
          source_process_run_id,source_correlation_id
        ) values(
          $1,$2,$3,$4,$5,
          'https://github.com/latinabeautycollection/TCDS_BOT_CREATION','main',$6,
          $7,$8,$9,$10,$11,$12,$13,$14,
          $15::jsonb,$16::jsonb,$17::jsonb,
          'verified',$18::jsonb,$19,now(),$20,$21
        )
        on conflict(platform_id,asset_code,package_tree_sha256)
        do update set
          discovery_status=retail.retail_scraper_assets.discovery_status,
          updated_at=retail.retail_scraper_assets.updated_at
        returning id,verification_evidence_sha256
      `,[
        platform.id,`${e.platform_code}_existing_scraper`,
        e.implementation_root,e.implementation_kind,authorityType,
        gitCommit,treeHash,
        evidence.entrypoint_ref,entrySha,
        pkgFile?path.relative(repoRoot,pkgFile).replaceAll(path.sep,'/'):null,pkgSha,
        execution,pkg?.scripts?.test?'npm test':null,
        pkg?.scripts?.build?'npm run build':null,
        JSON.stringify(sources.map(f=>path.relative(repoRoot,f).replaceAll(path.sep,'/'))),
        JSON.stringify(tests.map(f=>path.relative(repoRoot,f).replaceAll(path.sep,'/'))),
        JSON.stringify(sql.map(f=>path.relative(repoRoot,f).replaceAll(path.sep,'/'))),
        JSON.stringify(evidence),actor,runId,correlationId
      ]);

      await c.query(`
        insert into retail.r1b_adapter_integration_matrix(
          platform_id,scraper_asset_id,expected_slot,platform_code,
          implementation_root,inventory_status,r1b_certification_status,notes
        ) values(
          $1,$2,$3,$4,$5,'verified',
          case when $4='walmart' then 'test_only' else 'inventory_pending' end,
          $6
        )
        on conflict(expected_slot) do update set
          platform_id=excluded.platform_id,
          scraper_asset_id=excluded.scraper_asset_id,
          platform_code=excluded.platform_code,
          implementation_root=excluded.implementation_root,
          inventory_status='verified',
          adapter_id=
            case
              when retail.r1b_adapter_integration_matrix.scraper_asset_id
                     is distinct from excluded.scraper_asset_id
                or not exists(
                  select 1
                  from retail.retail_search_adapters linked_adapter
                  where linked_adapter.id=
                          retail.r1b_adapter_integration_matrix.adapter_id
                    and linked_adapter.scraper_asset_id=
                          excluded.scraper_asset_id
                )
              then null
              else retail.r1b_adapter_integration_matrix.adapter_id
            end,
          scraper_contract_id=
            case
              when retail.r1b_adapter_integration_matrix.scraper_asset_id
                     is distinct from excluded.scraper_asset_id
                or not exists(
                  select 1
                  from retail.retail_scraper_contracts linked_contract
                  where linked_contract.id=
                          retail.r1b_adapter_integration_matrix.scraper_contract_id
                    and linked_contract.scraper_asset_id=
                          excluded.scraper_asset_id
                )
              then null
              else retail.r1b_adapter_integration_matrix.scraper_contract_id
            end,
          r1b_certification_status=
            case
              when excluded.platform_code='walmart'
                then 'test_only'
              when retail.r1b_adapter_integration_matrix.scraper_asset_id
                     is distinct from excluded.scraper_asset_id
                or not exists(
                  select 1
                  from retail.retail_search_adapters linked_adapter
                  where linked_adapter.id=
                          retail.r1b_adapter_integration_matrix.adapter_id
                    and linked_adapter.scraper_asset_id=
                          excluded.scraper_asset_id
                )
                or not exists(
                  select 1
                  from retail.retail_scraper_contracts linked_contract
                  where linked_contract.id=
                          retail.r1b_adapter_integration_matrix.scraper_contract_id
                    and linked_contract.scraper_asset_id=
                          excluded.scraper_asset_id
                )
              then 'inventory_pending'
              else retail.r1b_adapter_integration_matrix.r1b_certification_status
            end,
          notes=excluded.notes,updated_at=now()
      `,[
        platform.id,asset.rows[0].id,e.expected_slot,e.platform_code,
        e.implementation_root,
        e.platform_code==='walmart'
          ?'Visible implementation is a test harness; cannot be production-certified'
          :'Existing scraper inventoried/hash-bound; contract lifecycle required'
      ]);

      results.push({
        slot:e.expected_slot,platform:e.platform_code,status:'VERIFIED',
        authorityType,implementationSha256:treeHash,
        evidenceSha256:asset.rows[0].verification_evidence_sha256
      });
    }

    await c.query('commit');
    await pool.query(`
      update arb.process_runs
      set status='SUCCEEDED',completed_at=now(),rows_seen=$2,
          rows_succeeded=$3,rows_failed=0,updated_at=now()
      where run_id=$1
    `,[runId,expected.rowCount,results.filter(x=>x.status==='VERIFIED').length]);

    console.log(JSON.stringify({
      event:'r1b_existing_scraper_inventory_complete',
      processRunId:runId,correlationId,gitCommit,results
    },null,2));
  }catch(e){
    await c.query('rollback').catch(()=>undefined);
    await pool.query(`
      update arb.process_runs
      set status='FAILED',failed_at=now(),
          error_class=$2,error_summary=$3,updated_at=now()
      where run_id=$1
    `,[runId,(e as Error).name,String((e as Error).message??e).slice(0,2000)]);
    throw e;
  }finally{
    c.release();
    await pool.end();
  }
}
main().catch(e=>{console.error(e);process.exitCode=1;});
