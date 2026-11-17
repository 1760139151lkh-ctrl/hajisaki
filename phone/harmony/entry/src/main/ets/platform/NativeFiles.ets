import { common } from '@kit.AbilityKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { http } from '@kit.NetworkKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { Artifact, UploadSession } from '../model/Types';
import { previewMode } from '../model/BuildMode';
import { Gateway } from '../services/Gateway';

interface UploadManifest {
  name: string;
  size: number;
  sha256: string;
  mime: string;
}

interface UploadOffset { offset: number }
interface SaveOperation { phase: string }

export class NativeFileError extends Error {
  phase: string;
  code: number;
  constructor(phase: string, code: number, message: string) {
    super(message); this.phase = phase; this.code = code;
  }
}

const CHUNK_BYTES: number = 1024 * 1024;
const DOWNLOAD_IDLE_TIMEOUT_MS: number = 120000;

export class NativeFiles {
  private context: common.UIAbilityContext;
  private gateway: Gateway;

  constructor(context: common.UIAbilityContext, gateway: Gateway) {
    this.context = context;
    this.gateway = gateway;
  }

  async uploadPicked(onProgress: (done: number, total: number) => void): Promise<Artifact | undefined> {
    const documentPicker = new picker.DocumentViewPicker(this.context);
    const options = new picker.DocumentSelectOptions();
    options.maxSelectNumber = 1;
    const uris = await documentPicker.select(options);
    if (uris.length === 0) {
      return undefined;
    }
    const uri = uris[0];
    const name = this.filename(uri);
    return this.uploadUri(uri, name, this.mimeFor(name), onProgress);
  }

  /** Re-selecting the same file resumes from the server's durable hash-based offset. */
  async uploadUri(uri: string, name: string, mime: string,
    onProgress: (done: number, total: number) => void): Promise<Artifact> {
    const file = await fileIo.open(uri, fileIo.OpenMode.READ_ONLY);
    try {
      const stat = await fileIo.stat(file.fd);
      if (!stat.isFile()) {
        throw new Error('请选一份文件；文件夹可以先收进压缩包。');
      }
      const size = stat.size;
      const digest = await this.hashOpenFile(file.fd, size);
      const manifest: UploadManifest = { name: name, size: size, sha256: digest, mime: mime };
      const session = await this.gateway.request<UploadSession>('/api/uploads', http.RequestMethod.POST,
        JSON.stringify(manifest));
      if (session.complete && session.artifact !== undefined) {
        onProgress(size, size);
        return session.artifact;
      }
      let offset = session.offset;
      if (!Number.isSafeInteger(offset) || offset < 0 || offset > size) {
        throw new Error('文件的续传位置没有对齐，请重新选择它。');
      }
      onProgress(offset, size);
      while (offset < size) {
        const length = Math.min(CHUNK_BYTES, size - offset);
        const buffer = new ArrayBuffer(length);
        const read = await fileIo.read(file.fd, buffer, { offset: offset, length: length });
        if (read <= 0) {
          throw new Error('这份文件在途中变了，请重新选择后再交给我。');
        }
        const chunk = read === buffer.byteLength ? buffer : buffer.slice(0, read);
        const next = await this.gateway.request<UploadOffset>(
          `/api/uploads/${encodeURIComponent(session.id)}?offset=${offset}`, http.RequestMethod.PUT, chunk);
        if (next.offset !== offset + read) {
          throw new Error('这一段尚未完整收好，重新选择同一文件即可续传。');
        }
        offset = next.offset;
        onProgress(offset, size);
      }
      return await this.gateway.request<Artifact>(
        `/api/uploads/${encodeURIComponent(session.id)}/complete`, http.RequestMethod.POST, '{}');
    } finally {
      await fileIo.close(file);
    }
  }

  /**
   * Streams to private storage, verifies bytes, then lets the user choose where to
   * export. An HTTP failure cannot be mistaken for a successfully saved document.
   * Partial and verified private files are retained; no destructive cleanup occurs.
   */
  async saveArtifact(artifact: Artifact): Promise<boolean> {
    const operation: SaveOperation = { phase: 'prepare' };
    try {
      return await this.downloadAndExport(artifact, operation);
    } catch (error) {
      const numericCode = this.errorCode(error as Error);
      // Only fixed phase names and numeric codes enter preview diagnostics.
      // Paths, picker URIs, credentials and SDK error messages stay private.
      if (previewMode()) console.info(`HajiSaki preview file-save phase=${operation.phase}, error_code=${numericCode}`);
      if (error instanceof NativeFileError) throw error;
      throw new NativeFileError(operation.phase, numericCode, this.saveFailure(operation.phase));
    }
  }

