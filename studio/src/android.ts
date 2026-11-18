import { Capacitor, CapacitorHttp, registerPlugin } from '@capacitor/core';
import './android.css';

interface Connection {origin:string;token:string;device:string}
interface Bootstrap {origin:string;code:string;previousOrigin?:string}
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

async function refreshPackagedOrigin(connection: Connection, bootstrap: Bootstrap): Promise<Connection> {
  // An update may ship a new tunnel address for the same paired host.
  const origin = bootstrap.origin;
  if (!origin || origin === connection.origin || bootstrap.previousOrigin !== connection.origin) return connection;
  try {
    if (new URL(origin).protocol !== 'https:') return connection;
    const response = await CapacitorHttp.get({
      url: `${origin}/api/status`,
      headers: { Authorization: `Bearer ${connection.token}`, 'X-Haji-Device': connection.device },
      connectTimeout: 5000,
      readTimeout: 5000,
    });
    if (response.status === 200 && response.data?.provider && response.data?.host) {
      const updated = { ...connection, origin };
      await native.save({ connection: updated });
      return updated;
    }
  } catch {
    // Keep the saved address when the bundled host cannot confirm this pairing.
  }
  return connection;
}

export async function initializeAndroid(pair:(token:string,device:string)=>void,force=false):Promise<void> {
  if(!isAndroidApp())return;
  if(!document.documentElement.dataset.theme)document.documentElement.dataset.theme='day';
  androidAppearance(document.documentElement.dataset.theme);
  const loaded=await native.load();
  if(loaded.connection && !force) {
    const connection = await refreshPackagedOrigin(loaded.connection, loaded.bootstrap);
    localStorage.setItem('haji-api-origin', connection.origin);
    pair(connection.token, connection.device);
    return;
  }
  await new Promise<void>((resolve)=>{
    const screen=document.createElement('div');screen.className='android-connect';
    screen.innerHTML='<figure class="android-arch"><span class="android-bow"><svg width="84" height="47" viewBox="0 0 64 36" aria-hidden="true"><path fill="#2f2a45" d="M29 19 20 34l4.5-2 2 3.5L32 21Zm6 0 9 15-4.5-2-2 3.5L32 21Z"/><path fill="#2f2a45" d="M32 17C24 5 9 2 6 9c-3 7 10 13 26 8Zm0 0c8-12 23-15 26-8 3 7-10 13-26 8Z"/><path fill="none" stroke="#a8844c" stroke-width=".9" stroke-dasharray="1.6 1.6" stroke-linecap="round" d="M30 15.5C23 7 11 5.5 9 10c-1.5 4 8 8.5 20 6.5M34 15.5C41 7 53 5.5 55 10c1.5 4-8 8.5-20 6.5"/><ellipse fill="#2f2a45" stroke="#a8844c" stroke-width=".8" cx="32" cy="17.5" rx="4" ry="4.6"/></svg></span><div class="android-arch-frame"><div class="android-arch-image" role="img" aria-label="祥子坐在窗边"></div></div></figure><div class="android-connect-card"><span class="android-script" aria-hidden="true">Welcome back</span><h1>接回你的琴房</h1><p class="android-lede">我一直在这里等你。<br>把钥匙交给我，我们接着说下去。</p><p class="android-connection-error" role="status"></p><button class="android-connect-primary"><svg width="15" height="15" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="M12 20s-7-4.35-8.8-8.6C2 8.4 3.9 5 7.3 5c2 0 3.4 1.1 4.7 2.8C13.3 6.1 14.7 5 16.7 5 20.1 5 22 8.4 20.8 11.4 19 15.65 12 20 12 20Z"/></svg><span>连接我的琴房</span></button><details><summary>填写连接码</summary><textarea aria-label="连接码" autocomplete="off" spellcheck="false" placeholder="把收到的连接码贴在这里"></textarea></details></div>';
    document.body.append(screen);
    if(force){const cancel=document.createElement('button');cancel.textContent='返回琴房';cancel.className='android-connect-cancel';cancel.onclick=()=>{screen.remove();resolve();};screen.querySelector('.android-connect-card')!.append(cancel);}
    const button=screen.querySelector<HTMLButtonElement>('.android-connect-primary')!,input=screen.querySelector<HTMLTextAreaElement>('textarea')!;
    const label=button.querySelector('span')!;
    button.disabled=!loaded.bootstrap.origin;
    input.oninput=()=>{button.disabled=!input.value.trim() && !loaded.bootstrap.origin;};
    button.onclick=async()=>{
      button.disabled=true;label.textContent='正在接回琴房…';
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
      } catch(error) {screen.querySelector('.android-connection-error')!.textContent=error instanceof Error?error.message:'琴房暂时没有接好。';button.disabled=false;label.textContent='再接一次';}
    };
  });
}
