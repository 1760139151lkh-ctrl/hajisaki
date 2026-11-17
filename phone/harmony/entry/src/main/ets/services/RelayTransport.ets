import { http } from '@kit.NetworkKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { fileIo as fs } from '@kit.CoreFileKit';

// HSR1 matches relay/hajisaki_relay/protocol.py. Requires the real API 26 SDK.
// Credentials must be resolved from the app's secure credential store by its owner.
// The journal must durably persist encrypted bytes before resolving saveRequest.
// This class never persists or logs raw keys, tokens, paths or decrypted responses.
// HTTPS is intentional: the public OpenHarmony WebSocket implementation enables
// hostname/self-signed bypass flags. NetworkKit HTTP adds mandatory SPKI pinning
// to CA verification and mTLS; no insecure WebSocket fallback is implemented.
export interface RelayConfig {
  origin: string; // bare https://host:port; http://loopback:port only in explicit development
  channel: string;
  development: boolean;
}

export interface RelayCredentials {
  channelToken: string;
  masterKeyBase64: string;
  privateRoot: string; // actual UIAbilityContext.filesDir, not an imported JSON value
  caPath: string;
  certPath: string;
  keyPath: string;
  serverPublicKeySha256: string; // base64 SHA256(DER SubjectPublicKeyInfo), from trusted provisioning
  keyPassword?: string;
}

export interface RelayJournal {
  saveRequest(channel: string, id: string, encrypted: ArrayBuffer, method: string): Promise<void>;
  readRequest(channel: string, id: string): Promise<ArrayBuffer>;
  saveResponse(channel: string, id: string, encrypted: ArrayBuffer, settled: boolean): Promise<void>;
}

export interface RelayResponse {
  status: number;
  body: string; // JSON/text only; binary downloads use data
  data: ArrayBuffer;
  headers: Record<string, string>;
  requestId: string;
  outcomeUncertain: boolean;
}

export class RelayError extends Error {
  status: number;
  requestId: string;
  outcomeUncertain: boolean;
  constructor(status: number, message: string, requestId: string = '', uncertain: boolean = false) {
    super(message);
    this.status = status;
    this.requestId = requestId;
    this.outcomeUncertain = uncertain;
  }
}

interface WireHeader { exp: number; id: string; iat: number; kind: string; nonce: string; v: number; }
interface WireRequest { headers: Record<string, string>; method: string; path: string; }
interface WireResponse {
  headers: Record<string, string>;
  outcome_uncertain: boolean;
  request_digest: string;
  status: number;
}
interface OpenedFrame { header: WireHeader; plain: Uint8Array; metadata: string; body: Uint8Array; }
interface PreparedRequest { id: string; method: string; digest: string; frame: Uint8Array; }
interface ActiveRequest {
  cancel: () => void;
}

const MAX_BODY: number = 4194304;
const MAX_META: number = 16384;
const MAX_HEADER: number = 1024;
const MAX_FRAME: number = 4211738;
const MAX_INFLIGHT: number = 8;
const WINDOW_MS: number = 120000;
const SKEW_MS: number = 30000;

export class RelayTransport {
  private config?: RelayConfig;
  private journal?: RelayJournal;
  private tlsOptions?: http.HttpRequestOptions;
  private requestKey?: cryptoFramework.SymKey;
  private responseKey?: cryptoFramework.SymKey;
  private pending: Map<string, ActiveRequest> = new Map<string, ActiveRequest>();
  private preparing: number = 0;
  private configuring: boolean = false;
  private identity: string = '';
  private base64: util.Base64Helper = new util.Base64Helper();

