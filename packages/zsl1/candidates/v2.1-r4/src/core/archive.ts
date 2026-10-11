import { execFile } from "node:child_process";
import { promisify } from "node:util";
import type { SourcePolicy } from "./policy.js";
const exec = promisify(execFile);
export interface ZipMember { name:string; expandedBytes:number; compressedBytes:number; }
export async function inspectZip(path:string, policy:SourcePolicy):Promise<ZipMember[]> {
  const {stdout}=await exec("unzip",["-lv",path],{maxBuffer:16*1024*1024});
  const members:ZipMember[]=[];
  for(const line of stdout.split(/\r?\n/)){
    const m=line.match(/^\s*(\d+)\s+\S+\s+(\d+)\s+\S+\s+(?:\d{4}-\d{2}-\d{2}|\d{2}-\d{2}-\d{4})\s+\d{2}:\d{2}\s+[0-9a-fA-F]+\s+(.+)$/);
    if(!m)continue;
    const expandedBytes=Number(m[1]),compressedBytes=Number(m[2]),name=m[3]!.trim();
    if(name.includes("..")||name.startsWith("/")||name.includes("\\")||/^[A-Za-z]:/.test(name))throw new Error("UNSAFE_ARCHIVE_MEMBER_PATH");
    if(expandedBytes>policy.maxMemberBytes)throw new Error("ARCHIVE_MEMBER_SIZE_EXCEEDED");
    const ratio=compressedBytes===0?(expandedBytes===0?1:Number.POSITIVE_INFINITY):expandedBytes/compressedBytes;
    if(ratio>policy.maxCompressionRatio)throw new Error("ARCHIVE_COMPRESSION_RATIO_EXCEEDED");
    members.push({name,expandedBytes,compressedBytes});
  }
  if(!members.length)throw new Error("ARCHIVE_EMPTY_OR_UNREADABLE");
  if(members.length>policy.maxMembers)throw new Error("ARCHIVE_MEMBER_LIMIT_EXCEEDED");
  const total=members.reduce((n,x)=>n+x.expandedBytes,0);
  if(total>policy.maxExpandedBytes)throw new Error("ARCHIVE_EXPANDED_SIZE_EXCEEDED");
  return members;
}
