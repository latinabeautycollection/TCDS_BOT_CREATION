export type RoundingMode='HALF_UP'|'HALF_EVEN'|'HALF_AWAY_FROM_ZERO'|'TRUNCATE'|'CEILING'|'FLOOR';
export function parseDecimalToScale(value:string,scale:number):bigint{
  if(!/^-?\d+(\.\d+)?$/.test(value))throw new Error('INVALID_DECIMAL');
  const neg=value.startsWith('-'),s=neg?value.slice(1):value,[w,f='']=s.split('.');
  const padded=(f+'0'.repeat(scale)).slice(0,scale);const n=BigInt(w)*10n**BigInt(scale)+BigInt(padded||'0');return neg?-n:n;
}
export function divRound(num:bigint,den:bigint,mode:RoundingMode='HALF_UP'):bigint{
  if(den<=0n)throw new Error('INVALID_DENOMINATOR');const neg=num<0n,a=neg?-num:num,q=a/den,rem=a%den;
  let inc=false;
  if(mode==='HALF_UP'||mode==='HALF_AWAY_FROM_ZERO')inc=rem*2n>=den;
  else if(mode==='HALF_EVEN'){const twice=rem*2n;inc=twice>den||(twice===den&&(q%2n===1n));}
  else if(mode==='CEILING')inc=!neg&&rem>0n;
  else if(mode==='FLOOR')inc=neg&&rem>0n;
  const v=q+(inc?1n:0n);return neg?-v:v;
}
export const divRoundHalfUp=(num:bigint,den:bigint)=>divRound(num,den,'HALF_UP');
export function mulCentsByRate(cents:bigint,rate:string,mode:RoundingMode='HALF_UP'):bigint{const r=parseDecimalToScale(rate,12),den=10n**12n;return divRound(cents*r,den,mode)}
export function allocateProRata(total:bigint,weights:bigint[]):bigint[]{if(total<0n||weights.some(x=>x<0n))throw new Error('NEGATIVE_ALLOCATION');const sum=weights.reduce((a,b)=>a+b,0n);if(sum===0n){if(total===0n)return weights.map(()=>0n);throw new Error('ZERO_ALLOCATION_WEIGHT')}const base=weights.map(w=>total*w/sum);let remainder=total-base.reduce((a,b)=>a+b,0n);const order=weights.map((w,i)=>({i,rem:(total*w)%sum})).sort((a,b)=>a.rem===b.rem?a.i-b.i:(a.rem>b.rem?-1:1));for(let k=0;remainder>0n;k++,remainder--)base[order[k%order.length].i]++;return base}
export function dollarsToCents(value:string|number,mode:RoundingMode='HALF_UP'):bigint{const s=typeof value==='number'?String(value):value;if(!/^-?\d+(\.\d+)?$/.test(s))throw new Error('INVALID_MONEY');const neg=s.startsWith('-'),x=neg?s.slice(1):s,[w,f='']=x.split('.'),frac=(f+'000').slice(0,3);let cents=BigInt(w)*100n+BigInt(frac.slice(0,2)||'0');const third=BigInt(frac[2]||'0');if((mode==='HALF_UP'||mode==='HALF_AWAY_FROM_ZERO')&&third>=5n)cents++;else if(mode==='HALF_EVEN'&&third>5n)cents++;else if(mode==='HALF_EVEN'&&third===5n&&cents%2n===1n)cents++;else if(mode==='CEILING'&&!neg&&third>0n)cents++;else if(mode==='FLOOR'&&neg&&third>0n)cents++;return neg?-cents:cents}
export function mulCentsByOneMinusRate(cents:bigint,rate:string,mode:RoundingMode='HALF_UP'):bigint{const r=parseDecimalToScale(rate,12),one=10n**12n;if(r<0n||r>one)throw new Error('INVALID_FRACTION');return divRound(cents*(one-r),one,mode)}