  async configure(config: RelayConfig, credentials: RelayCredentials, journal: RelayJournal): Promise<void> {
    if (this.configuring || this.preparing > 0 || this.pending.size > 0) {
      throw new RelayError(409, '这段传送还未落笔，请等它结束后再换钥匙。');
    }
    this.configuring = true;
    this.close();
    this.config = undefined;
    this.journal = undefined;
    this.requestKey?.clearMem();
    this.responseKey?.clearMem();
    this.requestKey = undefined;
    this.responseKey = undefined;
    this.identity = '';
    let secret: Uint8Array = new Uint8Array();
    try {
      if (!canIUse('SystemCapability.Security.CryptoFramework.Kdf') ||
        !canIUse('SystemCapability.Security.CryptoFramework.Cipher') ||
        !canIUse('SystemCapability.Security.CryptoFramework.MessageDigest')) {
        throw new RelayError(503, '这台设备暂时缺少备用通道所需的加密能力。');
      }
      if (!/^[A-Za-z0-9_-]{20,64}$/.test(config.channel) || typeof config.development !== 'boolean') {
        throw new RelayError(400, '备用通道的地址或钥匙还没有配齐。');
      }
      const secure = /^https:\/\/(?:[a-zA-Z0-9.-]+|\[[a-fA-F0-9:]+\]):[0-9]{1,5}$/.test(config.origin);
      const local = /^http:\/\/(127\.0\.0\.1|\[::1\]):[0-9]{1,5}$/.test(config.origin);
      const port = Number(config.origin.substring(config.origin.lastIndexOf(':') + 1));
      if (!(config.development ? local : secure) || port < 1 || port > 65535) {
        throw new RelayError(400, '备用通道需要受信任的加密地址。');
      }
      if (!/^[A-Za-z0-9_-]{40,128}$/.test(credentials.channelToken)) {
        throw new RelayError(401, '备用通道的钥匙还没有配齐。');
      }
      secret = this.base64.decodeSync(credentials.masterKeyBase64);
      if (secret.length !== 32 || this.base64.encodeToStringSync(secret) !== credentials.masterKeyBase64) {
        throw new RelayError(401, '备用通道的钥匙还没有配齐。');
      }
      const options: http.HttpRequestOptions = {
        header: { 'Authorization': 'Bearer ' + credentials.channelToken, 'Content-Type': 'application/octet-stream',
          'Accept-Encoding': 'identity' },
        usingProxy: false, remoteValidation: 'system', maxRedirects: 0
      };
      if (!config.development) {
        this.validatePrivateFile(credentials.privateRoot, credentials.caPath);
        this.validatePrivateFile(credentials.privateRoot, credentials.certPath);
        this.validatePrivateFile(credentials.privateRoot, credentials.keyPath);
        const pin = this.base64.decodeSync(credentials.serverPublicKeySha256);
        if (pin.length !== 32 || this.base64.encodeToStringSync(pin) !== credentials.serverPublicKeySha256) {
          throw new RelayError(401, '还缺少备用通道的可信公钥指纹，请重新导入。');
        }
        options.caPath = credentials.caPath;
        options.clientCert = { certPath: credentials.certPath, keyPath: credentials.keyPath,
          certType: http.CertType.PEM, keyPassword: credentials.keyPassword ?? '' };
        options.certificatePinning = { publicKeyHash: credentials.serverPublicKeySha256, hashAlgorithm: 'SHA-256' };
        options.tlsOptions = { tlsVersionMin: http.TlsVersion.TLS_V_1_3, tlsVersionMax: http.TlsVersion.TLS_V_1_3 };
      }
      const salt = await this.sha(this.bytes(config.channel));
      this.requestKey = await this.derive(secret, salt, 'request');
      this.responseKey = await this.derive(secret, salt, 'response');
      const identityMaterial = this.concat(this.bytes(config.channel+'\u0000'),secret);
      try { this.identity = this.hex(await this.sha(identityMaterial)); }
      finally { identityMaterial.fill(0); }
      this.config = { origin: config.origin, channel: config.channel, development: config.development };
      this.tlsOptions = options;
      this.journal = journal;
    } catch (error) {
      this.requestKey?.clearMem();
      this.responseKey?.clearMem();
      this.requestKey = undefined;
      this.responseKey = undefined;
      this.tlsOptions = undefined;
      if (error instanceof RelayError) throw error;
      throw new RelayError(401, '备用通道的证书或钥匙暂时读不到，请重新导入。');
    } finally {
      secret.fill(0);
      this.configuring = false;
    }
  }

