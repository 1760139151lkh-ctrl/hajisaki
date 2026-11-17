// Adapted from Evan Wallace's MIT-licensed ThumbHash decoder and PNG writer.
// https://github.com/evanw/thumbhash/blob/main/js/thumbhash.js
// Copyright (c) 2023 Evan Wallace. Full notice: rawfile/third-party-notices.txt.

interface HashImage { width:number; height:number; rgba:Uint8Array }
interface HashChannel { values:number[]; next:number }
const BASE64:string='ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

function encode64(bytes:Uint8Array):string {
  let value='';
  for(let i=0;i<bytes.length;i+=3) {
    const a=bytes[i],b=i+1<bytes.length?bytes[i+1]:0,c=i+2<bytes.length?bytes[i+2]:0;
    value+=BASE64[a>>2]+BASE64[((a&3)<<4)|(b>>4)]+(i+1<bytes.length?BASE64[((b&15)<<2)|(c>>6)]:'=')+
      (i+2<bytes.length?BASE64[c&63]:'=');
  }
  return value;
}

function decode64(value:string):Uint8Array {
  if(value.length<8 || value.length>36 || value.length%4!==0 || !/^[A-Za-z0-9+/]+={0,2}$/.test(value))
    throw new Error('Invalid ThumbHash encoding');
  const bytes:number[]=[];
  for(let i=0;i<value.length;i+=4) {
    const a=BASE64.indexOf(value[i]),b=BASE64.indexOf(value[i+1]);
    const c=value[i+2]==='='?0:BASE64.indexOf(value[i+2]),d=value[i+3]==='='?0:BASE64.indexOf(value[i+3]);
    bytes.push((a<<2)|(b>>4));
    if(value[i+2]!=='=')bytes.push(((b&15)<<4)|(c>>2));
    if(value[i+3]!=='=')bytes.push(((c&3)<<6)|d);
  }
  const result=new Uint8Array(bytes);
  if(encode64(result)!==value)throw new Error('Noncanonical ThumbHash encoding');
  return result;
}

function channel(hash:Uint8Array,start:number,index:number,nx:number,ny:number,scale:number):HashChannel {
  const values:number[]=[];
  for(let cy=0;cy<ny;cy++)for(let cx=cy?0:1;cx*ny<nx*(ny-cy);cx++) {
    if(start+(index>>1)>=hash.length)throw new Error('Incomplete ThumbHash');
    values.push((((hash[start+(index>>1)]>>((index&1)<<2))&15)/7.5-1)*scale);index++;
  }
  return {values:values,next:index};
}

