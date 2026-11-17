import { util } from '@kit.ArkTS';
import { LocalStore } from './LocalStore';
import { RelayJournal } from './RelayTransport';

/** Only already encrypted HSR1 frames are journalled, inside the encrypted RDB. */
export class LocalRelayJournal implements RelayJournal {
  private store: LocalStore;
  private codec: util.Base64Helper = new util.Base64Helper();
  constructor(store: LocalStore) { this.store=store; }
  async saveRequest(channel: string,id: string,encrypted: ArrayBuffer,method: string): Promise<void> {
    await this.store.putRelayFrame('relay_request',channel+':'+id,this.codec.encodeToStringSync(new Uint8Array(encrypted)),JSON.stringify({method:method}));
  }
  async readRequest(channel: string,id: string): Promise<ArrayBuffer> {
    const encoded=await this.store.get('relay_request',channel+':'+id,'');
    if(!encoded) throw new Error('没有找到这封传送的原稿，请保留原操作。');
    return this.codec.decodeSync(encoded).buffer as ArrayBuffer;
  }
  async saveResponse(channel: string,id: string,encrypted: ArrayBuffer,settled: boolean): Promise<void> {
    await this.store.putRelayFrame('relay_response',channel+':'+id,this.codec.encodeToStringSync(new Uint8Array(encrypted)),JSON.stringify({settled:settled}));
  }
}
