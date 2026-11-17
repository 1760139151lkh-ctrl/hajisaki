import { http } from '@kit.NetworkKit';
import { RelayTransport, RelayError, RelayResponse } from './RelayTransport';
import { previewMode } from '../model/BuildMode';

export class GatewayError extends Error {
  status: number;
  requestId: string;
  outcomeUncertain: boolean;
  constructor(status: number, message: string, requestId: string='', outcomeUncertain: boolean=false) {
    super(message); this.status=status; this.requestId=requestId; this.outcomeUncertain=outcomeUncertain;
  }
}

export class Gateway {
  onAvailabilityChange: (available: boolean) => void = (_available: boolean) => {};
  private primary: string = '';
  private fallback: string = '';
  private token: string = '';
  private device: string = '';
  private active: string = '';
  private relay?: RelayTransport;
  private relayActive: boolean = false;
  private pendingReceipt: string = '';
  private activeRequests: number = 0;
  private relayUpdating: boolean = false;
  private relayToken: string = '';
  private relayDevice: string = '';

  configure(primary: string, fallback: string, token: string, device: string): void {
    this.requireStableRelay();
    this.validateAddress(primary);
    if (fallback.length > 0) this.validateAddress(fallback);
    this.primary = primary.replace(/\/$/, '');
    this.fallback = fallback.replace(/\/$/, '');
    this.active = this.primary;
    this.relayActive = false;
    this.token = token.trim();
    this.device = device.trim();
  }

  private validateAddress(address: string): void {
    // Plain HTTP is only for an explicitly selected private development link.
    const privateHttp = /^http:\/\/(127\.0\.0\.1|localhost|10\.\d+\.\d+\.\d+|192\.168\.\d+\.\d+|172\.(1[6-9]|2\d|3[01])\.\d+\.\d+)(:\d+)?$/;
    if (!/^https:\/\/[a-zA-Z0-9.-]+(:\d+)?$/.test(address) && !privateHttp.test(address)) {
      throw new GatewayError(0, '请填写琴房的 HTTPS 地址，或开发时使用的私有网络地址。');
    }
  }

  isConfigured(): boolean { return this.token.length > 0 && this.primary.length > 0 && this.device.length > 0; }
  installRelay(relay: RelayTransport, activate: boolean = false, pairedToken: string = '', pairedDevice: string = ''): void {
    if(!relay.isConfigured()) throw new GatewayError(0,'备用琴房的证书与钥匙还没有配齐。');
    if((this.pendingReceipt && !this.relay?.sameIdentity(relay)) || this.relay?.isBusy() || (this.relay !== undefined && !this.relayUpdating)) {
      throw new GatewayError(409,'这封传送还没落笔，请先收好回执再换备用钥匙。');
    }
    const previous = this.relay;
    this.relay=relay;
    this.relayToken=pairedToken || this.token; this.relayDevice=pairedDevice || this.device;
    if (activate) this.relayActive=true;
    previous?.dispose();
  }
  beginRelayUpdate(candidate: RelayTransport): void {
    if(this.relayUpdating || this.activeRequests>0 || (this.pendingReceipt && !this.relay?.sameIdentity(candidate)) || this.relay?.isBusy()) {
      throw new GatewayError(409,'当前传送还没结束，稍等片刻再收好备用钥匙。');
    }
    this.relayUpdating=true;
  }
  relayIdentityChanges(candidate: RelayTransport): boolean { return this.relay!==undefined && !this.relay.sameIdentity(candidate); }
  currentRelayChannel(): string { return this.relay?.channel() || ''; }
  endRelayUpdate(): void { this.relayUpdating=false; }
  isRelayUpdating(): boolean { return this.relayUpdating; }
  private requireStableRelay(): void {
    if(this.relayUpdating) throw new GatewayError(423,'备用钥匙正在收好，稍等片刻再送来。');
  }
  hasUsableRelay(): boolean {
    return this.relay?.isConfigured()===true && this.relayToken.length>0 && this.relayDevice.length>0 &&
      this.token===this.relayToken && this.device===this.relayDevice;
  }
  isRelayActive(): boolean { return this.relayActive && this.hasUsableRelay(); }
  canStreamDirectly(): boolean { return !this.isRelayActive(); }
  endpoint(path: string): string { return this.active + path; }
  headers(): Record<string, string> {
    return { 'Authorization': 'Bearer ' + this.token, 'X-Haji-Device': this.device };
  }
  async request<T>(path: string, method: http.RequestMethod = http.RequestMethod.GET,
    body?: string | ArrayBuffer, readTimeoutMs: number = 20000): Promise<T> {
    this.requireStableRelay(); this.activeRequests++;
    try {
      const result = await this.route<T>(path,method,body,readTimeoutMs);
      this.onAvailabilityChange(true);
      return result;
    } catch (error) {
      const failure=error as GatewayError;
      if(failure.status===0||failure.status===401) this.onAvailabilityChange(false);
      throw failure;
    } finally { this.activeRequests--; }
  }
  private async route<T>(path: string, method: http.RequestMethod,
    body?: string | ArrayBuffer, readTimeoutMs: number = 20000): Promise<T> {
    if (!this.isConfigured()) throw new GatewayError(401, '还差最后一把钥匙。请到主机台连接琴房。');
    if(method!==http.RequestMethod.GET && this.pendingReceipt) {
      throw new GatewayError(409,'先确认上一封回执，再继续落笔。',this.pendingReceipt,true);
    }
    if(this.isRelayActive()) return this.performRelay<T>(path,method,body);
    try {
      return await this.perform<T>(this.active, path, method, body, readTimeoutMs);
    } catch (error) {
      const failure = error as GatewayError;
      // Safe reads can fail over. Mutations use idempotency or explicit retry, never blind duplication.
      if (failure.status === 0 && method === http.RequestMethod.GET) {
        if(this.fallback.length>0) {
          const alternate = this.active === this.primary ? this.fallback : this.primary;
          try {
            const result = await this.perform<T>(alternate,path,method,body,readTimeoutMs);
            this.active=alternate; return result;
          } catch(alternateError) {
            const alternateFailure=alternateError as GatewayError;
            if(alternateFailure.status!==0) throw alternateFailure;
          }
        }
        if(this.hasUsableRelay()) {
          const result=await this.performRelay<T>(path,method,body);
          this.relayActive=true; return result;
        }
      }
      throw failure;
    }
  }