  isConfigured(): boolean {
    return !this.configuring && this.config !== undefined && this.journal !== undefined &&
      this.requestKey !== undefined && this.responseKey !== undefined && this.tlsOptions !== undefined;
  }

  isBusy(): boolean { return this.configuring || this.preparing > 0 || this.pending.size > 0; }
  sameIdentity(other: RelayTransport): boolean { return this.identity.length>0 && this.identity===other.identity; }
  channel(): string { return this.config?.channel || ''; }

  dispose(): void {
    this.close(); this.requestKey?.clearMem(); this.responseKey?.clearMem();
    this.requestKey = undefined; this.responseKey = undefined;
    this.config = undefined; this.journal = undefined; this.tlsOptions = undefined;
    this.identity = '';
  }

  private validatePrivateFile(root: string, path: string): void {
    if (!root.startsWith('/') || root.endsWith('/') || root.includes('..') ||
      !path.startsWith(root + '/') || path.includes('/../') || path.includes('/./') ||
      path.includes('\\') || /[\x00-\x1f\x7f]/.test(path) || !fs.accessSync(path) || !fs.statSync(path).isFile()) {
      throw new RelayError(401, '请先把备用通道证书导入琴房的私有储存。');
    }
    let prefix = root;
    path.substring(root.length + 1).split('/').forEach((part: string) => {
      prefix += '/' + part;
      if (fs.lstatSync(prefix).isSymbolicLink()) throw new RelayError(401, '证书必须保存在琴房私有储存的真实文件中。');
    });
  }

  async request(path: string, method: string, headers: Record<string, string>,
    body?: string | ArrayBuffer): Promise<RelayResponse> {
    this.reserve();
    let prepared: PreparedRequest;
    try {
      const data = typeof body === 'string' ? this.bytes(body) : new Uint8Array(body ?? new ArrayBuffer(0));
      const normalized: Record<string, string> = {};
      Object.keys(headers).forEach((key: string) => {
        if (normalized[key.toLowerCase()] !== undefined) throw new RelayError(400, '这一页的配对信息有重复，请重新整理后送来。');
        normalized[key.toLowerCase()] = headers[key];
      });
      if (body !== undefined && normalized['content-type'] === undefined) {
        normalized['content-type'] = typeof body === 'string' ? 'application/json' : 'application/octet-stream';
      }
      const metadata: WireRequest = { headers: normalized, method: method, path: path };
      this.validateRequest(metadata, data.length);
      const rawMeta = this.bytes(this.requestJson(metadata));
      if (rawMeta.length > MAX_META) throw new RelayError(413, '这一段内容太长，请拆开后再送来。');
      const plain = new Uint8Array(4 + rawMeta.length + data.length);
      new DataView(plain.buffer).setUint32(0, rawMeta.length, false);
      plain.set(rawMeta, 4);
      plain.set(data, 4 + rawMeta.length);
      const random = await cryptoFramework.createRandom().generateRandom(16);
      const id = this.hex(random.data);
      const digest = this.hex(await this.sha(plain));
      const frame = await this.seal(id, plain);
      // No network side effect can occur until the durable journal confirms this write.
      await this.journal!.saveRequest(this.config!.channel, id, frame.buffer as ArrayBuffer, method);
      prepared = { id: id, method: method, digest: digest, frame: frame };
      return await this.exchange(prepared);
    } catch (error) {
      if (error instanceof RelayError) throw error;
      throw new RelayError(0, '备用通道的加密或本地保存暂时未完成，内容尚未送出。');
    } finally { this.preparing--; }
  }

