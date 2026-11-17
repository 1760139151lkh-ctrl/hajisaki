import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { userAuth } from '@kit.UserAuthenticationKit';

/** A local biometric gate. A boolean is not a remote authorization proof. */
export async function authenticate(reason: string): Promise<boolean> {
  let challenge: Uint8Array;
  try {
    challenge = (await cryptoFramework.createRandom().generateRandom(32)).data;
  } catch (_) {
    return false;
  }
  const authParam: userAuth.AuthParam = {
    challenge: challenge,
    authType: [userAuth.UserAuthType.FINGERPRINT, userAuth.UserAuthType.FACE],
    authTrustLevel: userAuth.AuthTrustLevel.ATL3
  };
  const widgetParam: userAuth.WidgetParam = {
    title: reason.slice(0, 500)
  };
  return new Promise<boolean>((resolve) => {
    let instance: userAuth.UserAuthInstance | undefined = undefined;
    let settled: boolean = false;
    let timeout: number = -1;
    const callback: userAuth.IAuthCallback = {
      onResult: (result: userAuth.UserAuthResult): void => {
        if (settled) {
          return;
        }
        settled = true;
        if (timeout >= 0) {
          clearTimeout(timeout);
        }
        try {
          instance?.off('result', callback);
        } catch (_) {
          // The completed system result remains authoritative if cleanup races.
        }
        resolve(result.result === userAuth.UserAuthResultCode.SUCCESS);
      }
    };
    try {
      instance = userAuth.getUserAuthInstance(authParam, widgetParam);
      instance.on('result', callback);
      instance.start();
      timeout = setTimeout(() => {
        if (!settled) {
          settled = true;
          try {
            instance?.cancel();
            instance?.off('result', callback);
          } catch (_) {
            // Timeout still denies access if the system has already closed its widget.
          }
          resolve(false);
        }
      }, 60000);
    } catch (_) {
      if (!settled) {
        settled = true;
        if (timeout >= 0) {
          clearTimeout(timeout);
        }
        if (instance !== undefined) {
          try {
            instance.off('result', callback);
          } catch (_) {
            // No authentication result has been accepted.
          }
        }
        resolve(false);
      }
    }
  });
}