  private async performRelay<T>(path:string,method:http.RequestMethod,body?:string|ArrayBuffer):Promise<T> {
    if(!this.hasUsableRelay()) throw new GatewayError(0,'备用琴房还没有接好。');
    const headers=this.headers();
    headers['Content-Type']=typeof body==='string'?'application/json':'application/octet-stream';
    try {
      const result=await this.relay!.request(path,method,headers,body);
      this.checkReceipt(result);
      return JSON.parse(result.body) as T;
    } catch(error) { throw this.relayFailure(error as Error); }
  }

  private checkReceipt(result:RelayResponse):void {
    if(result.outcomeUncertain) {
      this.pendingReceipt=result.requestId;
      throw new GatewayError(409,'这次回执还没到，原操作已经留好。',result.requestId,true);
    }
    if(this.pendingReceipt===result.requestId) this.pendingReceipt='';
    if(result.status<200||result.status>=300) throw new GatewayError(result.status,'这一步还没有完成，原稿已为你留好。',result.requestId,false);
  }
  private relayFailure(error:Error):GatewayError {
    if(error instanceof GatewayError) return error;
    if(error instanceof RelayError) {
      if(error.outcomeUncertain) this.pendingReceipt=error.requestId;
      return new GatewayError(error.status,error.message,error.requestId,error.outcomeUncertain);
    }
    return new GatewayError(0,'备用琴房暂时没有回音，原操作还在。');
  }
  async retryRelay(requestId:string):Promise<void> {
    this.requireStableRelay();
    if(!this.hasUsableRelay()) throw new GatewayError(0,'先接回备用琴房，再查询这封回执。',requestId,true);
    try { this.checkReceipt(await this.relay!.retry(requestId)); }
    catch(error) { throw this.relayFailure(error as Error); }
  }

  async readRelayChunk(path:string,start:number,end:number):Promise<ArrayBuffer> {
    this.requireStableRelay();
    if(!this.isRelayActive()) throw new GatewayError(0,'备用琴房还没有接好。');
    const headers=this.headers(); headers['Range']='bytes='+start+'-'+end;
    const result=await this.relay!.request(path,'GET',headers);
    const range=result.headers['content-range']||result.headers['Content-Range']||'';
    if(result.status!==206 || !range.startsWith('bytes '+start+'-'+end+'/') || result.data.byteLength!==end-start+1) {
      throw new GatewayError(0,'这一段文件还没有完整收齐，请重新取一次。');
    }
    return result.data;
  }

  private async perform<T>(address: string, path: string, method: http.RequestMethod,
    body?: string | ArrayBuffer, readTimeoutMs: number = 20000): Promise<T> {
    const connection = http.createHttp();
    const headers = this.headers();
    headers['Content-Type'] = typeof body === 'string' ? 'application/json' : 'application/octet-stream';
    try {
      const options: http.HttpRequestOptions = {
        method: method, header: headers, expectDataType: http.HttpDataType.STRING,
        connectTimeout: 4500, readTimeout: readTimeoutMs, usingCache: false, usingProxy: false
      };
      if (body !== undefined) options.extraData = body;
      const response = await connection.request(address + path, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        const code = response.responseCode;
        if(previewMode()) console.info('HajiSaki preview HTTP status='+code+', method='+method);
        let copy = '这一步还没完成，内容已为你留好。';
        if (code === 401 || code === 403) copy = '琴房的钥匙还没有对上，请检查设备名称与配对令牌。';
        if (code === 409) copy = '这一页正在续写，稍等片刻再试。';
        if (code === 413) copy = '这一份内容太大了，请拆成几份交给我。';
        throw new GatewayError(code, copy);
      }
      return JSON.parse(response.result as string) as T;
    } catch (error) {
      if (error instanceof GatewayError) throw error;
      throw new GatewayError(0, '……信号被晚风吹散了一下。你刚才的话还在本子上。');
    } finally { connection.destroy(); }
  }
}