  async retry(requestId: string): Promise<RelayResponse> {
    this.reserve();
    let prepared: PreparedRequest;
    try {
      if (!/^[0-9a-f]{32}$/.test(requestId)) throw new RelayError(400, '这一页的传送编号没有对上。');
      const saved = await this.journal!.readRequest(this.config!.channel, requestId);
      const opened = await this.openFrame(new Uint8Array(saved), 'request', true);
      if (opened.header.id !== requestId) throw new RelayError(409, '保存的传送记录没有对上。', requestId);
      const meta = JSON.parse(opened.metadata) as WireRequest;
      this.validateRequest(meta, opened.body.length);
      if (this.requestJson(meta) !== opened.metadata) throw new RelayError(409, '保存的传送记录没有对上。', requestId);
      await this.journal!.saveRequest(this.config!.channel,requestId,saved,meta.method);
      prepared = { id: requestId, method: meta.method, digest: this.hex(await this.sha(opened.plain)),
        frame: await this.seal(requestId, opened.plain) };
      return await this.exchange(prepared);
    } catch (error) {
      if (error instanceof RelayError) throw error;
      throw new RelayError(0, '这份加密记录暂时读不到，请先核对已导入的钥匙。', requestId);
    } finally { this.preparing--; }
  }

  private reserve(): void {
    if (!this.isConfigured()) throw new RelayError(401, '备用通道还没有导入完整的证书与钥匙。');
    if (this.preparing >= MAX_INFLIGHT) throw new RelayError(429, '这一段传送正忙，稍等片刻再送来。');
    this.preparing++;
  }

