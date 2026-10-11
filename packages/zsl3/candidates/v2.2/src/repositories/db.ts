import{Pool,type PoolClient}from'pg';
export const pool=new Pool({connectionString:process.env.DATABASE_URL,ssl:process.env.ZSL3_DB_SSL==='false'?undefined:{rejectUnauthorized:true},max:Number(process.env.ZSL3_DB_POOL_MAX??'8')});
export async function tx<T>(fn:(c:PoolClient)=>Promise<T>):Promise<T>{const c=await pool.connect();try{await c.query('BEGIN');const v=await fn(c);await c.query('COMMIT');return v}catch(e){await c.query('ROLLBACK');throw e}finally{c.release()}}
export async function advisory(c:PoolClient,key:string):Promise<void>{const r=await c.query<{ok:boolean}>('SELECT pg_try_advisory_xact_lock(hashtextextended($1,0)) ok',[key]);if(!r.rows[0]?.ok)throw new Error('ZSL3_ADVISORY_LOCK_BUSY:'+key)}
