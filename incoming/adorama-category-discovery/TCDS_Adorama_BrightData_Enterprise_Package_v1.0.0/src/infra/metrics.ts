import client from "prom-client";
client.collectDefaultMetrics();
export const jobsTotal=new client.Counter({name:'adorama_jobs_total',help:'Jobs by terminal outcome',labelNames:['outcome']});
export const apiRequests=new client.Counter({name:'adorama_brightdata_api_requests_total',help:'Bright Data API calls',labelNames:['operation','status']});
export const recordsTotal=new client.Counter({name:'adorama_records_total',help:'Records processed',labelNames:['outcome']});
export const jobDuration=new client.Histogram({name:'adorama_job_duration_seconds',help:'End-to-end job duration'});
export const registry=client.register;
