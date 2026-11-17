import { common } from '@kit.AbilityKit';
import { fileIo as fs, picker } from '@kit.CoreFileKit';
import { asset } from '@kit.AssetStoreKit';
import { util } from '@kit.ArkTS';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { RelayConfig, RelayCredentials } from '../services/RelayTransport';
import { previewMode } from '../model/BuildMode';

interface ProfileKeys {
  channelToken: string;
  masterKeyBase64: string;
  serverPublicKeySha256: string;
  keyPassword: string;
}
interface ProfileFiles { caPem: string; certificatePem: string; encryptedPrivateKeyPem: string }
export interface RelayProfile {
  kind: string;
  version: number;
  device: string;
  authentication: string;
  relay: RelayConfig;
  credentials: ProfileKeys;
  files: ProfileFiles;
}
export interface StoredRelayProfile {
  version: number;
  relay: RelayConfig;
  credentials: ProfileKeys;
  folder: string;
  gatewayToken: string;
  gatewayDevice: string;
}

export class RelayImportError extends Error {}
const MAX_PROFILE_BYTES: number = 32768;

/** Keys/passwords are Asset SECRETs; only encrypted PKCS8 and public certs use private files. */
export class RelayVault {
  private context: common.UIAbilityContext;
  private alias: Uint8Array = new util.TextEncoder().encodeInto('hajisaki.relay.profile.v1');
  private codec: util.Base64Helper = new util.Base64Helper();
  constructor(context: common.UIAbilityContext) { this.context = context; }

  parse(source: string): RelayProfile {
    let phase='size';
    try {
      if (!source || source.length > MAX_PROFILE_BYTES || this.bytes(source).length > MAX_PROFILE_BYTES) throw new Error('size');
      phase='json';
      const profile = JSON.parse(source) as RelayProfile;
      phase='shape';
      if (!profile || profile.kind !== 'hajisaki-relay' || profile.version !== 1 ||
        Object.keys(profile).sort().join(',') !== 'authentication,credentials,device,files,kind,relay,version' ||
        typeof profile.device!=='string' || !/^[A-Za-z0-9_-]{1,128}$/.test(profile.device) ||
        !this.base64Key(profile.authentication) || !profile.files ||
        Object.keys(profile.files).sort().join(',') !== 'caPem,certificatePem,encryptedPrivateKeyPem') throw new Error('profile');
      phase='keys';
      if(!this.validKeys(profile.relay,profile.credentials)) throw new Error('keys');
      phase='pem';
      if(!this.pem(profile.files.caPem, 'CERTIFICATE', 8192) ||
        !this.pem(profile.files.certificatePem, 'CERTIFICATE', 8192) ||
        !this.pem(profile.files.encryptedPrivateKeyPem, 'ENCRYPTED PRIVATE KEY', 16384)) throw new Error('profile');
      return profile;
    } catch (_) {
      if(previewMode()) console.info(`HajiSaki preview relay-profile phase=${phase}, characters=${source.length}`);
      throw new RelayImportError('这份通道资料没有对上，请选择主机导出的通道文件。');
    }
  }