  private validateRequest(meta: WireRequest, size: number): void {
    if (meta === null || typeof meta !== 'object' || typeof meta.path !== 'string' ||
      typeof meta.method !== 'string' || meta.headers === null || typeof meta.headers !== 'object' ||
      !['GET', 'POST', 'PUT', 'PATCH', 'DELETE'].includes(meta.method) || !meta.path.startsWith('/api/') ||
      meta.path.length > 4096 || /[\x00-\x20\x7f\\#]/.test(meta.path) || meta.path.includes('//') ||
      meta.path.split('?')[0].includes('%') || meta.path.split('?')[0].includes('..') ||
      meta.path.split('?')[0] === '/api/local-pair' || /\/api\/runs\/[^/]+\/(deliver|progress)/.test(meta.path)) {
      throw new RelayError(403, '这条小路不在备用通道的通行范围里。');
    }
    if (size > MAX_BODY || (meta.method !== 'PUT' && size > 2097152) ||
      (['GET', 'DELETE'].includes(meta.method) && size > 0)) {
      throw new RelayError(413, '这一段内容太长，请分段送来。');
    }
    const names = Object.keys(meta.headers);
    const allowed = ['authorization', 'x-haji-device', 'content-type', 'range', 'if-range'];
    if (names.length > allowed.length || names.some((key: string) => !allowed.includes(key) ||
      typeof meta.headers[key] !== 'string' || meta.headers[key].length > 4096 || /[^\x20-\x7e]/.test(meta.headers[key])) ||
      !meta.headers['authorization']?.startsWith('Bearer ') || !meta.headers['x-haji-device']) {
      throw new RelayError(401, '设备的配对钥匙还没有对上。');
    }
    const download = /^\/api\/artifacts\/[A-Za-z0-9_-]{1,80}\/content(?:\?|$)/.test(meta.path);
    if (download) {
      const range = /^bytes=(0|[1-9][0-9]{0,15})-(0|[1-9][0-9]{0,15})$/.exec(meta.headers['range'] ?? '');
      if (range === null || !Number.isSafeInteger(Number(range[1])) || !Number.isSafeInteger(Number(range[2])) ||
        Number(range[2]) < Number(range[1]) || Number(range[2]) - Number(range[1]) + 1 > MAX_BODY) {
        throw new RelayError(400, '请为文件指定不超过 4 MiB 的一段范围。');
      }
    } else if (meta.headers['range'] !== undefined || meta.headers['if-range'] !== undefined) {
      throw new RelayError(400, '分段读取只用于文件原件。');
    }
  }

  private async exchange(prepared: PreparedRequest): Promise<RelayResponse> {
    if (this.pending.has(prepared.id)) throw new RelayError(409, '这一页仍在传送，请等它落笔。', prepared.id);
    if (!this.isConfigured()) throw new RelayError(401, '备用通道的钥匙暂时读不到。');
    const connection = http.createHttp();
    const options: http.HttpRequestOptions = {
      method: http.RequestMethod.POST, header: this.tlsOptions!.header, body: prepared.frame.buffer as ArrayBuffer,
      expectDataType: http.HttpDataType.ARRAY_BUFFER, usingCache: false, usingProxy: false,
      connectTimeout: 10000, readTimeout: 50000, maxLimit: MAX_FRAME, maxRedirects: 0, remoteValidation: 'system'
    };
    if (!this.config!.development) {
      options.caPath = this.tlsOptions!.caPath;
      options.clientCert = this.tlsOptions!.clientCert;
      options.certificatePinning = this.tlsOptions!.certificatePinning;
      options.tlsOptions = this.tlsOptions!.tlsOptions;
    }
    let timer = 0;
    let cancelled = false;
    const deadline = new Promise<http.HttpResponse>((resolve: (value: http.HttpResponse) => void,
      reject: (error: RelayError) => void) => {
      const cancel = (): void => {
        cancelled = true;
        this.destroy(connection);
        reject(new RelayError(0, '这一页还没有回音，请保留原编号稍后续接。', prepared.id, prepared.method !== 'GET'));
      };
      this.pending.set(prepared.id, { cancel: cancel });
      timer = setTimeout(cancel, 55000);
    });
    try {
      const response = await Promise.race([deadline,
        connection.request(this.config!.origin + '/v1/channels/' + this.config!.channel + '/request', options)]);
      // Outer HTTP status only describes transport. It is never the gateway/API outcome.
      if (response.responseCode !== 200 || !(response.result instanceof ArrayBuffer)) {
        throw new RelayError(0, '备用通道暂时没有送回签名完整的回信。', prepared.id, prepared.method !== 'GET');
      }
      const frame = new Uint8Array(response.result);
      const opened = await this.openFrame(frame, 'response', false);
      const meta = JSON.parse(opened.metadata) as WireResponse;
      if (opened.header.id !== prepared.id || meta === null || typeof meta !== 'object' ||
        !Number.isInteger(meta.status) || meta.status < 100 || meta.status > 599 ||
        typeof meta.request_digest !== 'string' || meta.request_digest !== prepared.digest ||
        typeof meta.outcome_uncertain !== 'boolean' || meta.headers === null || typeof meta.headers !== 'object' ||
        Object.keys(meta.headers).some((key: string) => typeof meta.headers[key] !== 'string' || meta.headers[key].length > 4096) ||
        this.responseJson(meta) !== opened.metadata) {
        throw new RelayError(0, '这一页的签名没有对上，已停止接收。', prepared.id, prepared.method !== 'GET');
      }
      await this.journal!.saveResponse(this.config!.channel, prepared.id, frame.buffer as ArrayBuffer,
        !meta.outcome_uncertain && ![401,403,503].includes(meta.status));
      if (cancelled) throw new RelayError(0, '这一页已暂停接收，原编号仍可续接。', prepared.id, prepared.method !== 'GET');
      const contentType = meta.headers['content-type'] ?? '';
      const text = contentType.includes('json') || contentType.startsWith('text/') ? this.text(opened.body) : '';
      const result: RelayResponse = { status: meta.status, body: text, data: opened.body.buffer as ArrayBuffer, headers: meta.headers,
        requestId: prepared.id, outcomeUncertain: meta.outcome_uncertain };
      return result;
    } catch (error) {
      if (error instanceof RelayError) throw error;
      throw new RelayError(0, '……备用通道暂时没有接通，原编号仍在本子上。', prepared.id, prepared.method !== 'GET');
    } finally {
      clearTimeout(timer);
      this.pending.delete(prepared.id);
      this.destroy(connection);
    }
  }

  close(): void {
    this.pending.forEach((entry: ActiveRequest) => entry.cancel());
  }

  private destroy(connection: http.HttpRequest): void {
    try { connection.destroy(); } catch (_) { /* Cancellation may already have disposed this request. */ }
  }

  private async derive(secret: Uint8Array, salt: Uint8Array, direction: string): Promise<cryptoFramework.SymKey> {
    const specification: cryptoFramework.HKDFSpec = { algName: 'HKDF', key: secret, salt: salt,
      info: this.bytes('HajiSaki/relay/v1/' + direction), keySize: 32 };
    const key = await cryptoFramework.createKdf('HKDF|SHA256|EXTRACT_AND_EXPAND').generateSecret(specification);
    try { return await cryptoFramework.createSymKeyGenerator('AES256').convertKey(key); }
    finally { key.data.fill(0); }
  }

  private async seal(id: string, plain: Uint8Array): Promise<Uint8Array> {
    const nonce = (await cryptoFramework.createRandom().generateRandom(12)).data;
    const issued = Date.now();
    const header: WireHeader = { exp: issued + WINDOW_MS, id: id, iat: issued, kind: 'request',
      nonce: this.base64.encodeToStringSync(nonce), v: 1 };
    const raw = this.bytes(this.headerJson(header));
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec', iv: { data: nonce },
      aad: { data: this.concat(this.bytes(this.config!.channel + '\u0000'), raw) }, authTag: { data: new Uint8Array(16) } };
    await cipher.init(cryptoFramework.CryptoMode.ENCRYPT_MODE, this.requestKey!, params);
    // API26 doFinal appends the 16-byte GCM tag, exactly as Python AESGCM.encrypt does.
    const encrypted = (await cipher.doFinal({ data: plain })).data;
    const frame = new Uint8Array(6 + raw.length + encrypted.length);
    frame.set([72, 83, 82, 49], 0);
    new DataView(frame.buffer).setUint16(4, raw.length, false);
    frame.set(raw, 6);
    frame.set(encrypted, 6 + raw.length);
    if (frame.length > MAX_FRAME) throw new RelayError(413, '这一段内容太长，请分段送来。');
    return frame;
  }

