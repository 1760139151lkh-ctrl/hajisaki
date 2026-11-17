import { common } from '@kit.AbilityKit';
import { relationalStore } from '@kit.ArkData';
import { Artifact, Conversation, Message, StreamEvent, PendingMessage, Connection, Settings, defaultSettings } from '../model/Types';

interface RelayRequestInfo { method: string }
interface RelayResponseInfo { settled: boolean }

export class LocalStore {
  private db?: relationalStore.RdbStore;
  private writes: Promise<void> = Promise.resolve();
  private serialize(operation: () => Promise<void>): Promise<void> {
    const next = this.writes.then(operation);
    this.writes = next.catch(() => {});
    return next;
  }
  async open(context: common.UIAbilityContext): Promise<void> {
    this.db = await relationalStore.getRdbStore(context, {
      name: 'hajisaki.db', securityLevel: relationalStore.SecurityLevel.S3, encrypt: true
    });
    await this.db.executeSql('CREATE TABLE IF NOT EXISTS records (kind TEXT NOT NULL, id TEXT NOT NULL, body TEXT NOT NULL, PRIMARY KEY(kind,id))');
    await this.db.executeSql('CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL)');
    await this.db.executeSql('CREATE INDEX IF NOT EXISTS messages_conversation ON messages(conversation_id,created_at)');
    await this.db.executeSql('CREATE TABLE IF NOT EXISTS events (seq INTEGER PRIMARY KEY, conversation_id TEXT NOT NULL, body TEXT NOT NULL)');
    await this.db.executeSql('CREATE TABLE IF NOT EXISTS outbox (client_id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, body TEXT NOT NULL, created_at TEXT NOT NULL, sent INTEGER NOT NULL DEFAULT 0)');
  }
  private ready(): relationalStore.RdbStore {
    if (!this.db) throw new Error('本地手稿尚未打开。');
    return this.db;
  }
  async put(kind: string, id: string, value: string): Promise<void> {
    await this.serialize(async () => {
      await this.ready().executeSql('INSERT OR REPLACE INTO records(kind,id,body) VALUES(?,?,?)', [kind,id,value]);
    });
  }
  async get(kind: string, id: string, fallback: string): Promise<string> {
    await this.writes;
    // Image checkpoints and encrypted relay frames can exceed ResultSet's 2 MiB
    // shared row limit. LiteResultSet reads these records without that window.
    const rows = await this.ready().querySqlWithoutRowCount('SELECT body FROM records WHERE kind=? AND id=?', [kind,id]);
    try { return rows.goToNextRow() ? rows.getString(0) : fallback; } finally { rows.close(); }
  }
  async all<T>(kind: string): Promise<T[]> {
    await this.writes;
    const rows = await this.ready().querySqlWithoutRowCount('SELECT body FROM records WHERE kind=?', [kind]);
    const result: T[] = [];
    try { while (rows.goToNextRow()) result.push(JSON.parse(rows.getString(0)) as T); } finally { rows.close(); }
    return result;
  }
  async putRelayFrame(kind: string, id: string, frame: string, info: string): Promise<void> {
    if(kind!=='relay_request' && kind!=='relay_response') throw new Error('Invalid relay record');
    await this.serialize(async () => {
      const db=this.ready(); db.beginTransaction();
      try {
        await db.executeSql('INSERT OR REPLACE INTO records(kind,id,body) VALUES(?,?,?)',[kind,id,frame]);
        await db.executeSql('INSERT OR REPLACE INTO records(kind,id,body) VALUES(?,?,?)',[kind+'_info',id,info]);
        db.commit();
      } catch(error) { db.rollBack(); throw error as Error; }
    });
  }
  async hasUnsettledRelayMutation(channel: string): Promise<boolean> {
    await this.writes;
    const prefix=channel+':';
    const rows=await this.ready().querySql("SELECT qi.body,ri.body FROM records q LEFT JOIN records qi ON qi.kind='relay_request_info' AND qi.id=q.id LEFT JOIN records ri ON ri.kind='relay_response_info' AND ri.id=q.id WHERE q.kind='relay_request' AND substr(q.id,1,?)=?",[prefix.length,prefix]);
    try {
      while(rows.goToNextRow()) {
        try {
          if(!rows.isColumnNull(0) && (JSON.parse(rows.getString(0)) as RelayRequestInfo).method==='GET') continue;
          if(!rows.isColumnNull(1) && (JSON.parse(rows.getString(1)) as RelayResponseInfo).settled===true) continue;
        } catch(_) { /* Unknown legacy metadata cannot authorize discarding its key. */ }
        return true;
      }
      return false;
    } finally { rows.close(); }
  }
  async conversations(): Promise<Conversation[]> {
    const list = await this.all<Conversation>('conversation');
    return list.sort((a: Conversation, b: Conversation) => b.updated_at.localeCompare(a.updated_at));
  }
  async saveConversations(items: Conversation[]): Promise<void> {
    for (const item of items) await this.put('conversation',item.id,JSON.stringify(item));
  }
  async messages(id: string): Promise<Message[]> {
    await this.writes;
    const rows = await this.ready().querySql('SELECT body FROM messages WHERE conversation_id=? ORDER BY created_at,rowid', [id]);
    const result: Message[] = [];
    try { while (rows.goToNextRow()) result.push(JSON.parse(rows.getString(0)) as Message); } finally { rows.close(); }
    return result.length > 0 ? result : JSON.parse(await this.get('prefetch',id,'[]')) as Message[];
  }
  async matchingConversations(query: string): Promise<string[]> {
    await this.writes;
    const escaped = query.replace(/\\/g,'\\\\').replace(/%/g,'\\%').replace(/_/g,'\\_');
    const term='%'+escaped+'%';
    const rows = await this.ready().querySql("SELECT conversation_id FROM messages WHERE body LIKE ? ESCAPE '\\' UNION SELECT id FROM records WHERE kind='prefetch' AND body LIKE ? ESCAPE '\\' LIMIT 100", [term,term]);
    const result: string[] = [];
    try { while (rows.goToNextRow()) result.push(rows.getString(0)); } finally { rows.close(); }
    return result;
  }
  async saveMessages(items: Message[]): Promise<void> {
    await this.serialize(async () => {
      const db = this.ready();
      db.beginTransaction();
      try {
        for (const item of items) await db.executeSql('INSERT OR REPLACE INTO messages(id,conversation_id,body,created_at) VALUES(?,?,?,?)',
          [item.id,item.conversation_id,JSON.stringify(item),item.created_at]);
        db.commit();
      } catch (error) { db.rollBack(); throw error as Error; }
    });
  }
  async savePrefetchedMessages(id: string, items: Message[], watermark: number): Promise<void> {
    await this.serialize(async () => {
      const db=this.ready(); db.beginTransaction();
      try {
        const rows=await db.querySql("SELECT body FROM records WHERE kind='prefetch_cursor' AND id=?",[id]);
        let current=0;
        try { if(rows.goToFirstRow()) current=Number(rows.getString(0)); } finally { rows.close(); }
        if (current<=watermark) {
          // Inactive prefetch is a separate snapshot. It must never alter the
          // message table whose content is coupled to the live event cursor.
          await db.executeSql('INSERT OR REPLACE INTO records(kind,id,body) VALUES(?,?,?)',['prefetch',id,JSON.stringify(items)]);
          await db.executeSql('INSERT OR REPLACE INTO records(kind,id,body) VALUES(?,?,?)',['prefetch_cursor',id,String(watermark)]);
        }
        db.commit();
      } catch(error) { db.rollBack(); throw error as Error; }
    });
  }
  async clearSentDraft(id: string, content: string): Promise<void> {
    await this.serialize(async () => {
      await this.ready().executeSql("UPDATE records SET body='' WHERE kind='draft' AND id=? AND body=?",[id,content]);
    });
  }
  async clearSentAttachments(id: string, sent: Artifact[]): Promise<void> {
    await this.serialize(async () => {
      const db=this.ready();
      const rows=await db.querySql("SELECT body FROM records WHERE kind='draft_attachments' AND id=?",[id]);
      let selected: Artifact[]=[];
      try { if(rows.goToFirstRow()) selected=JSON.parse(rows.getString(0)) as Artifact[]; } finally { rows.close(); }
      const ids=sent.map((file:Artifact) => file.id);
      await db.executeSql('INSERT OR REPLACE INTO records(kind,id,body) VALUES(?,?,?)',
        ['draft_attachments',id,JSON.stringify(selected.filter((file:Artifact) => !ids.includes(file.id)))]);
    });
  }
  async cursor(id: string): Promise<number> { return Number(await this.get('cursor',id,'0')); }
  async saveSnapshot(id: string, messages: Message[], events: StreamEvent[], cursor: number): Promise<void> {
    await this.serialize(async () => {
      const db = this.ready(); db.beginTransaction();
      try {
        for (const item of messages) await db.executeSql('INSERT OR REPLACE INTO messages(id,conversation_id,body,created_at) VALUES(?,?,?,?)',
          [item.id,item.conversation_id,JSON.stringify(item),item.created_at]);
        for (const event of events) await db.executeSql('INSERT OR IGNORE INTO events(seq,conversation_id,body) VALUES(?,?,?)', [event.seq,id,JSON.stringify(event)]);
        await db.executeSql('INSERT OR REPLACE INTO records(kind,id,body) VALUES(?,?,?)',['cursor',id,String(cursor)]);
        db.commit();
      } catch (error) { db.rollBack(); throw error as Error; }
    });
  }
  async saveEvents(id: string, items: StreamEvent[], cursor: number): Promise<void> {
    await this.serialize(async () => {
      const db = this.ready();
      db.beginTransaction();
      try {
        for (const item of items) await db.executeSql('INSERT OR IGNORE INTO events(seq,conversation_id,body) VALUES(?,?,?)', [item.seq,id,JSON.stringify(item)]);
        await db.executeSql('INSERT OR REPLACE INTO records(kind,id,body) VALUES(?,?,?)', ['cursor',id,String(cursor)]);
        db.commit();
      } catch (error) { db.rollBack(); throw error as Error; }
    });
  }
  async events(id: string): Promise<StreamEvent[]> {
    await this.writes;
    const rows = await this.ready().querySql('SELECT body FROM events WHERE conversation_id=? ORDER BY seq', [id]);
    const result: StreamEvent[] = [];
    try { while (rows.goToNextRow()) result.push(JSON.parse(rows.getString(0)) as StreamEvent); } finally { rows.close(); }
    return result;
  }
  async enqueue(item: PendingMessage): Promise<void> {
    await this.serialize(async () => {
      await this.ready().executeSql('INSERT OR IGNORE INTO outbox(client_id,conversation_id,body,created_at) VALUES(?,?,?,?)',
        [item.client_id,item.conversation_id,JSON.stringify(item),item.created_at]);
    });
  }
  async pending(): Promise<PendingMessage[]> {
    await this.writes;
    const rows = await this.ready().querySql('SELECT body FROM outbox WHERE sent=0 ORDER BY created_at,rowid');
    const result: PendingMessage[] = [];
    try { while (rows.goToNextRow()) result.push(JSON.parse(rows.getString(0)) as PendingMessage); } finally { rows.close(); }
    return result;
  }
  async sent(clientId: string): Promise<void> {
    await this.serialize(async () => { await this.ready().executeSql('UPDATE outbox SET sent=1 WHERE client_id=?', [clientId]); });
  }
  async settings(): Promise<Settings> { return JSON.parse(await this.get('config','settings',JSON.stringify(defaultSettings()))) as Settings; }
  async connection(): Promise<Connection> {
    return JSON.parse(await this.get('config','connection','{"primary":"","fallback":"","device":""}')) as Connection;
  }
  async close(): Promise<void> { if (this.db) { await this.db.close(); this.db = undefined; } }
}