function decodeImage(hash:Uint8Array):HashImage {
  if(hash.length<5 || (hash[3]&7)===0)throw new Error('Invalid ThumbHash header');
  const h24=hash[0]|(hash[1]<<8)|(hash[2]<<16),h16=hash[3]|(hash[4]<<8);
  const alpha=(h24&0x800000)!==0,landscape=(h16&0x8000)!==0,limit=alpha?5:7;
  const lx=Math.max(3,landscape?limit:h16&7),ly=Math.max(3,landscape?h16&7:limit);
  const start=alpha?6:5;
  if(hash.length<start)throw new Error('Incomplete ThumbHash header');
  const l=channel(hash,start,0,lx,ly,((h24>>18)&31)/31);
  const p=channel(hash,start,l.next,3,3,((h16>>3)&63)/63*1.25);
  const q=channel(hash,start,p.next,3,3,((h16>>9)&63)/63*1.25);
  const a=alpha?channel(hash,start,q.next,5,5,(hash[5]>>4)/15):{values:[],next:q.next} as HashChannel;
  if(start+Math.ceil(a.next/2)!==hash.length)throw new Error('Invalid ThumbHash length');
  const ratio=(landscape?limit:h16&7)/(landscape?h16&7:limit);
  const width=Math.round(ratio>1?32:32*ratio),height=Math.round(ratio>1?32/ratio:32);
  const xs:number[][]=[],ys:number[][]=[];
  for(let x=0;x<width;x++) {
    const row:number[]=[];
    for(let cx=0;cx<Math.max(lx,alpha?5:3);cx++)row.push(Math.cos(Math.PI/width*(x+0.5)*cx));
    xs.push(row);
  }
  for(let y=0;y<height;y++) {
    const row:number[]=[];
    for(let cy=0;cy<Math.max(ly,alpha?5:3);cy++)row.push(Math.cos(Math.PI/height*(y+0.5)*cy));
    ys.push(row);
  }
  const rgba=new Uint8Array(width*height*4);
  for(let y=0;y<height;y++)for(let x=0;x<width;x++) {
    let light=(h24&63)/63,yellow=((h24>>6)&63)/31.5-1,red=((h24>>12)&63)/31.5-1;
    let opacity=alpha?(hash[5]&15)/15:1;
    for(let cy=0,j=0;cy<ly;cy++)for(let cx=cy?0:1;cx*ly<lx*(ly-cy);cx++,j++)
      light+=l.values[j]*xs[x][cx]*ys[y][cy]*2;
    for(let cy=0,j=0;cy<3;cy++)for(let cx=cy?0:1;cx<3-cy;cx++,j++) {
      const f=xs[x][cx]*ys[y][cy]*2;yellow+=p.values[j]*f;red+=q.values[j]*f;
    }
    if(alpha)for(let cy=0,j=0;cy<5;cy++)for(let cx=cy?0:1;cx<5-cy;cx++,j++)
      opacity+=a.values[j]*xs[x][cx]*ys[y][cy]*2;
    const blue=light-2/3*yellow,r=(3*light-blue+red)/2,g=r-red,index=(y*width+x)*4;
    rgba[index]=Math.max(0,255*Math.min(1,r));rgba[index+1]=Math.max(0,255*Math.min(1,g));
    rgba[index+2]=Math.max(0,255*Math.min(1,blue));rgba[index+3]=Math.max(0,255*Math.min(1,opacity));
  }
  return {width:width,height:height,rgba:rgba};
}

function checksum(bytes:number[],start:number,end:number):void {
  const table:number[]=[0,498536548,997073096,651767980,1994146192,1802195444,1303535960,1342533948,
    -306674912,-267414716,-690576408,-882789492,-1687895376,-2032938284,-1609899400,-1111625188];
  let c=~0;
  for(let i=start;i<end;i++){c^=bytes[i];c=(c>>>4)^table[c&15];c=(c>>>4)^table[c&15];}
  c=~c;bytes[end]=c>>>24;bytes[end+1]=(c>>16)&255;bytes[end+2]=(c>>8)&255;bytes[end+3]=c&255;
}

function imageUri(image:HashImage):string {
  const w=image.width,h=image.height,row=w*4+1,idat=6+h*(5+row);
  const bytes:number[]=[137,80,78,71,13,10,26,10,0,0,0,13,73,72,68,82,0,0,w>>8,w&255,0,0,h>>8,h&255,
    8,6,0,0,0,0,0,0,0,idat>>>24,(idat>>16)&255,(idat>>8)&255,idat&255,73,68,65,84,120,1];
  let a=1,b=0;
  for(let y=0,i=0,end=row-1;y<h;y++,end+=row-1) {
    bytes.push(y+1<h?0:1,row&255,row>>8,~row&255,(row>>8)^255,0);
    b=(b+a)%65521;
    for(;i<end;i++){const u=image.rgba[i];bytes.push(u);a=(a+u)%65521;b=(b+a)%65521;}
  }
  bytes.push(b>>8,b&255,a>>8,a&255,0,0,0,0,0,0,0,0,73,69,78,68,174,66,96,130);
  checksum(bytes,12,29);checksum(bytes,37,41+idat);
  return 'data:image/png;base64,'+encode64(new Uint8Array(bytes));
}

/** Decode a bounded real hash locally, including its aspect ratio and alpha. */
export function thumbHashUri(value:string):string | undefined {
  try {return imageUri(decodeImage(decode64(value)));} catch (_) {return undefined;}
}