  private inspect(frame: Uint8Array, direction: string, allowExpired: boolean): WireHeader {
    if (frame.length < 24 || frame.length > MAX_FRAME || frame[0] !== 72 || frame[1] !== 83 || frame[2] !== 82 || frame[3] !== 49) {
      throw new RelayError(0, '这一页的传送封口没有对上。');
    }
    const size = new DataView(frame.buffer, frame.byteOffset, frame.byteLength).getUint16(4, false);
    if (size < 1 || size > MAX_HEADER || frame.length < 6 + size + 16) throw new RelayError(0, '这一页的封口不完整。');
    const raw = this.text(frame.slice(6, 6 + size));
    const header = JSON.parse(raw) as WireHeader;
    if (header === null || typeof header !== 'object' || header.v !== 1 || header.kind !== direction ||
      typeof header.id !== 'string' || !/^[0-9a-f]{32}$/.test(header.id) || typeof header.nonce !== 'string' ||
      !/^[A-Za-z0-9+/]{16}$/.test(header.nonce) || !Number.isSafeInteger(header.iat) || !Number.isSafeInteger(header.exp) ||
      header.exp <= header.iat || header.exp - header.iat > WINDOW_MS || header.iat > Date.now() + SKEW_MS ||
      (!allowExpired && header.exp < Date.now()) || this.headerJson(header) !== raw) {
      throw new RelayError(0, '这一页的编号或时间没有对上，请按原编号续接。');
    }
    return header;
  }

