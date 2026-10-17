import pg from "pg";import type { PoolClient } from "pg";const {Pool}=pg;
const sslMode=(process.env.PGSSLMODE??'require').toLowerCase();const reject=(process.env.PGSSL_REJECT_UNAUTHORIZED??'true').toLowerCase()!=='false';
if(!process.env.DATABASE_URL)throw new Error('DATABASE_URL_REQUIRED');
export const pool=new Pool({connectionString:process.env.DATABASE_URL,application_name:'tcds-zsl1-v2.1',max:Number(process.env.ZSL_DB_POOL_MAX??5),statement_timeout:Number(process.env.ZSL_STATEMENT_TIMEOUT_MS??120000),idle_in_transaction_session_timeout:Number(process.env.ZSL_IDLE_TX_TIMEOUT_MS??60000),ssl:sslMode==='disable'?false:{rejectUnauthorized:reject}});
export async function withTx<T>(fn:(client:PoolClient)=>Promise<T>):Promise<T>{const c=await pool.connect();try{await c.query('BEGIN');await c.query("SET LOCAL lock_timeout='15s'");const v=await fn(c);await c.query('COMMIT');return v}catch(e){await c.query('ROLLBACK').catch(()=>{});throw e}finally{c.release()}}
