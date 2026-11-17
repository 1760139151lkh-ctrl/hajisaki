import { common } from '@kit.AbilityKit';
import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { Artifact, ArtifactPage, Conversation, ConversationPage, EventPage, Memory, MemoryPage,
  Message, MessagePage, ModelPage, PendingMessage, SendResult, Settings, Status, StreamEvent,
  TaskPage, MessageTasks, ContextPin, PinPage } from '../model/Types';
import { ClientState, MessageSource } from '../model/ClientState';
import { Gateway, GatewayError } from './Gateway';
import { LocalStore } from './LocalStore';
import { EventStream } from './EventStream';
import { Credentials, StoredCredential } from '../platform/Credentials';
import { RelayTransport, RelayConfig, RelayCredentials, RelayError } from './RelayTransport';
import { LocalRelayJournal } from './LocalRelayJournal';
import { RelayVault, RelayImportError, StoredRelayProfile } from '../platform/RelayVault';
import { previewMode } from '../model/BuildMode';
import { PreviewStore } from './PreviewStore';
import { ComposerState, ComposerCatalog } from '../model/CommandTypes';
import { BranchOrigin } from '../model/BranchTypes';

export class Companion {
  readonly gateway: Gateway = new Gateway();
  readonly local: LocalStore = previewMode() ? new PreviewStore() : new LocalStore();
  readonly messageSource: MessageSource = new MessageSource();
  readonly state: ClientState;
  private pollTimer: number = -1;
  private polling: boolean = false;
  private draining: boolean = false;
  private generation: number = 0;
  private stoppedRuns: string[] = [];
  private prefetching: boolean = false;
  private credentials?: Credentials;
  private relayVault?: RelayVault;
  private importingRelay: boolean = false;
  private sessionCredential?: StoredCredential;
  private stream: EventStream = new EventStream();
  private streamId: string = '';
  private eventQueue: StreamEvent[] = [];
  private flushTimer: number = -1;
  private flushing: boolean = false;
  private draftRevision: number = 0;
  private memoryRevision: number = 0;
  private committedMessages: Map<string,Message[]> = new Map();
  private committedCursors: Map<string,number> = new Map();
  private previewSequence:number=0;
  private composerVersions:Map<string,number>=new Map();
  onMessages: () => void = () => {};
  onCue: (cue: 'send' | 'reply') => void = () => {};

