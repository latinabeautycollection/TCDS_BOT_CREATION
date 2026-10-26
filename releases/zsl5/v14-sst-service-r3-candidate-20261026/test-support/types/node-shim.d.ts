declare const process:{env:Record<string,string|undefined>;argv:string[];execPath:string;exitCode?:number;exit(code?:number):never};
declare const Buffer:{byteLength(input:string):number};
declare module 'node:crypto' { export function createHash(name:string):{update(v:string):any;digest(enc:'hex'):string}; export function randomUUID():string; }
declare module 'node:fs/promises' { export function readFile(path:any,encoding:'utf8'):Promise<string>; export function writeFile(path:any,data:string):Promise<void>; export function readdir(path:any,options?:any):Promise<any[]>; export function stat(path:any):Promise<any>; export function mkdir(path:any,options?:any):Promise<any>; }
declare module 'node:path' { export function join(...parts:string[]):string; export function dirname(path:string):string; export function resolve(...parts:string[]):string; }
declare module 'node:child_process' { export function spawn(command:string,args?:string[],options?:any):{on(event:string,listener:(arg?:any)=>void):any}; }
declare module 'node:test' { const test:(name:string,fn:()=>any|Promise<any>)=>void; export default test; }
declare module 'node:assert/strict' { const assert:any; export default assert; }
