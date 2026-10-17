type PolicyLike={upstream?:{zsl1?:{sha256BySourceKey?:Record<string,unknown>}}};
export function expectedZsl1PackageSha256(p:PolicyLike,sourceKey:string):string|null{
 const value=p?.upstream?.zsl1?.sha256BySourceKey?.[sourceKey];
 return typeof value==='string'&&/^[0-9a-f]{64}$/.test(value)?value:null;
}
export function isExactZsl1Package(p:PolicyLike,sourceKey:string,actual:unknown):boolean{
 const expected=expectedZsl1PackageSha256(p,sourceKey);
 return expected!==null&&actual===expected;
}