  constructor(state: ClientState) {
    this.state = state;
    this.gateway.onAvailabilityChange=(available:boolean)=>{
      this.state.online=available; this.state.relayActive=this.gateway.isRelayActive();
    };
    this.state.previewStorage=previewMode();
    this.stream.onEvent = (event: StreamEvent) => {
      if (event.conversation_id !== this.state.activeId) return;
      this.eventQueue.push(event); this.scheduleFlush(); this.state.online = true;
    };
    this.stream.onDisconnect = () => { this.streamId = ''; };
  }
  async initialize(context: common.UIAbilityContext): Promise<void> {
    try {
      if(!this.state.previewStorage) this.credentials = new Credentials(context);
      await this.local.open(context);
      this.state.settings = await this.local.settings();
      this.state.connection = await this.local.connection();
      this.state.conversations = await this.local.conversations();
      this.state.memories = JSON.parse(await this.local.get('snapshot','memories','[]')) as Memory[];
      this.state.artifacts = await this.local.all<Artifact>('artifact');
      this.state.pending = await this.pendingWithFailures();
      this.state.queued = this.state.pending.length;
      const previous = await this.local.get('config','active','');
      if (previous.length > 0) {
        const item = this.state.conversations.find((c: Conversation) => c.id === previous);
        if (item && item.group !== '私密保险箱') await this.open(item, false);
      }
      this.state.ready = true;
      this.relayVault = new RelayVault(context);
      try {
        const stored = await this.relayVault.load();
        if(stored) await this.configureRelay(stored.relay,this.relayVault.credentialsFor(stored),stored);
      } catch(error) {
        this.state.relayNotice=error instanceof RelayImportError || error instanceof RelayError ? error.message : '备用钥匙暂时没有取出，请重新导入通道文件。';
      }
      try {
        const credential = await this.credentials?.load();
        if (credential) await this.connect(credential.primary,credential.fallback,credential.token,credential.device,false);
      } catch (error) { this.state.notice = '钥匙暂时还没有取出，可以到主机台重新配对。'; }
    } catch (error) { this.fail(error); this.state.ready = true; }
  }
  private fail(error: Error): void {
    if(error instanceof GatewayError && error.requestId) {
      this.state.pendingRelayId=error.outcomeUncertain ? error.requestId : '';
    }
    this.state.notice = error instanceof GatewayError ? error.message : '手稿暂时没能收好，请保留这一页，再试一次。';
  }
  clearNotice(): void { this.state.notice = ''; }
  async retryRelay():Promise<void> {
    const id=this.state.pendingRelayId;
    if(!id) return;
    try {
      await this.gateway.retryRelay(id);
      this.state.pendingRelayId=''; this.state.notice='';
      await this.refresh(); await this.loadMemories(false); await this.synchronize();
    } catch(error) { this.fail(error); }
  }
  async configureRelay(config: RelayConfig, credentials: RelayCredentials, stored?: StoredRelayProfile): Promise<void> {
    const transport=new RelayTransport();
    try {
      await transport.configure(config,credentials,new LocalRelayJournal(this.local));
      this.gateway.installRelay(transport,false,stored?.gatewayToken || '',stored?.gatewayDevice || '');
      this.state.relayConfigured=true; this.state.relayOrigin=config.origin;
    } catch(error) { transport.dispose(); throw error as Error; }
  }
  async importRelay(source: string): Promise<void> {
    if(this.importingRelay || !this.relayVault) throw new RelayImportError('备用通道还在准备，稍等片刻再试。');
    this.importingRelay=true;
    let transport: RelayTransport | undefined = undefined;
    let locked=false;
    try {
      const profile=this.relayVault.parse(source);
      if(!this.gateway.isConfigured()) throw new RelayImportError('先填好主机地址与设备钥匙，再来接备用琴房。');
      const gatewayHeaders=this.gateway.headers();
      const stored=await this.relayVault.stage(profile,gatewayHeaders['Authorization'].substring(7),gatewayHeaders['X-Haji-Device']);
      transport=new RelayTransport();
      await transport.configure(stored.relay,this.relayVault.credentialsFor(stored),new LocalRelayJournal(this.local));
      const reply=await transport.request('/api/status','GET',this.gateway.headers());
      if(reply.status!==200 || reply.outcomeUncertain) throw new RelayImportError('备用琴房还没有认出这台设备，请核对配对钥匙后再试。');
      const status=JSON.parse(reply.body) as Status;
      if(!status.provider || typeof status.provider.name!=='string') throw new RelayImportError('备用琴房的回信还不完整，稍后再试。');
      const currentHeaders=this.gateway.headers();
      if(currentHeaders['Authorization']!==gatewayHeaders['Authorization'] || currentHeaders['X-Haji-Device']!==gatewayHeaders['X-Haji-Device']) {
        throw new RelayImportError('设备钥匙刚刚换过，请按当前钥匙重新导入通道文件。');
      }
      this.gateway.beginRelayUpdate(transport); locked=true;
      if(this.gateway.relayIdentityChanges(transport) && await this.local.hasUnsettledRelayMutation(this.gateway.currentRelayChannel())) {
        throw new RelayImportError('还有传送回执没有确认，请先保留当前备用钥匙并收好回执。');
      }
      await this.relayVault.save(stored);
      this.gateway.installRelay(transport,!this.state.online,stored.gatewayToken,stored.gatewayDevice);
      transport=undefined;
      this.state.relayConfigured=true; this.state.relayOrigin=stored.relay.origin;
      this.state.relayActive=this.gateway.isRelayActive(); this.state.relayNotice='';
      this.state.status=status; this.state.online=true;
    } catch(error) {
      if(error instanceof RelayImportError || error instanceof RelayError || error instanceof GatewayError) throw error as Error;
      throw new RelayImportError('备用通道暂时没有接稳，请保留通道文件后再试。');
    } finally {
      if(locked) this.gateway.endRelayUpdate();
      transport?.dispose(); this.importingRelay=false;
    }
    const pairing=this.sessionCredential;
    if(pairing) await this.connect(pairing.primary,pairing.fallback,pairing.token,pairing.device);
  }
  async connect(primary: string, fallback: string, token: string, device: string, remember: boolean = true): Promise<void> {
    this.state.connecting = true;
    try {
      this.gateway.configure(primary,fallback,token,device);
      this.sessionCredential={primary:primary,fallback:fallback,token:token,device:device};
      this.state.relayConfigured=this.gateway.hasUsableRelay();
      this.state.relayActive=this.gateway.isRelayActive();
      if(this.state.relayOrigin) this.state.relayNotice=this.state.relayConfigured ? '' : '备用通道与当前设备钥匙不同，请为本机重新导入。';
      this.state.status = await this.gateway.request<Status>('/api/status');
      this.state.connection = { primary: primary, fallback: fallback, device: device };
      // Ordinary configuration contains no secret; Asset Store holds the pairing credential.
      await this.local.put('config','connection',JSON.stringify(this.state.connection));
      this.state.online = true;
      this.state.notice = '';
      if (await this.local.get('config','settings_pending','false') === 'true') {
        await this.gateway.request<Settings>('/api/settings/update',http.RequestMethod.POST,JSON.stringify(this.state.settings));
        await this.local.put('config','settings_pending','false');
      } else {
        this.state.settings = await this.gateway.request<Settings>('/api/settings');
        await this.local.put('config','settings',JSON.stringify(this.state.settings));
      }
      const models = await this.gateway.request<ModelPage>('/api/models');
      this.state.models = models.models;
      if (models.models.length > 0) {
        this.state.model = models.models[0].id;
        this.state.effort = models.models[0].efforts[0] || '';
      }
      await this.refresh();
      try {await this.composerCatalog();}catch (_) { /* Cached shortcuts remain usable until the next connection. */ }
      await this.drain();
      this.startPolling();
      this.prefetchHistory();
      if (remember && this.credentials) {
        try { await this.credentials.save(token,device,primary,fallback); }
        catch (error) { this.state.notice = '已接回琴房。这台设备暂时不能安全记住钥匙，下次仍需配对。'; }
      }
    } catch (error) { this.state.online = false; this.fail(error); }
    finally { this.state.connecting = false; }
  }
  async refresh(): Promise<void> {
    if (!this.gateway.isConfigured()) return;
    try {
      const result = await this.gateway.request<ConversationPage>('/api/conversations');
      await this.local.saveConversations(result.conversations);
      this.state.conversations = result.conversations;
      this.state.status = await this.gateway.request<Status>('/api/status');
      this.state.online = true;
    } catch (error) { this.state.online = false; this.fail(error); }
  }
  filteredConversations(query:string, group:string, conversations:Conversation[], matches:string[]): Conversation[] {
    return conversations.filter((item: Conversation) => {
      const groupMatch = group === '全部' ? item.group !== '私密保险箱' : group === item.group;
      const term = query.trim().toLowerCase();
      return !item.archived && (!item.branch_parent_id || term.length>0) && groupMatch && ((item.title + item.preview).toLowerCase().includes(term) || matches.includes(item.id));
    }).sort((a: Conversation,b: Conversation) => Number(b.pinned)-Number(a.pinned) || b.updated_at.localeCompare(a.updated_at));
  }
  async search(query: string): Promise<void> {
    this.state.query = query;
    this.state.searchConversationIds=[];
    if (!query.trim()) { this.state.searchConversationIds = []; return; }
    try {
      const matches = await this.local.matchingConversations(query.trim());
      if (this.state.query === query) this.state.searchConversationIds = matches;
      if(this.gateway.isConfigured() && this.state.online) {
        const found=await this.gateway.request<ConversationPage>('/api/conversations?q='+encodeURIComponent(query.trim()));
        if(this.state.query===query) this.state.searchConversationIds=found.conversations.map((item:Conversation) => item.id);
      }
    } catch (error) { this.fail(error); }
  }
  private async prefetchHistory(): Promise<void> {
    if (this.prefetching) return;
    this.prefetching = true;
    try {
      for (const item of this.state.conversations) {
        if (!this.state.online) break;
        if (item.id === this.state.activeId) continue;
        const snapshot = await this.gateway.request<MessagePage>('/api/conversations/' + encodeURIComponent(item.id) + '/messages');
        await this.local.savePrefetchedMessages(item.id,snapshot.messages,snapshot.cursor);
      }
    } catch (error) {
      // Existing local history remains available; resume() retries the unfinished sync.
    } finally { this.prefetching = false; }
  }
  async create(navigate:boolean=true): Promise<Conversation | undefined> {
    try {
      const group = this.state.group === '全部' ? '专属日常' : this.state.group;
      const result = await this.gateway.request<Conversation>('/api/conversations',http.RequestMethod.POST,
        JSON.stringify({ title: '未写完的乐章', group: group }));
      await this.local.saveConversations([result]);
      this.state.conversations = [result].concat(this.state.conversations);
      await this.open(result,navigate);
      return result;
    } catch (error) { this.fail(error); return undefined; }
  }
  async open(item: Conversation, navigate: boolean = true): Promise<void> {
    this.stream.close(); this.streamId = ''; this.eventQueue = [];
    const ticket = ++this.generation;
    this.state.draftLoading=true;this.state.draftEpoch++;
    this.state.activeId = item.id; this.state.activeTitle = item.title;
    this.state.runId = ''; this.state.stopping = false; this.state.showProcess = false;
    this.state.taskPages=[]; this.state.pins=[];
    if (navigate) this.state.page = 'chat';
    const savedMessages = await this.local.messages(item.id);
    const savedEvents = await this.local.events(item.id);
    const draft = await this.local.get('draft',item.id,'');
    const attachments = JSON.parse(await this.local.get('draft_attachments',item.id,'[]')) as Artifact[];
    const pins=JSON.parse(await this.local.get('pins',item.id,'[]')) as ContextPin[];
    const composer=JSON.parse(await this.local.get('composer',item.id,'null')) as ComposerState | null;
    const origin=JSON.parse(await this.local.get('branch-origin',item.id,'{"thread":null,"arena":null}')) as BranchOrigin;
    if (ticket !== this.generation) return;
    this.state.events = savedEvents; this.state.draft = draft;
    this.state.draftEpoch++;this.state.draftLoading=false;
    this.draftRevision++; this.state.selectedAttachments=attachments;
    for (const event of savedEvents) {
      if (event.kind === 'run_started') this.state.runId = event.run_id;
      if ((event.kind === 'run_finished' || event.kind === 'run_stopped' || event.kind === 'run_failed') && this.state.runId === event.run_id) this.state.runId = '';
    }
    this.setMessages(savedMessages);
    this.state.pins=pins;
    this.state.toneId=composer?.tone_id || 'inherit';
    this.state.branchOrigin=origin;
    await this.local.put('config','active',item.id);
    if (this.gateway.isConfigured()) { await this.synchronize(); this.startPolling(); this.loadPins(); this.refreshComposer(item.id).catch(()=>{}); this.refreshOrigin(item.id,ticket); }
  }

