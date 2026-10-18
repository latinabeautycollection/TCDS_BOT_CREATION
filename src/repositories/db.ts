import pg from 'pg';
const {Pool}=pg;
export function pool(){const u=process.env.DATABASE_URL;if(!u)throw new Error('DATABASE_URL_REQUIRED');return new Pool({connectionString:u,ssl:{rejectUnauthorized:true},max:4,application_name:'tcds-zsl2'});}