  async pick(): Promise<string | undefined> {
    try {
      const options = new picker.DocumentSelectOptions(); options.maxSelectNumber = 1;
      options.fileSuffixFilters = ['通道资料|.json'];
      const uris = await new picker.DocumentViewPicker(this.context).select(options);
      if (uris.length === 0) return undefined;
      const file = await fs.open(uris[0], fs.OpenMode.READ_ONLY);
      let bytes: Uint8Array = new Uint8Array();
      try {
        const stat = await fs.stat(file.fd);
        if (!stat.isFile() || !Number.isSafeInteger(stat.size) || stat.size < 1 || stat.size > MAX_PROFILE_BYTES) throw new Error('size');
        bytes = new Uint8Array(stat.size);
        let offset = 0;
        while (offset < stat.size) {
          const part = new ArrayBuffer(stat.size - offset);
          const read = await fs.read(file.fd, part, { offset: offset, length: part.byteLength });
          if (!Number.isSafeInteger(read) || read <= 0 || read > part.byteLength) throw new Error('read');
          bytes.set(new Uint8Array(part, 0, read), offset); offset += read;
        }
        return util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true }).decodeToString(bytes, { stream: false });
      } finally { bytes.fill(0); await fs.close(file); }
    } catch (_) { throw new RelayImportError('这份通道文件暂时读不到，请重新选择，或填入主机导出的通道资料。'); }
  }

  async stage(profile: RelayProfile, token: string, device: string): Promise<StoredRelayProfile> {
    this.requireStorage();
    await this.authenticate(profile,token,device);
    const random = cryptoFramework.createRandom().generateRandomSync(12).data;
    let suffix = '';
    random.forEach((byte: number) => { suffix += byte.toString(16).padStart(2, '0'); });
    const folder = 'relay-' + suffix;
    const root = this.context.filesDir + '/' + folder;
    try {
      await fs.mkdir(root);
      await this.write(root + '/ca.pem', profile.files.caPem);
      await this.write(root + '/client.pem', profile.files.certificatePem);
      await this.write(root + '/client-key.pem', profile.files.encryptedPrivateKeyPem);
      return { version: 1, relay: profile.relay, credentials: profile.credentials, folder: folder,
        gatewayToken:token,gatewayDevice:device };
    } catch (_) { throw new RelayImportError('备用通道资料暂时没能收进手机，请保留主机上的通道文件。'); }
  }

  credentialsFor(stored: StoredRelayProfile): RelayCredentials {
    if (!this.validStored(stored)) throw new RelayImportError('保存的备用钥匙没有对上，请重新导入通道文件。');
    const root = this.context.filesDir + '/' + stored.folder;
    return { channelToken: stored.credentials.channelToken, masterKeyBase64: stored.credentials.masterKeyBase64,
      serverPublicKeySha256: stored.credentials.serverPublicKeySha256, keyPassword: stored.credentials.keyPassword,
      privateRoot: this.context.filesDir, caPath: root + '/ca.pem', certPath: root + '/client.pem', keyPath: root + '/client-key.pem' };
  }

  async save(stored: StoredRelayProfile): Promise<void> {
    this.requireStorage();
    if (!this.validStored(stored)) throw new RelayImportError('备用钥匙的信息还不完整，请重新导入通道文件。');
    const secret = this.bytes(JSON.stringify(stored));
    try {
      if (secret.length > 1024) throw new RelayImportError('这份通道资料超过安全钥匙匣的容量，请在主机上重新导出。');
      const attributes: asset.AssetMap = new Map();
      attributes.set(asset.Tag.ALIAS, this.alias); attributes.set(asset.Tag.SECRET, secret);
      attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
      attributes.set(asset.Tag.REQUIRE_PASSWORD_SET, true); attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
      attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
      attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.THROW_ERROR);
      try { await asset.add(attributes); }
      catch (error) {
        if ((error as BusinessError).code !== asset.ErrorCode.DUPLICATED) throw this.storageError();
        const query: asset.AssetMap = new Map(); query.set(asset.Tag.ALIAS, this.alias);
        const changes: asset.AssetMap = new Map(); changes.set(asset.Tag.SECRET, secret);
        try { await asset.update(query, changes); } catch (_) { throw this.storageError(); }
      }
    } finally { secret.fill(0); }
  }

  async load(): Promise<StoredRelayProfile | undefined> {
    if (previewMode()) return undefined;
    this.requireStorage();
    const query: asset.AssetMap = new Map(); query.set(asset.Tag.ALIAS, this.alias);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let records: asset.AssetMap[];
    try { records = await asset.query(query); }
    catch (error) {
      if ((error as BusinessError).code === asset.ErrorCode.NOT_FOUND) return undefined;
      throw this.storageError();
    }
    if (records.length === 0) return undefined;
    if (records.length !== 1) throw this.storageError();
    const secret = records[0].get(asset.Tag.SECRET);
    if (!(secret instanceof Uint8Array)) throw this.storageError();
    try {
      const stored = JSON.parse(util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true })
        .decodeToString(secret, { stream: false })) as StoredRelayProfile;
      if (!this.validStored(stored)) throw this.storageError();
      return stored;
    } catch (_) { throw this.storageError(); }
    finally { secret.fill(0); }
  }

  private requireStorage(): void {
    // A Previewer mock must never be accepted as secure device persistence.
    if (previewMode() || !canIUse('SystemCapability.Security.Asset')) {
      throw new RelayImportError('这台设备暂时不能安全收好备用钥匙，请保留主机上的通道文件。');
    }
  }
  private storageError(): RelayImportError { return new RelayImportError('手机的备用钥匙匣暂时打不开，请解锁手机后再试。'); }
  private validStored(value: StoredRelayProfile): boolean {
    return value !== null && typeof value === 'object' && value.version === 1 &&
      Object.keys(value).sort().join(',') === 'credentials,folder,gatewayDevice,gatewayToken,relay,version' &&
      typeof value.gatewayToken==='string' && /^[\x21-\x7e]{32,128}$/.test(value.gatewayToken) &&
      typeof value.gatewayDevice==='string' && /^[A-Za-z0-9_-]{1,128}$/.test(value.gatewayDevice) &&
      typeof value.folder === 'string' && /^relay-[a-f0-9]{24}$/.test(value.folder) && this.validKeys(value.relay, value.credentials);
  }
  private validKeys(config: RelayConfig, keys: ProfileKeys): boolean {
    if (!config || !keys || Object.keys(config).sort().join(',') !== 'channel,development,origin' ||
      Object.keys(keys).sort().join(',') !== 'channelToken,keyPassword,masterKeyBase64,serverPublicKeySha256' ||
      config.development !== false || typeof config.origin !== 'string' || config.origin.length > 320 ||
      !/^https:\/\/(?:[a-zA-Z0-9.-]+|\[[a-fA-F0-9:]+\]):[0-9]{1,5}$/.test(config.origin) ||
      Number(config.origin.substring(config.origin.lastIndexOf(':') + 1)) < 1 ||
      Number(config.origin.substring(config.origin.lastIndexOf(':') + 1)) > 65535 ||
      typeof config.channel !== 'string' || !/^[A-Za-z0-9_-]{20,64}$/.test(config.channel) ||
      typeof keys.channelToken !== 'string' || !/^[A-Za-z0-9_-]{40,128}$/.test(keys.channelToken) ||
      typeof keys.keyPassword !== 'string' || !/^[A-Za-z0-9_-]{32,128}$/.test(keys.keyPassword) ||
      !this.base64Key(keys.masterKeyBase64) || !this.base64Key(keys.serverPublicKeySha256)) return false;
    return true;
  }
  private base64Key(value: string): boolean {
    // Exactly 32 bytes in canonical padded Base64; the final two pad bits are zero.
    // Structural parsing does not depend on a Previewer system-codec mock.
    return typeof value==='string' && /^[A-Za-z0-9+/]{42}[AEIMQUYcgkosw048]=$/.test(value);
  }
  private async authenticate(profile: RelayProfile, token: string, device: string): Promise<void> {
    if(profile.device!==device) throw new RelayImportError('这份通道资料属于另一台设备，请在主机上为本机重新导出。');
    if(!canIUse('SystemCapability.Security.CryptoFramework.Mac')) throw new RelayImportError('手机暂时不能核对通道封签，请保留主机上的通道文件。');
    const material=this.bytes(token);
    let key: cryptoFramework.SymKey | undefined = undefined;
    let expected=new Uint8Array();
    let actual=new Uint8Array();
    try {
      key=await cryptoFramework.createSymKeyGenerator('HMAC').convertKey({data:material});
      const mac=cryptoFramework.createMac('SHA256'); await mac.init(key);
      await mac.update({data:this.bytes('HajiSaki/native-relay/v1\u0000')});
      await mac.update({data:this.bytes(this.canonical(profile))});
      actual=(await mac.doFinal()).data; expected=this.codec.decodeSync(profile.authentication);
      if(actual.length!==32 || expected.length!==32) throw new Error('mac');
      let difference=0;
      for(let index=0;index<32;index++) difference|=actual[index]^expected[index];
      if(difference!==0) throw new Error('mac');
    } catch(_) { throw new RelayImportError('通道封签与当前设备钥匙没有对上，请在主机上重新导出。'); }
    finally { material.fill(0); expected.fill(0); actual.fill(0); key?.clearMem(); }
  }
  private canonical(profile: RelayProfile): string {
    // Fixed lexical key order matches Python sort_keys; all accepted fields are ASCII.
    const keys=profile.credentials; const files=profile.files; const relay=profile.relay;
    return '{"credentials":{"channelToken":'+JSON.stringify(keys.channelToken)+',"keyPassword":'+JSON.stringify(keys.keyPassword)+
      ',"masterKeyBase64":'+JSON.stringify(keys.masterKeyBase64)+',"serverPublicKeySha256":'+JSON.stringify(keys.serverPublicKeySha256)+
      '},"device":'+JSON.stringify(profile.device)+',"files":{"caPem":'+JSON.stringify(files.caPem)+
      ',"certificatePem":'+JSON.stringify(files.certificatePem)+',"encryptedPrivateKeyPem":'+JSON.stringify(files.encryptedPrivateKeyPem)+
      '},"kind":'+JSON.stringify(profile.kind)+',"relay":{"channel":'+JSON.stringify(relay.channel)+
      ',"development":false,"origin":'+JSON.stringify(relay.origin)+'},"version":1}';
  }
  private pem(value: string, label: string, maximum: number): boolean {
    return typeof value === 'string' && value.length <= maximum &&
      new RegExp('^-----BEGIN ' + label + '-----\\r?\\n[A-Za-z0-9+/=\\r\\n]+-----END ' + label + '-----\\r?\\n?$').test(value);
  }
  private bytes(value: string): Uint8Array { return new util.TextEncoder().encodeInto(value); }
  private async write(path: string, value: string): Promise<void> {
    const bytes = this.bytes(value);
    const file = await fs.open(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
    try {
      let offset = 0;
      while (offset < bytes.length) {
        const part = bytes.slice(offset);
        const count = await fs.write(file.fd, part.buffer as ArrayBuffer, { offset: offset, length: part.length });
        if (!Number.isSafeInteger(count) || count <= 0 || count > part.length) throw new Error('write');
        offset += count;
      }
      await fs.fsync(file.fd);
    } finally { bytes.fill(0); await fs.close(file); }
  }
}
