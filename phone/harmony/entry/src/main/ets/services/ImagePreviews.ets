import { http } from '@kit.NetworkKit';
import { Artifact } from '../model/Types';
import { Gateway } from './Gateway';
import { LocalStore } from './LocalStore';
import { thumbHashUri } from './ThumbHash';

export interface PictureData {
  supported: boolean;
  width: number;
  height: number;
  mime: string;
  image_base64: string;
  source_sha256?: string;
  thumbhash?: string;
  placeholder_base64?: string;
  animated?: boolean;
  page?: number;
  reason?: string;
}
export interface PictureResult { data: PictureData; stored: boolean }
export interface PictureMeta { placeholder: string; width: number; height: number; thumbhash?: string }
interface PictureInfo { supported:boolean; width:number; height:number; thumbhash:string; source_sha256:string; animated?:boolean }

export function isPicture(file: Artifact): boolean {
  return /^image\/(png|jpeg|webp|gif)$/i.test(file.mime);
}
export function pictureUri(data: PictureData): string { return 'data:'+data.mime+';base64,'+data.image_base64; }
export function pictureValid(data: PictureData,file: Artifact): boolean {
  return data?.supported===true && Number.isSafeInteger(data.width) && data.width>0 && data.width<=16384 &&
    Number.isSafeInteger(data.height) && data.height>0 && data.height<=16384 &&
    ['image/png','image/jpeg','image/webp'].includes(data.mime) && typeof data.image_base64==='string' &&
    data.image_base64.length>0 && data.image_base64.length<=4*1024*1024 && /^[A-Za-z0-9+/]+={0,2}$/.test(data.image_base64) &&
    (data.source_sha256===undefined || data.source_sha256===file.sha256);
}

/** Immutable source identities share requests and preserve real visited images. */
export class ImagePreviews {
  private gateway: Gateway;
  private local: LocalStore;
  private static memory: Map<string,PictureData> = new Map();
  private static pending: Map<string,Promise<PictureData>> = new Map();
  private static pendingInfo: Map<string,Promise<PictureInfo>> = new Map();
  constructor(gateway: Gateway,local: LocalStore) { this.gateway=gateway;this.local=local; }
  private key(file:Artifact,width:number,page:number,full:boolean):string {
    return file.sha256+':'+(full?'full':String(width))+':'+page;
  }
  async meta(file:Artifact,page:number=-1):Promise<PictureMeta | undefined> {
    try {
      const info=JSON.parse(await this.local.get('picture_meta_v2',file.sha256+':'+page,'')) as PictureInfo;
      const meta=this.decodeMeta(info,file);if(meta)return meta;
    } catch (_) { /* A first visit does not have a local hash yet. */ }
    try {
      const value=JSON.parse(await this.local.get('picture_meta_v1',file.sha256+':'+page,'')) as PictureMeta;
      if(typeof value.placeholder==='string' && value.placeholder.startsWith('data:image/png;base64,') && value.placeholder.length<64000)
        return value;
    } catch (_) { /* A first visit does not have a stored ThumbHash placeholder yet. */ }
    return undefined;
  }
  private decodeMeta(info:PictureInfo,file:Artifact):PictureMeta | undefined {
    if(info?.supported!==true || info.source_sha256!==file.sha256 || !Number.isSafeInteger(info.width) || info.width<1 ||
      info.width>16384 || !Number.isSafeInteger(info.height) || info.height<1 || info.height>16384 || typeof info.thumbhash!=='string')return undefined;
    const uri=thumbHashUri(info.thumbhash);
    return uri?{placeholder:uri,width:info.width,height:info.height,thumbhash:info.thumbhash}:undefined;
  }
  async prepare(file:Artifact,page:number=-1):Promise<PictureMeta | undefined> {
    const saved=await this.meta(file,page);
    if(saved?.thumbhash || page>=0)return saved;
    try {
      let pending=ImagePreviews.pendingInfo.get(file.sha256);
      if(!pending) {
        pending=this.gateway.request<PictureInfo>('/api/artifacts/'+encodeURIComponent(file.id)+'/image-info',http.RequestMethod.GET,undefined,45000);
        ImagePreviews.pendingInfo.set(file.sha256,pending);
      }
      let info:PictureInfo;
      try {info=await pending;} finally {ImagePreviews.pendingInfo.delete(file.sha256);}
      const meta=this.decodeMeta(info,file);if(!meta)return saved;
      try {await this.local.put('picture_meta_v2',file.sha256+':'+page,JSON.stringify(info));} catch (_) { /* The actual image has its own durable-cache result. */ }
      return meta;
    } catch (_) {return saved;}
  }
  private remember(key:string,value:PictureData):void {
    if(key.includes(':full:'))return;
    ImagePreviews.memory.delete(key);ImagePreviews.memory.set(key,value);
    if(ImagePreviews.memory.size>24) {
      const oldest=Array.from(ImagePreviews.memory.keys())[0];ImagePreviews.memory.delete(oldest);
    }
  }
  async read(file:Artifact,width:number=480,page:number=-1,full:boolean=false,force:boolean=false):Promise<PictureResult> {
    const key=this.key(file,width,page,full);
    if(!force) {
      const ready=ImagePreviews.memory.get(key);
      if(ready) return {data:ready,stored:true};
      try {
        const saved=await this.local.get('picture_preview_v1',key,'');
        if(saved) {const data=JSON.parse(saved) as PictureData;if(pictureValid(data,file)) {this.remember(key,data);return {data:data,stored:true};}}
      } catch (_) { /* An unavailable cache does not erase the original. */ }
    }
    let request=ImagePreviews.pending.get(key);
    if(!request) {
      request=this.fetch(file,width,page,full);ImagePreviews.pending.set(key,request);
    }
    let data:PictureData;
    try {data=await request;} finally {ImagePreviews.pending.delete(key);}
    let stored=true;
    try {
      await this.local.put('picture_preview_v1',key,JSON.stringify(data));
      if(data.thumbhash) {
        const info:PictureInfo={supported:true,width:data.width,height:data.height,thumbhash:data.thumbhash,source_sha256:file.sha256,animated:data.animated};
        if(this.decodeMeta(info,file))await this.local.put('picture_meta_v2',file.sha256+':'+page,JSON.stringify(info));
      } else if(data.placeholder_base64 && data.placeholder_base64.length<64000) {
        const meta:PictureMeta={placeholder:'data:image/png;base64,'+data.placeholder_base64,width:data.width,height:data.height};
        await this.local.put('picture_meta_v1',file.sha256+':'+page,JSON.stringify(meta));
      }
    } catch (_) {stored=false;}
    if(stored)this.remember(key,data);
    return {data:data,stored:stored};
  }
  private async fetch(file:Artifact,width:number,page:number,full:boolean):Promise<PictureData> {
    let data:PictureData;
    if(page>=0) data=await this.gateway.request<PictureData>('/api/artifacts/'+encodeURIComponent(file.id)+
      '/page-image?page='+page+'&width='+(full?1600:480),http.RequestMethod.GET,undefined,45000);
    else if(full && file.mime!=='image/gif') data=await this.gateway.request<PictureData>('/api/image-studio/preview',http.RequestMethod.POST,
      JSON.stringify({source_id:file.id,operations:[]}),45000);
    else data=await this.gateway.request<PictureData>('/api/artifacts/'+encodeURIComponent(file.id)+'/thumbnail?width='+width,
      http.RequestMethod.GET,undefined,45000);
    if(!pictureValid(data,file)) throw new Error('这一张画面还没有完整收齐，原件仍在。');
    return data;
  }
}
