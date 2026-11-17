import { common } from '@kit.AbilityKit';
import { Artifact, Conversation, Message, StreamEvent, PendingMessage, Connection, Settings,
  defaultSettings } from '../model/Types';
import { LocalStore } from './LocalStore';

interface PreviewMessageRow {
  conversation: string;
  created: string;
  order: number;
  body: string;
}

interface PreviewEventRow { conversation: string; body: string }
interface RelayRequestInfo { method: string }
interface RelayResponseInfo { settled: boolean }

interface PreviewOutboxRow {
  created: string;
  order: number;
  body: string;
  sent: boolean;
}

/**
 * Explicit preview-product storage adapter, containing only data received through
 * normal application flows. It never opens a database or writes credentials/files.
 * All content lasts only for this instance's lifetime; it is not durable storage.
 * Production selection must remain LocalStore, with no error-triggered fallback.
 */
export class PreviewStore extends LocalStore {
  private previewOpened: boolean = false;
  private previewWrites: Promise<void> = Promise.resolve();
  private records: Map<string, Map<string, string>> = new Map();
  private messageRows: Map<string, PreviewMessageRow> = new Map();
  private eventRows: Map<number, PreviewEventRow> = new Map();
  private outboxRows: Map<string, PreviewOutboxRow> = new Map();
  private messageOrder: number = 0;
  private outboxOrder: number = 0;

  async open(_context: common.UIAbilityContext): Promise<void> {
    await this.previewWrites;
    this.previewOpened = true;
  }

  async put(kind: string, id: string, value: string): Promise<void> {
    await this.transact(() => { this.setRecord(kind, id, value); });
  }

  async get(kind: string, id: string, fallback: string): Promise<string> {
    await this.previewWrites;
    this.requireOpen();
    return this.record(kind, id, fallback);
  }

  async all<T>(kind: string): Promise<T[]> {
    await this.previewWrites;
    this.requireOpen();
    const values = this.records.get(kind);
    const result: T[] = [];
    if (values) {
      for (const body of values.values()) result.push(JSON.parse(body) as T);
    }
    return result;
  }
  async putRelayFrame(kind: string, id: string, frame: string, info: string): Promise<void> {
    if(kind!=='relay_request' && kind!=='relay_response') throw new Error('Invalid relay record');
    await this.transact(()=>{this.setRecord(kind,id,frame);this.setRecord(kind+'_info',id,info);});
  }
  async hasUnsettledRelayMutation(channel: string): Promise<boolean> {
    await this.previewWrites; this.requireOpen();
    const requests=this.records.get('relay_request');
    if(!requests) return false;
    for(const id of requests.keys()) {
      if(!id.startsWith(channel+':')) continue;
      try {
        const request=this.record('relay_request_info',id,'{}');
        if((JSON.parse(request) as RelayRequestInfo).method==='GET') continue;
        const response=this.record('relay_response_info',id,'{}');
        if((JSON.parse(response) as RelayResponseInfo).settled===true) continue;
      } catch(_) { /* Unknown metadata retains the key. */ }
      return true;
    }
    return false;
  }

  async conversations(): Promise<Conversation[]> {
    const values = await this.all<Conversation>('conversation');
    return values.sort((a: Conversation, b: Conversation) => b.updated_at.localeCompare(a.updated_at));
  }

  async saveConversations(items: Conversation[]): Promise<void> {
    for (const item of items) await this.put('conversation', item.id, JSON.stringify(item));
  }

  async messages(id: string): Promise<Message[]> {
    await this.previewWrites;
    this.requireOpen();
    const rows = Array.from(this.messageRows.values()).filter((row: PreviewMessageRow) => row.conversation === id);
    rows.sort((a: PreviewMessageRow, b: PreviewMessageRow) => a.created.localeCompare(b.created) || a.order - b.order);
    const messages = rows.map((row: PreviewMessageRow): Message => JSON.parse(row.body) as Message);
    return messages.length > 0 ? messages : JSON.parse(this.record('prefetch', id, '[]')) as Message[];
  }

  async matchingConversations(query: string): Promise<string[]> {
    await this.previewWrites;
    this.requireOpen();
    const needle = this.asciiFold(query);
    const result: string[] = [];
    for (const row of this.messageRows.values()) {
      // LocalStore uses SQLite LIKE with escaped wildcards: match literal text,
      // retaining SQLite's default ASCII-only case folding.
      if (this.asciiFold(row.body).includes(needle) && !result.includes(row.conversation)) {
        result.push(row.conversation);
        if (result.length >= 100) break;
      }
    }
    return result;
  }

  async saveMessages(items: Message[]): Promise<void> {
    await this.transact(() => {
      const staged = new Map(this.messageRows);
      let order = this.messageOrder;
      for (const item of items) {
        staged.set(item.id, {
          conversation: item.conversation_id, created: item.created_at, order: ++order, body: JSON.stringify(item)
        });
      }
      this.messageRows = staged;
      this.messageOrder = order;
    });
  }

