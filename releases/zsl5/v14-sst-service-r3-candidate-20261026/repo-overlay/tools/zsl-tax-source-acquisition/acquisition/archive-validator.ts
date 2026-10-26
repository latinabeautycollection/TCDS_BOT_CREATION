import { createHash } from 'node:crypto';import unzipper from 'unzipper';
const sha=(b:Buffer)=>createHash('sha256').update(b).digest('hex');
export async function validateZip(bytes:Buffer,limits={maxEntries:10000,maxUncompressedBytes:500_000_000,maxRatio:100}){
  const dir=await unzipper.Open.buffer(bytes);if(dir.files.length>limits.maxEntries)throw new Error('ZIP_TOO_MANY_ENTRIES');let total=0;const entries:any[]=[];
  for(const f of dir.files){if(f.path.includes('..')||f.path.startsWith('/')||f.path.includes('\\'))throw new Error('ZIP_PATH_TRAVERSAL');total+=f.uncompressedSize;if(total>limits.maxUncompressedBytes)throw new Error('ZIP_UNCOMPRESSED_LIMIT');if(f.compressedSize>0&&f.uncompressedSize/f.compressedSize>limits.maxRatio)throw new Error('ZIP_RATIO_LIMIT');if(f.type==='File'){const b=await f.buffer();entries.push({path:f.path,compressedSize:f.compressedSize,uncompressedSize:f.uncompressedSize,sha256:sha(b)});} }
  return {entryCount:dir.files.length,totalUncompressedBytes:total,entries};
}