  private async openFrame(frame: Uint8Array, direction: string, allowExpired: boolean): Promise<OpenedFrame> {
    const header = this.inspect(frame, direction, allowExpired);
    const size = new DataView(frame.buffer, frame.byteOffset, frame.byteLength).getUint16(4, false);
    const raw = frame.slice(6, 6 + size);
    const cipher = cryptoFramework.createCipher('AES256|GCM|NoPadding');
    const params: cryptoFramework.GcmParamsSpec = { algName: 'GcmParamsSpec',
      iv: { data: this.base64.decodeSync(header.nonce) },
      aad: { data: this.concat(this.bytes(this.config!.channel + '\u0000'), raw) },
      authTag: { data: frame.slice(frame.length - 16) } };
    await cipher.init(cryptoFramework.CryptoMode.DECRYPT_MODE, direction === 'request' ? this.requestKey! : this.responseKey!, params);
    const plain = (await cipher.doFinal({ data: frame.slice(6 + size, frame.length - 16) })).data;
    if (plain.length < 4) throw new RelayError(0, '这一页的内容不完整。');
    const metaSize = new DataView(plain.buffer, plain.byteOffset, plain.byteLength).getUint32(0, false);
    if (metaSize < 1 || metaSize > MAX_META || plain.length < 4 + metaSize || plain.length - 4 - metaSize > MAX_BODY) {
      throw new RelayError(0, '这一页的内容长度没有对上。');
    }
    return { header: header, plain: plain, metadata: this.text(plain.slice(4, 4 + metaSize)), body: plain.slice(4 + metaSize) };
  }

  private headerJson(value: WireHeader): string {
    const ordered: WireHeader = { exp: value.exp, id: value.id, iat: value.iat, kind: value.kind, nonce: value.nonce, v: value.v };
    return this.ascii(JSON.stringify(ordered));
  }
  private requestJson(value: WireRequest): string {
    return '{"headers":' + this.headersJson(value.headers) + ',"method":' + this.ascii(JSON.stringify(value.method)) +
      ',"path":' + this.ascii(JSON.stringify(value.path)) + '}';
  }
  private responseJson(value: WireResponse): string {
    return '{"headers":' + this.headersJson(value.headers) + ',"outcome_uncertain":' + JSON.stringify(value.outcome_uncertain) +
      ',"request_digest":' + JSON.stringify(value.request_digest) + ',"status":' + JSON.stringify(value.status) + '}';
  }
  private headersJson(headers: Record<string, string>): string {
    return '{' + Object.keys(headers).sort().map((key: string): string =>
      this.ascii(JSON.stringify(key)) + ':' + this.ascii(JSON.stringify(headers[key]))).join(',') + '}';
  }
  private ascii(value: string): string {
    return value.replace(/[^\x00-\x7f]/g, (character: string): string => '\\u' + character.charCodeAt(0).toString(16).padStart(4, '0'));
  }
  private bytes(value: string): Uint8Array { return new util.TextEncoder().encodeInto(value); }
  private text(value: Uint8Array): string {
    return util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(value, { stream: false });
  }
  private concat(first: Uint8Array, second: Uint8Array): Uint8Array {
    const result = new Uint8Array(first.length + second.length); result.set(first); result.set(second, first.length); return result;
  }
  private hex(value: Uint8Array): string {
    let result = ''; value.forEach((byte: number) => { result += byte.toString(16).padStart(2, '0'); }); return result;
  }
  private async sha(value: Uint8Array): Promise<Uint8Array> {
    const digest = cryptoFramework.createMd('SHA256'); await digest.update({ data: value }); return (await digest.digest()).data;
  }
}