  async savePrefetchedMessages(id: string, items: Message[], watermark: number): Promise<void> {
    await this.transact(() => {
      const current = Number(this.record('prefetch_cursor', id, '0'));
      if (current <= watermark) {
        const body = JSON.stringify(items);
        this.setRecord('prefetch', id, body);
        this.setRecord('prefetch_cursor', id, String(watermark));
      }
    });
  }

  async clearSentDraft(id: string, content: string): Promise<void> {
    await this.transact(() => {
      const drafts = this.records.get('draft');
      if (drafts?.has(id) && drafts.get(id) === content) this.setRecord('draft', id, '');
    });
  }

  async clearSentAttachments(id: string, sent: Artifact[]): Promise<void> {
    await this.transact(() => {
      const selected = JSON.parse(this.record('draft_attachments', id, '[]')) as Artifact[];
      const ids = sent.map((file: Artifact) => file.id);
      this.setRecord('draft_attachments', id,
        JSON.stringify(selected.filter((file: Artifact) => !ids.includes(file.id))));
    });
  }

  async cursor(id: string): Promise<number> {
    return Number(await this.get('cursor', id, '0'));
  }

  async saveSnapshot(id: string, messages: Message[], events: StreamEvent[], cursor: number): Promise<void> {
    await this.transact(() => {
      const stagedMessages = new Map(this.messageRows);
      const stagedEvents = new Map(this.eventRows);
      let order = this.messageOrder;
      for (const item of messages) {
        stagedMessages.set(item.id, {
          conversation: item.conversation_id, created: item.created_at, order: ++order, body: JSON.stringify(item)
        });
      }
      for (const event of events) {
        if (!stagedEvents.has(event.seq)) {
          stagedEvents.set(event.seq, { conversation: id, body: JSON.stringify(event) });
        }
      }
      // No await occurs during publication. Readers wait for this transaction,
      // so message content, event rows and the replay cursor become visible together.
      this.messageRows = stagedMessages;
      this.eventRows = stagedEvents;
      this.messageOrder = order;
      this.setRecord('cursor', id, String(cursor));
    });
  }

  async saveEvents(id: string, items: StreamEvent[], cursor: number): Promise<void> {
    await this.transact(() => {
      const staged = new Map(this.eventRows);
      for (const item of items) {
        if (!staged.has(item.seq)) staged.set(item.seq, { conversation: id, body: JSON.stringify(item) });
      }
      this.eventRows = staged;
      this.setRecord('cursor', id, String(cursor));
    });
  }

  async events(id: string): Promise<StreamEvent[]> {
    await this.previewWrites;
    this.requireOpen();
    const result: StreamEvent[] = [];
    for (const row of this.eventRows.values()) {
      if (row.conversation === id) result.push(JSON.parse(row.body) as StreamEvent);
    }
    return result.sort((a: StreamEvent, b: StreamEvent) => a.seq - b.seq);
  }

  async enqueue(item: PendingMessage): Promise<void> {
    await this.transact(() => {
      if (!this.outboxRows.has(item.client_id)) {
        const body = JSON.stringify(item);
        this.outboxRows.set(item.client_id, {
          created: item.created_at, order: ++this.outboxOrder, body: body, sent: false
        });
      }
    });
  }

  async pending(): Promise<PendingMessage[]> {
    await this.previewWrites;
    this.requireOpen();
    const rows = Array.from(this.outboxRows.values()).filter((row: PreviewOutboxRow) => !row.sent);
    rows.sort((a: PreviewOutboxRow, b: PreviewOutboxRow) => a.created.localeCompare(b.created) || a.order - b.order);
    return rows.map((row: PreviewOutboxRow): PendingMessage => JSON.parse(row.body) as PendingMessage);
  }

  async sent(clientId: string): Promise<void> {
    await this.transact(() => {
      const row = this.outboxRows.get(clientId);
      if (row) row.sent = true;
    });
  }

  async settings(): Promise<Settings> {
    return JSON.parse(await this.get('config', 'settings', JSON.stringify(defaultSettings()))) as Settings;
  }

  async connection(): Promise<Connection> {
    return JSON.parse(await this.get('config', 'connection',
      '{"primary":"","fallback":"","device":""}')) as Connection;
  }

  async close(): Promise<void> {
    await this.previewWrites;
    this.previewOpened = false;
  }

  private transact(operation: () => void): Promise<void> {
    const next = this.previewWrites.then(() => { this.requireOpen(); operation(); });
    this.previewWrites = next.catch(() => {});
    return next;
  }

  private requireOpen(): void {
    if (!this.previewOpened) throw new Error('预览手稿尚未打开。');
  }

  private record(kind: string, id: string, fallback: string): string {
    return this.records.get(kind)?.get(id) ?? fallback;
  }

  private setRecord(kind: string, id: string, body: string): void {
    let values = this.records.get(kind);
    if (!values) {
      values = new Map<string, string>();
      this.records.set(kind, values);
    }
    values.set(id, body);
  }

  private asciiFold(value: string): string {
    return value.replace(/[A-Z]/g, (letter: string): string => letter.toLowerCase());
  }
}
