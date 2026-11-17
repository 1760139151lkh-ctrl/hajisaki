import { Capacitor, CapacitorHttp, registerPlugin } from '@capacitor/core';
import './android.css';

interface Connection {origin:string;token:string;device:string}
interface Bootstrap {origin:string;code:string}
interface NativeConnection {
  load():Promise<{connection?:Connection;bootstrap:Bootstrap;instance:string}>;
  save(options:{connection:Connection}):Promise<void>;
  clear():Promise<void>;
  appearance(options:{theme:string}):Promise<void>;
  saveFile(options:{name:string;mime:string;data?:string;path?:string}):Promise<void>;
}
const native=registerPlugin<NativeConnection>('HajiConnection');
export const isAndroidApp=()=>Capacitor.isNativePlatform();
export function apiAddress(path:string):string {return (isAndroidApp()?localStorage.getItem('haji-api-origin') || '':'')+path;}

export const disconnectAndroid=async()=>{if(isAndroidApp())await native.clear();};
export const androidAppearance=(theme:string)=>{if(isAndroidApp())void native.appearance({theme}).catch(()=>{});};
export async function saveAndroidBlob(blob:Blob,name:string):Promise<void> {
  const data=await new Promise<string>((resolve,reject)=>{const reader=new FileReader();reader.onload=()=>resolve(String(reader.result).split(',')[1]);reader.onerror=()=>reject(reader.error);reader.readAsDataURL(blob);});
  await native.saveFile({name,mime:blob.type || 'application/octet-stream',data});
}
export const saveAndroidPath=(path:string,name:string,mime:string)=>native.saveFile({path,name,mime});
export async function initializeAndroid(pair:(token:string,device:string)=>void,force=false):Promise<void> {
  if(!isAndroidApp())return;
  if(!document.documentElement.dataset.theme)document.documentElement.dataset.theme='day';
  androidAppearance(document.documentElement.dataset.theme);
  const loaded=await native.load();
  if(loaded.connection && !force) {
    localStorage.setItem('haji-api-origin',loaded.connection.origin);pair(loaded.connection.token,loaded.connection.device);return;
  }
  await new Promise<void>((resolve)=>{
    const screen=document.createElement('div');screen.className='android-connect';
    screen.innerHTML='<div class="android-connect-card"><span class="android-brand">♮</span><h1>接回你的琴房</h1><p class="android-connection-error" role="status"></p><button class="android-connect-primary">连接我的琴房</button><details><summary>填写连接码</summary><textarea aria-label="连接码" autocomplete="off" spellcheck="false"></textarea></details></div>';
    document.body.append(screen);
    if(force){const cancel=document.createElement('button');cancel.textContent='返回琴房';cancel.className='android-connect-cancel';cancel.onclick=()=>{screen.remove();resolve();};screen.querySelector('.android-connect-card')!.append(cancel);}
    const button=screen.querySelector<HTMLButtonElement>('button')!,input=screen.querySelector<HTMLTextAreaElement>('textarea')!;
    button.disabled=!loaded.bootstrap.origin;
    input.oninput=()=>{button.disabled=!input.value.trim() && !loaded.bootstrap.origin;};
    button.onclick=async()=>{
      button.disabled=true;button.textContent='正在接回…';
      try {
        let config=loaded.bootstrap;
        if(input.value.trim())config=JSON.parse(atob(input.value.trim().replace(/-/g,'+').replace(/_/g,'/'))) as Bootstrap;
        const url=new URL(config.origin);
        if(url.protocol!=='https:' && !['127.0.0.1','10.0.2.2','localhost'].includes(url.hostname))throw new Error('连接地址需要加密保护。');
        const response=await CapacitorHttp.post({url:config.origin+'/join',headers:{'Content-Type':'application/json'},
          data:{code:config.code,instance:loaded.instance},connectTimeout:12000,readTimeout:20000});
        if(response.status!==200)throw new Error(response.data?.detail || '连接码暂时没有对上。');
        const connection:Connection={origin:config.origin,token:response.data.token,device:response.data.device};
        await native.save({connection});localStorage.setItem('haji-api-origin',connection.origin);pair(connection.token,connection.device);
        screen.remove();resolve();
      } catch(error) {screen.querySelector('.android-connection-error')!.textContent=error instanceof Error?error.message:'琴房暂时没有接好。';button.disabled=false;button.textContent='再接一次';}
    };
  });
}
