export function detectDelimiter(header:string):"\t"|"|"|"," {
  const counts={"\t":header.split("\t").length,"|":header.split("|").length,",":header.split(",").length};
  return (Object.entries(counts).sort((a,b)=>b[1]-a[1])[0]![0]) as "\t"|"|"|",";
}
export function parseDelimitedLine(line:string,delimiter:string):string[]{
  if(delimiter!==",")return line.split(delimiter).map(x=>x.trim());
  const out:string[]=[];let cur="",quoted=false;
  for(let i=0;i<line.length;i++){const c=line[i]!;if(c==='"'){if(quoted&&line[i+1]==='"'){cur+='"';i++;}else quoted=!quoted;}else if(c===delimiter&&!quoted){out.push(cur);cur="";}else cur+=c;}
  out.push(cur);return out.map(x=>x.trim());
}
export async function* parseCsvStream(stream:NodeJS.ReadableStream):AsyncIterable<string[]> {
  let row:string[]=[],field="",quoted=false,pendingQuote=false;
  for await(const chunk of stream as any as AsyncIterable<Buffer|string>){const s=typeof chunk==='string'?chunk:chunk.toString('utf8');
    for(let i=0;i<s.length;i++){const c=s[i]!;
      if(pendingQuote){pendingQuote=false;if(c==='"'){field+='"';continue;}quoted=false;}
      if(c==='"'){if(quoted){if(i===s.length-1){pendingQuote=true;}else if(s[i+1]==='"'){field+='"';i++;}else quoted=false;}else quoted=true;continue;}
      if(c===','&&!quoted){row.push(field);field="";continue;}
      if((c==='\n'||c==='\r')&&!quoted){if(c==='\r'&&s[i+1]==='\n')i++;row.push(field);field="";if(row.some(x=>x.length))yield row;row=[];continue;}
      field+=c;
    }}
  if(pendingQuote)quoted=false;if(quoted)throw new Error('CSV_UNTERMINATED_QUOTE');
  if(field.length||row.length){row.push(field);if(row.some(x=>x.length))yield row;}
}