  private async downloadAndExport(artifact: Artifact, operation: SaveOperation): Promise<boolean> {
    if (!Number.isSafeInteger(artifact.size) || artifact.size < 0 || !/^[a-fA-F0-9]{64}$/.test(artifact.sha256)) {
      throw new Error('这份交付的校验信息还不完整，请刷新档案再试。');
    }
    const random = cryptoFramework.createRandom().generateRandomSync(12);
    const localPath = `${this.context.filesDir}/download-${this.toHex(random.data)}.part`;
    operation.phase = 'storage';
    const destination = await fileIo.open(localPath, fileIo.OpenMode.CREATE | fileIo.OpenMode.READ_WRITE);
    const request = http.createHttp();
    let received: number = 0;
    let failureMessage: string = '';
    let idleTimer: number = -1;
    let settled: boolean = false;
    try {
      operation.phase = 'transfer';
      if(this.gateway.isRelayActive()) {
        while(received<artifact.size) {
          const end=Math.min(received+CHUNK_BYTES,artifact.size)-1;
          const chunk=await this.gateway.readRelayChunk(`/api/artifacts/${encodeURIComponent(artifact.id)}/content`,received,end);
          let written=0;
          while(written<chunk.byteLength) {
            operation.phase = 'write';
            const remaining=chunk.slice(written);
            const count=await fileIo.write(destination.fd,remaining,{offset:received+written,length:remaining.byteLength});
            if(count<=0) throw new Error('文件暂时未能收好。');
            written+=count;
          }
          received+=written;
          operation.phase = 'transfer';
        }
      } else {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        header: this.gateway.headers(),
        usingCache: false,
        usingProxy: false,
        connectTimeout: 10000,
        // Native readTimeout=0 disables an absolute read deadline. The watchdog
        // below bounds inactivity while allowing a progressing multi-GB transfer.
        readTimeout: 0
      };
      await new Promise<void>((resolve, reject) => {
        let responseCode: number | undefined = undefined;
        let streamEnded: boolean = false;
        const fail = (message: string, code: number = 0): void => {
          if (settled) return;
          settled = true;
          failureMessage = message;
          if (idleTimer >= 0) clearTimeout(idleTimer);
          this.cancelRequest(request);
          reject(new NativeFileError(operation.phase, code, message));
        };
        const refreshIdleTimer = (): void => {
          if (idleTimer >= 0) clearTimeout(idleTimer);
          idleTimer = setTimeout(() => {
            fail('这份文件已经有一会儿没传过来了，稍后可以重新取一次。');
          }, DOWNLOAD_IDLE_TIMEOUT_MS);
        };
        const finishIfReady = (): void => {
          // The HTTP response and dataEnd may arrive in either order. Neither
          // event alone permits closing the FD or starting digest verification.
          if (settled || responseCode === undefined || !streamEnded) return;
          if (responseCode !== 200 || received !== artifact.size) {
            fail('这份文件还没有传完整，请重新取一次。');
            return;
          }
          settled = true;
          if (idleTimer >= 0) clearTimeout(idleTimer);
          resolve();
        };
        request.on('dataReceive', (chunk: ArrayBuffer): void => {
          if (settled) return;
          if (streamEnded || received + chunk.byteLength > artifact.size) {
            fail('收到的文件大小与档案不符，这份文件暂不导出。');
            return;
          }
          let writeResult: number = -1;
          try {
            let written: number = 0;
            while (written < chunk.byteLength) {
              const remaining = written === 0 ? chunk : chunk.slice(written);
              const count = fileIo.writeSync(destination.fd, remaining, { offset: received + written, length: remaining.byteLength });
              writeResult = Number.isSafeInteger(count) ? count : -2;
              if (!Number.isSafeInteger(count) || count <= 0 || count > remaining.byteLength) {
                throw new Error('File write returned an invalid byte count');
              }
              written += count;
            }
            received += written;
            if (written > 0) refreshIdleTimer();
          } catch (error) {
            operation.phase = 'write';
            if (previewMode()) {
              const failure = error as Error;
              const kind = failure instanceof TypeError ? 'type' : failure instanceof RangeError ? 'range' : 'other';
              console.info(`HajiSaki preview file-write api=${typeof fileIo.writeSync}, fd_valid=${Number.isSafeInteger(destination.fd) && destination.fd >= 0}, buffer_valid=${chunk instanceof ArrayBuffer}, bytes=${chunk.byteLength}, result=${writeResult}, error_kind=${kind}`);
            }
            fail('手机暂时没有收好这份文件，请检查存储空间后再试。', this.errorCode(error as Error));
          }
        });
        request.on('dataEnd', (): void => {
          if (settled) return;
          streamEnded = true;
          refreshIdleTimer();
          finishIfReady();
        });
        refreshIdleTimer();
        request.requestInStream(
          this.gateway.endpoint(`/api/artifacts/${encodeURIComponent(artifact.id)}/content`), options)
          .then((code: number): void => {
            if (settled) return;
            responseCode = code;
            if (code !== 200) {
              fail('这份文件暂时没有取到，请刷新档案后再试。');
              return;
            }
            refreshIdleTimer();
            finishIfReady();
          }).catch((error: Error): void => {
            fail('这份文件还没有传完整，请重新取一次。', this.errorCode(error));
          });
      });
      }
    } catch (error) {
      if (error instanceof NativeFileError) throw error;
      throw new NativeFileError(operation.phase, this.errorCode(error as Error),
        failureMessage.length > 0 ? failureMessage : this.saveFailure(operation.phase));
    } finally {
      settled = true;
      if (idleTimer >= 0) clearTimeout(idleTimer);
      try {
        request.off('dataReceive');
      } catch (_) {
        // An aborted transfer may already have detached its listeners.
      } finally {
        try {
          request.off('dataEnd');
        } catch (_) {
          // Cleanup continues even when the system has already removed the hook.
        } finally {
          this.cancelRequest(request);
          await fileIo.close(destination);
        }
      }
    }
    operation.phase = 'verify';
    const verified = await fileIo.open(localPath, fileIo.OpenMode.READ_ONLY);
    try {
      const digest = await this.hashOpenFile(verified.fd, artifact.size);
      if (digest.toLowerCase() !== artifact.sha256.toLowerCase()) {
        throw new NativeFileError('verify', 0, '文件的校验没有对上，已收内容先留在手机，暂不导出。');
      }
      operation.phase = 'picker';
      const documentPicker = new picker.DocumentViewPicker(this.context);
      const options = new picker.DocumentSaveOptions();
      options.newFileNames = [artifact.name.replace(/[\\/]/g, '_')];
      const uris = await documentPicker.save(options);
      if (uris.length === 0) {
        return false;
      }
      operation.phase = 'export';
      const output = await fileIo.open(uris[0], fileIo.OpenMode.READ_WRITE);
      try {
        await fileIo.copyFile(verified.fd, output.fd);
      } finally {
        await fileIo.close(output);
      }
      return true;
    } finally {
      await fileIo.close(verified);
    }
  }

  private saveFailure(phase: string): string {
    if (phase === 'prepare') return '这份交付的校验信息还不完整，请刷新档案再试。';
    if (phase === 'storage' || phase === 'write') return '手机暂时没能写入这份文件，请检查可用空间后再试。';
    if (phase === 'verify') return '这份原件暂时未能完成校验，已收内容留在手机，请稍后再试。';
    if (phase === 'picker') return '系统保存窗口暂时没能打开，请稍后再试。';
    if (phase === 'export') return '原件已经取好，暂时未能写入所选位置，请重新选择保存位置。';
    return '这份文件还没有传完整，请重新取一次。';
  }

  private errorCode(error: Error): number {
    const code = (error as BusinessError).code;
    return typeof code === 'number' && Number.isSafeInteger(code) ? code : 0;
  }

  private async hashOpenFile(fd: number, size: number): Promise<string> {
    const hash = cryptoFramework.createMd('SHA256');
    let offset: number = 0;
    while (offset < size) {
      const length = Math.min(CHUNK_BYTES, size - offset);
      const buffer = new ArrayBuffer(length);
      const read = await fileIo.read(fd, buffer, { offset: offset, length: length });
      if (read <= 0) {
        throw new Error('这份文件暂时读不到完整内容，请重新选择它。');
      }
      await hash.update({ data: new Uint8Array(buffer, 0, read) });
      offset += read;
    }
    const result = await hash.digest();
    return this.toHex(result.data);
  }

  private cancelRequest(request: http.HttpRequest): void {
    try {
      request.destroy();
    } catch (_) {
      // A completed or aborted request has no remaining transfer to cancel.
    }
  }

  private toHex(data: Uint8Array): string {
    let result: string = '';
    for (let index = 0; index < data.length; index++) {
      result += data[index].toString(16).padStart(2, '0');
    }
    return result;
  }

  private filename(uri: string): string {
    const last = uri.substring(uri.lastIndexOf('/') + 1).split('?')[0];
    try {
      return decodeURIComponent(last).replace(/[\\/]/g, '_') || '未命名文件';
    } catch (_) {
      return last || '未命名文件';
    }
  }

  private mimeFor(name: string): string {
    const extension = name.toLowerCase().split('.').pop();
    switch (extension) {
      case 'pdf': return 'application/pdf';
      case 'png': return 'image/png';
      case 'jpg':
      case 'jpeg': return 'image/jpeg';
      case 'webp': return 'image/webp';
      case 'gif': return 'image/gif';
      case 'mp4': return 'video/mp4';
      case 'aac': return 'audio/aac';
      case 'm4a': return 'audio/mp4';
      case 'mp3': return 'audio/mpeg';
      case 'wav': return 'audio/wav';
      case 'zip': return 'application/zip';
      case '7z': return 'application/x-7z-compressed';
      case 'json': return 'application/json';
      case 'txt':
      case 'md':
      case 'log': return 'text/plain';
      default: return 'application/octet-stream';
    }
  }
}