  private async refreshOrigin(id:string,ticket:number):Promise<void> {
    try {
      const origin=await this.gateway.request<BranchOrigin>('/api/conversations/'+encodeURIComponent(id)+'/origin');
      if(ticket!==this.generation)return;
      await this.local.put('branch-origin',id,JSON.stringify(origin));
      if(ticket===this.generation && this.state.activeId===id)this.state.branchOrigin=origin;
    } catch (_) { /* Retain the cached origin while reconnecting. */ }
  }
  async knownConversation(id:string):Promise<Conversation> {
    let item=this.state.conversations.find((item:Conversation)=>item.id===id);
    if(!item){await this.refresh();item=this.state.conversations.find((item:Conversation)=>item.id===id);}
    if(!item) {
      const saved=await this.local.get('conversation',id,'');
      if(saved)item=JSON.parse(saved) as Conversation;
    }
    if(!item)throw new Error('这一页暂时没有取回，原来的乐章仍在。');
    return item;
  }
  async openKnown(id:string):Promise<void> {
    await this.open(await this.knownConversation(id));
  }

  async composerCatalog():Promise<ComposerCatalog> {
    const result=await this.gateway.request<ComposerCatalog>('/api/composer/catalog');
    await this.local.put('snapshot','composer-catalog',JSON.stringify(result));
    return result;
  }
  async refreshComposer(conversation:string):Promise<ComposerState | undefined> {
    const revision=(this.composerVersions.get(conversation)||0)+1;
    this.composerVersions.set(conversation,revision);
    const result=await this.gateway.request<ComposerState>('/api/conversations/'+encodeURIComponent(conversation)+'/composer');
    if(this.composerVersions.get(conversation)!==revision)return undefined;
    await this.local.put('composer',conversation,JSON.stringify(result));
    if(this.composerVersions.get(conversation)!==revision)return undefined;
    if(this.state.activeId===conversation)this.state.toneId=result.tone_id;
    return result;
  }
  async setTone(conversation:string,tone:string):Promise<void> {
    const revision=(this.composerVersions.get(conversation)||0)+1;
    this.composerVersions.set(conversation,revision);
    try {
      const result=await this.gateway.request<ComposerState>('/api/conversations/'+encodeURIComponent(conversation)+'/tone',
        http.RequestMethod.POST,JSON.stringify({tone_id:tone}));
      if(this.composerVersions.get(conversation)!==revision)return;
      await this.local.put('composer',conversation,JSON.stringify(result));
      if(this.composerVersions.get(conversation)===revision && this.state.activeId===conversation)this.state.toneId=result.tone_id;
    } catch(error) {this.fail(error);throw error as Error;}
  }
  async compact(conversation:string,operation:string,model:string,effort:string):Promise<SendResult> {
    try {
      const result=await this.gateway.request<SendResult>('/api/conversations/'+encodeURIComponent(conversation)+'/compact',
        http.RequestMethod.POST,JSON.stringify({operation_id:operation,model:model,effort:effort}));
      await this.local.saveMessages([result.message]);
      await this.local.put('compact-operation',conversation,'');
      if(this.state.activeId===conversation){await this.synchronize();this.startPolling();}
      return result;
    } catch(error) {this.fail(error);throw error as Error;}
  }
  async stopContext(run:string):Promise<void> {
    if(this.state.runId===run){await this.stop();return;}
    try {
      await this.gateway.request<Record<string,string>>('/api/runs/'+encodeURIComponent(run)+'/stop',http.RequestMethod.POST,'{}');
      await this.synchronize();
    } catch(error) {this.fail(error);throw error as Error;}
  }
  private setMessages(items: Message[]): void {
    this.state.messages = items;
    this.messageSource.replace(items);
    this.onMessages();
  }
  async draftChanged(value: string): Promise<void> {
    this.draftRevision++;
    this.state.draft = value;
    try { if (this.state.activeId) await this.local.put('draft',this.state.activeId,value); }
    catch (error) { this.fail(error); }
  }
  async send(): Promise<void> {
    if (this.state.sending || (!this.state.draft.trim() && this.state.selectedAttachments.length === 0)) return;
    if (!this.state.activeId) { this.state.notice = '先选一页乐章，再把话交给我。'; return; }
    this.state.sending = true;
    const revision=this.draftRevision;
    const ticket=this.generation;
    let clientId='';
    try {
      clientId=this.state.previewStorage ? 'preview-'+Date.now().toString(36)+'-'+(++this.previewSequence)+'-'+Math.random().toString(36).substring(2,12) : util.generateRandomUUID();
      if(typeof clientId!=='string'||clientId.length<1||clientId.length>128) throw new Error('Invalid local message identifier');
    } catch(error) {
      this.state.sending=false;
      this.state.notice='这一页的编号还没写好，你的话先留在这里，稍后再送一次。';
      return;
    }
    const item: PendingMessage = {
      client_id: clientId, conversation_id: this.state.activeId,
      content: this.state.draft, model: this.state.model, effort: this.state.effort,
      tone_id:this.state.toneId,
      attachments: this.state.selectedAttachments, created_at: new Date().toISOString()
    };
    if(this.state.previewStorage) console.info('HajiSaki preview message fields: client_id=' + typeof item.client_id +
      ', client_id_length=' + item.client_id.length + ', model=' + item.model + ', effort=' + item.effort + ', content=' + typeof item.content);
    try {
      // Commit outbox before clearing any user input.
      await this.local.enqueue(item);
      this.onCue('send');
      await this.local.clearSentDraft(item.conversation_id,item.content);
      await this.local.clearSentAttachments(item.conversation_id,item.attachments);
      if (ticket===this.generation) {
        if (revision===this.draftRevision) { this.state.draft=''; this.draftRevision++; }
        const ids=item.attachments.map((file:Artifact) => file.id);
        this.state.selectedAttachments=this.state.selectedAttachments.filter((file:Artifact) => !ids.includes(file.id));
      }
      this.state.pending = await this.pendingWithFailures();
      this.state.queued = this.state.pending.length;
      this.state.notice = this.state.online ? '' : '我先替你夹在本子里，连回琴房就送出。';
    } catch (error) { this.fail(error); }
    finally { this.state.sending = false; }
    await this.drain();
  }
  private async pendingWithFailures():Promise<PendingMessage[]> {
    const pending=await this.local.pending();
    for(const item of pending) item.last_error=await this.local.get('outbox_error',item.client_id,'');
    return pending;
  }
  async drain(retryRejected:boolean=false): Promise<void> {
    if (this.draining || !this.gateway.isConfigured()) return;
    this.draining = true;
    let attempted:PendingMessage|undefined=undefined;
    try {
      const waiting = await this.pendingWithFailures();
      for (const item of waiting) {
        if(item.last_error&&!retryRejected) continue;
        if(retryRejected) await this.local.put('outbox_error',item.client_id,'');
        attempted=item;
        const result = await this.gateway.request<SendResult>('/api/conversations/' + encodeURIComponent(item.conversation_id) + '/messages',
          http.RequestMethod.POST,JSON.stringify({ content: item.content, client_id: item.client_id,
            model: item.model, effort: item.effort, tone_id:item.tone_id, attachments: item.attachments.map((file: Artifact) => file.id) }));
        await this.local.saveMessages([result.message]);
        await this.local.sent(item.client_id);
        // A delayed POST acknowledgement may describe a run which SSE already
        // completed. Current run state comes only from snapshots and lifecycle events.
      }
      this.state.pending = await this.pendingWithFailures();
      this.state.queued = this.state.pending.length;
      this.state.online = true;
      await this.synchronize();
    } catch (error) {
      const failure = error as GatewayError;
      if(attempted && failure.status>=400 && failure.status<500 && ![408,409,429].includes(failure.status)) {
        await this.local.put('outbox_error',attempted.client_id,failure.message);
      }
      if (failure.outcomeUncertain) this.fail(error);
      else if (failure.status === 409) this.state.notice = '这句话已夹在下一页，等她说完就接上。';
      else { if (failure.status === 0) this.state.online = false; this.fail(error); }
    } finally {
      try { this.state.pending=await this.pendingWithFailures(); this.state.queued=this.state.pending.length; }
      finally { this.draining = false; }
    }
  }
  async stop(): Promise<void> {
    const runId = this.state.runId;
    const ticket=this.generation;
    const conversation=this.state.activeId;
    if (!runId) return;
    this.state.stopping = true;
    this.stoppedRuns.push(runId); // Freeze the local transcript immediately.
    try {
      await this.gateway.request<Record<string,string>>('/api/runs/' + encodeURIComponent(runId) + '/stop',http.RequestMethod.POST,'{}');
      if (ticket!==this.generation) return;
      this.state.runId = ''; this.state.stopping = false;
      await this.synchronize();
    } catch (error) {
      const saved=await this.local.messages(conversation);
      if (ticket===this.generation) { this.state.stopping=false; this.setMessages(saved); this.fail(error); }
    }
  }
  async synchronize(fromStream: boolean = false): Promise<void> {
    if (this.polling || (this.flushing && !fromStream) || !this.gateway.isConfigured() || !this.state.activeId) return;
    this.polling = true;
    const id = this.state.activeId;
    const ticket = this.generation;
    try {
      const snapshot = await this.gateway.request<MessagePage>('/api/conversations/' + encodeURIComponent(id) + '/messages');
      if (!Number.isSafeInteger(snapshot.cursor)) throw new Error('主机需要提供一致的手稿游标。');
      let cursor = await this.local.cursor(id);
      let history: StreamEvent[] = [];
      while (cursor < snapshot.cursor) {
        const page = await this.gateway.request<EventPage>('/api/conversations/' + encodeURIComponent(id) + '/events?after=' + cursor + '&limit=1000');
        const included = page.events.filter((event: StreamEvent) => event.seq <= snapshot.cursor);
        history = history.concat(included);
        if (included.length === 0 || page.cursor >= snapshot.cursor || !page.has_more) break;
        cursor = page.cursor;
      }
      // The backend snapshot carries an atomic event watermark. Historical deltas
      // are stored for process history, never appended twice to that snapshot.
      await this.local.saveSnapshot(id,snapshot.messages,history,snapshot.cursor);
      this.committedMessages.set(id,snapshot.messages);
      this.committedCursors.set(id,snapshot.cursor);
      const storedEvents=await this.local.events(id);
      if (ticket === this.generation) {
        this.state.events = storedEvents;
        if (!this.state.stopping) { this.setMessages(snapshot.messages); this.state.runId = snapshot.active_run?.id || ''; }
        for(const message of snapshot.messages) if(/\[[ xX]\]/.test(message.content)) this.loadTasks(message.id);
      }
      this.state.online = true;
    } catch (error) { this.state.online = false; }
    finally { this.polling = false; }
  }
  private scheduleFlush(): void {
    if (this.flushTimer >= 0) return;
    // A bounded 12 ms coalescing window; actual device frame timing remains measured separately.
    this.flushTimer = setTimeout(() => { this.flushTimer = -1; this.flushEvents(); },12);
  }
  private async flushEvents(): Promise<void> {
    if (this.flushing || this.polling) { this.scheduleFlush(); return; }
    if (this.eventQueue.length === 0) return;
    this.flushing = true;
    const id = this.state.activeId;
    const ticket = this.generation;
    const received = this.eventQueue;
    this.eventQueue = [];
    try {
      if (received.some((event: StreamEvent) => event.kind === 'message_created' || event.kind==='reminder' || event.layer === 'L4' ||
        (event.kind === 'reply_delta' && !this.state.messages.some((message: Message) => message.id === event.payload.message_id)))) {
        await this.synchronize(true);
        if(!this.state.online) throw new Error('这一页尚未补齐。');
      }
      const cursor = this.committedCursors.get(id) ?? await this.local.cursor(id);
      const sorted = received.filter((event: StreamEvent) => event.seq > cursor && event.conversation_id === id)
        .sort((a: StreamEvent,b: StreamEvent) => a.seq-b.seq);
      const batch:StreamEvent[]=[];
      let previous=cursor;
      for(const event of sorted) { if(event.seq>previous) { batch.push(event); previous=event.seq; } }
      if (batch.length === 0 || ticket !== this.generation) return;
      const committed = this.committedMessages.get(id) || await this.local.messages(id);
      if (ticket!==this.generation) return;
      const messages = committed.map((message: Message): Message => {
        return { id:message.id,conversation_id:message.conversation_id,role:message.role,content:message.content,
          status:message.status,created_at:message.created_at,attachments:message.attachments };
      });
      for (const event of batch) {
        const message = messages.find((item: Message) => item.id === event.payload.message_id);
        if (event.kind === 'reply_delta') {
          if (!message) throw new Error('这一页尚未补齐。');
          message.content += event.payload.text || '';
        }
        if (event.kind === 'run_started' && message) message.status = 'streaming';
        if (event.kind === 'run_finished' || event.kind === 'run_failed' || event.kind === 'run_stopped') {
          if (message) message.status = event.payload.status || 'completed';
        }
      }
      await this.local.saveSnapshot(id,messages,batch,batch[batch.length-1].seq);
      // Cache only after the transaction acknowledges; this is separate from the
      // frozen UI transcript during Stop and avoids reading SQL on each frame.
      this.committedMessages.set(id,messages);
      this.committedCursors.set(id,batch[batch.length-1].seq);
      if (ticket === this.generation) {
        for (const event of batch) {
          if(event.kind==='run_started') this.state.runId=event.run_id;
          if(event.kind==='run_finished'||event.kind==='run_failed'||event.kind==='run_stopped') {
            if(this.state.runId===event.run_id) this.state.runId='';
            if(event.payload.message) this.state.notice=event.payload.message;
            if(event.kind==='run_finished') this.onCue('reply');
            if(event.payload.message_id) this.loadTasks(event.payload.message_id);
          }
          if(event.kind==='widget_updated' && event.payload.message_id) this.loadTasks(event.payload.message_id);
          if(event.kind==='pins_changed') this.loadPins();
          if(event.kind==='tone_changed' || event.kind==='context_compacted')this.refreshComposer(id).catch(()=>{});
        }
        this.state.events = this.state.events.concat(batch);
        if(this.state.previewStorage) console.info('HajiSaki preview SSE committed='+batch[batch.length-1].seq+', run_active='+Boolean(this.state.runId));
        if (!this.state.stopping) this.setMessages(messages);
        if (!this.state.runId && this.state.queued > 0) this.drain();
      }
    } catch (error) {
      this.stream.close(); this.streamId = ''; this.state.online = false;
      this.eventQueue=[];
      // Reconnect from the last committed cursor; never acknowledge an uncommitted batch.
    } finally {
      this.flushing = false;
      if (this.eventQueue.length > 0) this.scheduleFlush();
    }
  }
  private async ensureStream(): Promise<void> {
    if (this.streamId || !this.state.activeId || !this.state.online || !this.gateway.isConfigured() || !this.gateway.canStreamDirectly()) return;
    const id = this.state.activeId;
    this.streamId = id;
    try {
      const cursor = this.committedCursors.get(id) ?? await this.local.cursor(id);
      if (id === this.state.activeId && this.streamId === id) this.stream.open(this.gateway,id,cursor);
    } catch (error) { this.streamId = ''; }
  }
  startPolling(): void {
    this.ensureStream();
    if (this.pollTimer >= 0) return;
    // REST replay remains the recovery path. A healthy SSE stream causes no polling requests.
    this.pollTimer = setInterval(() => {
      if(this.gateway.isRelayUpdating()) return;
      if (!this.streamId) this.synchronize().then(async () => {
        if (this.state.pending.some((item:PendingMessage)=>!item.last_error)) await this.drain();
        this.ensureStream();
      });
      else if (!this.state.runId && this.state.pending.some((item:PendingMessage)=>!item.last_error)) this.drain();
    },1000);
  }
  suspend(): void {
    if (this.pollTimer >= 0) clearInterval(this.pollTimer);
    this.pollTimer = -1;
    this.stream.close(); this.streamId = ''; this.eventQueue = [];
    if (this.flushTimer >= 0) clearTimeout(this.flushTimer); this.flushTimer = -1;
    const active = this.state.conversations.find((item: Conversation) => item.id === this.state.activeId);
    if (this.state.group === '私密保险箱' || active?.group === '私密保险箱') {
      this.state.group = '全部'; this.state.page = 'hub'; this.state.activeId = '';
      this.state.draft = ''; this.state.events = []; this.setMessages([]); this.generation++;
    }
  }
  async resume(): Promise<void> { if (this.gateway.isConfigured()) { await this.refresh(); await this.drain(); this.startPolling(); this.prefetchHistory(); } }
  async archive(item: Conversation): Promise<void> {
    try { const changed = await this.gateway.request<Conversation>('/api/conversations/' + encodeURIComponent(item.id) + '/update',http.RequestMethod.POST,
      JSON.stringify({ archived: true })); await this.local.saveConversations([changed]); await this.refresh(); } catch (error) { this.fail(error); }
  }
  async pin(item: Conversation): Promise<void> {
    try { await this.gateway.request<Conversation>('/api/conversations/' + encodeURIComponent(item.id) + '/update',http.RequestMethod.POST,
      JSON.stringify({ pinned: !item.pinned })); await this.refresh(); } catch (error) { this.fail(error); }
  }
  async fork(message: Message): Promise<void> {
    try {
      const fork = await this.gateway.request<Conversation>('/api/conversations/' + encodeURIComponent(message.conversation_id) + '/fork',
        http.RequestMethod.POST,JSON.stringify({ message_id: message.id, title: this.state.activeTitle + ' · 另一页' }));
      await this.local.saveConversations([fork]); await this.refresh(); await this.open(fork);
    } catch (error) { this.fail(error); }
  }
  async loadMemories(navigate: boolean = true): Promise<void> {
    if(navigate) this.state.page = 'memory';
    const revision=++this.memoryRevision;
    if (!this.gateway.isConfigured()) return;
    try {
      const result = await this.gateway.request<MemoryPage>('/api/memories');
      if(revision!==this.memoryRevision) return;
      this.state.memories = result.memories;
      await this.local.put('snapshot','memories',JSON.stringify(result.memories));
    } catch (error) { this.fail(error); }
  }
  async saveMemory(content: string, id: string = ''): Promise<boolean> {
    if (!content.trim()) return false;
    try {
      await this.gateway.request<Memory>(id ? '/api/memories/' + encodeURIComponent(id) + '/update' : '/api/memories',
        http.RequestMethod.POST,JSON.stringify({ content: content.trim() }));
      await this.loadMemories(false);
      return true;
    } catch (error) { this.fail(error); return false; }
  }
  async recycleMemory(id: string): Promise<void> {
    this.memoryRevision++;
    try {
      await this.gateway.request<Record<string,string>>('/api/memories/' + encodeURIComponent(id),http.RequestMethod.DELETE);
      this.memoryRevision++;
      this.state.memories=this.state.memories.filter((memory:Memory) => memory.id!==id);
      await this.local.put('snapshot','memories',JSON.stringify(this.state.memories));
      // Retain a tombstone, rather than silently resurrecting the cached memory offline.
      await this.local.put('memory',id,JSON.stringify({ id: id, content: '', created_at: '', updated_at: new Date().toISOString() }));
      await this.loadMemories(false);
    } catch (error) { this.fail(error); }
  }
  async saveSettings(settings: Settings): Promise<void> {
    try {
      this.state.settings = settings;
      await this.local.put('config','settings',JSON.stringify(settings));
      await this.local.put('config','settings_pending','true');
      if (!this.gateway.isConfigured()) return;
      await this.gateway.request<Settings>('/api/settings/update',http.RequestMethod.POST,JSON.stringify(settings));
      await this.local.put('config','settings_pending','false');
    } catch (error) { this.fail(error); }
  }
  async loadArtifacts(): Promise<void> {
    this.state.page = 'vault';
    if (!this.gateway.isConfigured()) return;
    try {
      const result = await this.gateway.request<ArtifactPage>('/api/artifacts'); this.state.artifacts = result.artifacts;
      for (const file of result.artifacts) await this.local.put('artifact',file.id,JSON.stringify(file));
    } catch (error) { this.fail(error); }
  }
  async attach(file: Artifact, conversation: string = this.state.activeId): Promise<void> {
    const selected = conversation===this.state.activeId ? this.state.selectedAttachments :
      JSON.parse(await this.local.get('draft_attachments',conversation,'[]')) as Artifact[];
    const next=selected.filter((item:Artifact) => item.id!==file.id).concat([file]);
    await this.local.put('draft_attachments',conversation,JSON.stringify(next));
    if (conversation===this.state.activeId) this.state.selectedAttachments = next;
    await this.local.put('artifact',file.id,JSON.stringify(file));
  }
  async detach(id: string): Promise<void> {
    this.state.selectedAttachments=this.state.selectedAttachments.filter((file:Artifact) => file.id!==id);
    await this.local.put('draft_attachments',this.state.activeId,JSON.stringify(this.state.selectedAttachments));
  }
  tasksFor(id:string,pages:MessageTasks[]):TaskPage {
    return pages.find((item:MessageTasks) => item.message_id===id)?.page || {tasks:{},items:[],editable:false};
  }
  private publishTasks(id:string,page:TaskPage):void {
    this.state.taskPages=this.state.taskPages.filter((item:MessageTasks) => item.message_id!==id).concat([{message_id:id,page:page}]);
  }
  async loadTasks(id:string):Promise<void> {
    const ticket=this.generation;
    try {
      const page=this.gateway.isConfigured() ? await this.gateway.request<TaskPage>('/api/messages/'+encodeURIComponent(id)+'/tasks') :
        JSON.parse(await this.local.get('tasks',id,'{"tasks":{},"items":[],"editable":false}')) as TaskPage;
      await this.local.put('tasks',id,JSON.stringify(page));
      if(ticket===this.generation) this.publishTasks(id,page);
    } catch(error) {}
  }
  async toggleTask(id:string,index:number,checked:boolean):Promise<boolean> {
    const ticket=this.generation;
    try {
      const page=await this.gateway.request<TaskPage>('/api/messages/'+encodeURIComponent(id)+'/tasks/'+index+'/update',
        http.RequestMethod.POST,JSON.stringify({checked:checked}));
      await this.local.put('tasks',id,JSON.stringify(page));
      if(ticket===this.generation) this.publishTasks(id,page);
      return true;
    } catch(error) { this.fail(error); return false; }
  }
  async loadPins():Promise<void> {
    const id=this.state.activeId; const ticket=this.generation;
    if(!id||!this.gateway.isConfigured()) return;
    try {
      const result=await this.gateway.request<PinPage>('/api/conversations/'+encodeURIComponent(id)+'/pins');
      await this.local.put('pins',id,JSON.stringify(result.pins));
      if(ticket===this.generation) this.state.pins=result.pins;
    } catch(error) { this.fail(error); }
  }
  async pinContext(kind:string,target:string):Promise<void> {
    if(!this.state.activeId) return;
    try {
      await this.gateway.request<ContextPin>('/api/conversations/'+encodeURIComponent(this.state.activeId)+'/pins',
        http.RequestMethod.POST,JSON.stringify({kind:kind,target_id:target,content:''}));
      await this.loadPins();
    } catch(error) { this.fail(error); }
  }
  async unpinContext(id:string):Promise<void> {
    try { await this.gateway.request<Record<string,string>>('/api/pins/'+encodeURIComponent(id),http.RequestMethod.DELETE); await this.loadPins(); }
    catch(error) { this.fail(error); }
  }
  read(message: Message): void {
    this.state.readingText = message.content; this.state.readingMessageId=message.id;
    this.state.readingTitle = this.state.activeTitle; this.state.page = 'reader';
  }
}
