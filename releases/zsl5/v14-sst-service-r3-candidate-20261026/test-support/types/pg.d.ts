declare module 'pg' {
  export interface QueryResult<R=any>{rows:R[];rowCount:number|null}
  export interface PoolClient{query<R=any>(text:string,values?:any[]):Promise<QueryResult<R>>;release():void}
  export class Pool{constructor(config?:any);connect():Promise<PoolClient>;query<R=any>(text:string,values?:any[]):Promise<QueryResult<R>>;end():Promise<void>}
  const pg:{Pool:typeof Pool}; export default pg;
}
