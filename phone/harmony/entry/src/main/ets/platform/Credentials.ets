import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { asset } from '@kit.AssetStoreKit';
import { BusinessError } from '@kit.BasicServicesKit';

export interface StoredCredential {
  token: string;
  device: string;
  primary: string;
  fallback: string;
}

/** Pairing secrets remain in the system Asset Store, never in application files. */
export class Credentials {
  private alias: Uint8Array;

  constructor(_context: common.UIAbilityContext) {
    // Asset Store identifies the calling application itself. Neither its static
    // alias nor any unencrypted DATA_LABEL field contains user or host details.
    this.alias = new util.TextEncoder().encodeInto('hajisaki.gateway.credential.v1');
  }

  async save(token: string, device: string, primary: string, fallback: string = ''): Promise<void> {
    this.requireCapability();
    const credential: StoredCredential = {
      token: token.trim(),
      device: device.trim(),
      primary: primary.trim().replace(/\/$/, ''),
      fallback: fallback.trim().replace(/\/$/, '')
    };
    if (!this.validCredential(credential)) {
      throw new Error('琴房钥匙的信息还不完整，请检查令牌、设备名称与主机地址。');
    }
    const secret = new util.TextEncoder().encodeInto(JSON.stringify(credential));
    if (secret.byteLength > 1024) {
      secret.fill(0);
      throw new Error('这份配对信息超过安全钥匙的容量，请检查是否粘贴了多余内容。');
    }
    const attributes: asset.AssetMap = new Map();
    attributes.set(asset.Tag.ALIAS, this.alias);
    attributes.set(asset.Tag.SECRET, secret);
    attributes.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_FIRST_UNLOCKED);
    attributes.set(asset.Tag.REQUIRE_PASSWORD_SET, true);
    attributes.set(asset.Tag.AUTH_TYPE, asset.AuthType.NONE);
    attributes.set(asset.Tag.SYNC_TYPE, asset.SyncType.NEVER);
    attributes.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.THROW_ERROR);
    try {
      try {
        await asset.add(attributes);
      } catch (error) {
        const failure = error as BusinessError;
        if (failure.code !== asset.ErrorCode.DUPLICATED) {
          throw this.storageError(failure.code, true);
        }
        const query: asset.AssetMap = new Map();
        query.set(asset.Tag.ALIAS, this.alias);
        const changes: asset.AssetMap = new Map();
        changes.set(asset.Tag.SECRET, secret);
        try {
          // Replacement updates the encrypted secret in place. No remove/delete
          // call is used, and the existing access-control attributes stay intact.
          await asset.update(query, changes);
        } catch (updateError) {
          throw this.storageError((updateError as BusinessError).code, true);
        }
      }
    } finally {
      secret.fill(0);
    }
  }

  async load(): Promise<StoredCredential | undefined> {
    this.requireCapability();
    const query: asset.AssetMap = new Map();
    query.set(asset.Tag.ALIAS, this.alias);
    query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    let result: asset.AssetMap[];
    try {
      result = await asset.query(query);
    } catch (error) {
      const failure = error as BusinessError;
      if (failure.code === asset.ErrorCode.NOT_FOUND) {
        return undefined;
      }
      throw this.storageError(failure.code, false);
    }
    if (result.length === 0) {
      return undefined;
    }
    if (result.length !== 1) {
      throw new Error('保存的琴房钥匙没有对上，请重新连接一次。');
    }
    const secret = result[0].get(asset.Tag.SECRET);
    if (!(secret instanceof Uint8Array)) {
      throw new Error('保存的琴房钥匙暂时读不到，请重新连接一次。');
    }
    try {
      const decoder = util.TextDecoder.create('utf-8', { fatal: true, ignoreBOM: true });
      const credential = JSON.parse(decoder.decodeToString(secret, { stream: false })) as StoredCredential;
      // Older encrypted records had no fallback. Do not borrow an endpoint from
      // ordinary configuration, which may belong to a different pairing.
      if (credential !== null && typeof credential === 'object' && credential.fallback === undefined) {
        credential.fallback = '';
      }
      if (!this.validCredential(credential)) {
        throw new Error('Stored credential is invalid');
      }
      return credential;
    } catch (_) {
      throw new Error('保存的琴房钥匙内容不完整，请重新连接一次。');
    } finally {
      secret.fill(0);
    }
  }

  private requireCapability(): void {
    if (!canIUse('SystemCapability.Security.Asset')) {
      throw new Error('这台设备暂不支持安全保存琴房钥匙；本次仍可手动连接。');
    }
  }

  private validCredential(value: StoredCredential): boolean {
    return value !== null && typeof value === 'object' &&
      typeof value.token === 'string' && value.token.trim().length > 0 &&
      typeof value.device === 'string' && value.device.trim().length > 0 &&
      typeof value.primary === 'string' && value.primary.trim().length > 0 &&
      typeof value.fallback === 'string';
  }

  private storageError(code: number, saving: boolean): Error {
    if (code === asset.ErrorCode.STATUS_MISMATCH) {
      return new Error('请先设置并解锁手机锁屏密码，再来取用琴房钥匙。');
    }
    if (code === asset.ErrorCode.SERVICE_UNAVAILABLE || code === asset.ErrorCode.UNSUPPORTED) {
      return new Error('手机的安全钥匙匣暂时打不开；本次仍可手动连接。');
    }
    if (code === asset.ErrorCode.ACCESS_DENIED || code === asset.ErrorCode.PERMISSION_DENIED) {
      return new Error('手机尚未允许取用这把安全钥匙，请解锁后再试。');
    }
    return new Error(saving ? '琴房钥匙还没有安全存好，本次连接仍可继续。' :
      '保存的琴房钥匙暂时取不出，请重新连接一次。');
  }
}
