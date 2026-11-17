import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { pasteboard } from '@kit.BasicServicesKit';
import { SymbolGlyphModifier, LengthMetrics } from '@kit.ArkUI';
import { Artifact, ContextPin, Conversation, Memory, Message, PendingMessage, Settings, StreamEvent } from '../model/Types';
import { ClientState } from '../model/ClientState';
import { MessagePart } from '../model/MessageParts';
import { MessageRow } from '../components/MessageRow';
import { ReminderRoom } from '../components/ReminderRoom';
import { SpeechRoom } from '../components/SpeechRoom';
import { ArtifactRoom, readableArtifact } from '../components/ArtifactRoom';
import { RelayRoom } from '../components/RelayRoom';
import { StudioRoom } from '../components/StudioRoom';
import { PicturePreview } from '../components/PicturePreview';
import { ImageRoom } from '../components/ImageRoom';
import { ReferenceRoom } from '../components/ReferenceRoom';
import { CommandRoom } from '../components/CommandRoom';
import { SelectionRoom } from '../components/SelectionRoom';
import { BranchRoom } from '../components/BranchRoom';
import { ArenaRoom } from '../components/ArenaRoom';
import { ModelPicker } from '../components/ModelPicker';
import { ArenaSide, ArenaChoice, BranchOrigin } from '../model/BranchTypes';
import { CompactionRecord } from '../model/CommandTypes';
import { isPicture } from '../services/ImagePreviews';
import { PictureSource } from '../model/PictureSource';
import { Palette, palette } from '../design/Theme';
import { Companion } from '../services/Companion';
import { NativeFiles, NativeFileError } from '../platform/NativeFiles';
import { NativeRecorder } from '../platform/NativeRecorder';
import { authenticate } from '../platform/Biometrics';
import { Sensory, SensoryCue, SensoryPulse } from '../platform/Sensory';
import { Manuscript } from '../components/Manuscript';

interface ReadingAnchor { locked:boolean; index:number; top:number }

@Entry
@Component
struct Index {
  @State state: ClientState = new ClientState();
  @State primary: string = '';
  @State fallback: string = '';
  @State device: string = '';
  @State token: string = '';
  @State revealToken: boolean = false;
  @State memoryDraft: string = '';
  @State memoryId: string = '';
  @State readingLock: boolean = false;
  @State newContent: boolean = false;
  @State formality: number = 60;
  @State detail: number = 50;
  @State teasing: number = 25;
  @State wide: boolean = false;
  @State compact: boolean = false;
  @State speechArtifact: Artifact | undefined = undefined;
  @State viewedArtifact: Artifact | undefined = undefined;
  @State artifactOpen:boolean=false;
  @State savingArtifactId: string = '';
  @State wallClock: number = Date.now();
  @State responseGlow: boolean = false;
  @State studioArtifact: Artifact | undefined = undefined;
  @State studioSession: string = '';
  @State viewedImage:Artifact | undefined=undefined;
  @State imagePage:number=-1;
  @State imageOpen:boolean=false;
  @State imageEditing:boolean=false;
  @State imageAsking:boolean=false;
  @State galleryMode:boolean=false;
  @State referencesOpen:boolean=false;
  @State referenceQuery:string='';
  @State commandsOpen:boolean=false;
  @State commandQuery:string='';
  @State selectionOpen:boolean=false;
  @State selectionMessage:string='';
  @State branchesOpen:boolean=false;
  @State branchTab:string='threads';
  @State arenaOpen:boolean=false;
  @State arenaId:string='';
  @StorageLink('foreground') @Watch('foregroundChanged') foreground: boolean = true;
  private client: Companion = new Companion(this.state);
  private recorder: NativeRecorder = new NativeRecorder();
  private files?: NativeFiles;
  private sensory?: Sensory;
  private scroll: Scroller = new Scroller();
  private utilityReturnPage:string='memory';
  private speechReturnedText:string='';
  private returnAfterConnect:string='';
  private clockTimer:number=-1;
  private responseTimer:number=-1;
  private openedAt:number=Date.now();
  private studioConversation:string='';
  private studioReturnPage:string='hub';
  private chatFirstIndex:number=0;
  private studioAnchor:ReadingAnchor={locked:false,index:0,top:0};
  private readerAnchor:ReadingAnchor={locked:false,index:0,top:0};
  private pendingAnchor:ReadingAnchor | undefined=undefined;
  private processScroll:Scroller=new Scroller();
  private referenceConversation:string='';
  private referenceDraft:string='';
  private referencePrefix:string='';
  private suppressedReferenceDraft:string='';
  private commandConversation:string='';
  private commandDraft:string='';
  private commandPrefix:string='';
  private suppressedCommandDraft:string='';
  private commandGeneration:number=0;
  private selectionConversation:string='';
  private branchConversation:string='';
  private branchDraft:string='';
  private branchFiles:Artifact[]=[];
  private branchAnchors:Map<string,ReadingAnchor>=new Map();
  private branchModels:Map<string,ArenaChoice>=new Map();

  private openSelection(message:Message):void {
    this.branchModels.set(this.state.activeId,{model:this.state.model,effort:this.state.effort});
    this.selectionConversation=message.conversation_id;this.selectionMessage=message.id;this.selectionOpen=true;
  }
  private closeSelection():void {this.selectionOpen=false;this.focusComposer();}
  private readOriginQuote():void {
    const thread=this.state.branchOrigin.thread;if(!thread)return;
    this.readerAnchor=this.captureReading();this.state.readingText=thread.quote;this.state.readingMessageId='';
    this.state.readingTitle='附页原句';this.state.page='reader';
  }
  private async quoteSelection(text:string):Promise<void> {
    if(this.state.activeId!==this.selectionConversation)throw new Error('乐章已经换过，请重新选一句。');
    await this.client.draftChanged('> '+text.split('\n').join('\n> ')+'\n\n'+this.state.draft);
    this.closeSelection();
  }
  private async enterThread(item:Conversation):Promise<void> {
    if(this.state.activeId!==this.selectionConversation)return;
    this.branchAnchors.set(this.state.activeId,this.captureReading());
    this.selectionOpen=false;this.readingLock=false;
    await this.client.open(item);
  }
  private openBranches(tab:string='threads'):void {
    if(!this.state.activeId)return;
    this.branchConversation=this.state.activeId;this.branchDraft=this.state.draft;this.branchFiles=this.state.selectedAttachments.slice();
    this.branchAnchors.set(this.state.activeId,this.captureReading());
    this.branchTab=tab;this.branchesOpen=true;
    this.branchModels.set(this.state.activeId,{model:this.state.model,effort:this.state.effort});
  }
  private async enterKnownThread(id:string):Promise<void> {
    if(this.state.activeId!==this.branchConversation)return;
    const item=await this.client.knownConversation(id);
    if(!this.branchesOpen || this.state.activeId!==this.branchConversation)return;
    this.branchesOpen=false;this.readingLock=false;
    await this.client.open(item);
  }
  private openArena(id:string):void {this.branchesOpen=false;this.arenaId=id;this.arenaOpen=true;}
  private closeArena():void {
    this.arenaOpen=false;this.branchTab='arenas';
    if(this.state.activeId!==this.branchConversation) {
      this.returnToParent().then(()=>{
        if(this.state.activeId===this.branchConversation){this.branchDraft=this.state.draft;this.branchFiles=this.state.selectedAttachments.slice();this.branchesOpen=true;}
      });
    } else this.branchesOpen=true;
  }
  private async continueArena(side:ArenaSide,parent:string):Promise<void> {
    const item=await this.client.knownConversation(side.conversation_id);
    if(!this.arenaOpen)return;
    const origin:BranchOrigin={thread:null,arena:{arena_id:this.arenaId,side:side.side,parent_id:parent}};
    await this.client.local.put('branch-origin',side.conversation_id,JSON.stringify(origin));
    this.arenaOpen=false;this.readingLock=false;
    if(side.model)this.state.model=side.model;
    if(side.effort)this.state.effort=side.effort;
    await this.client.open(item);
  }
  private async returnToParent():Promise<void> {
    const origin=this.state.branchOrigin;
    const parent=origin.thread?.parent_id || origin.arena?.parent_id;
    if(!parent)return;
    const source=origin.thread?.source_message_id || '';
    this.readingLock=true;
    try {
      await this.client.openKnown(parent);
      const model=this.branchModels.get(parent);
      if(model){this.state.model=model.model;this.state.effort=model.effort;}
      const saved=this.branchAnchors.get(parent);
      const index=this.client.messageSource.indexOfMessage(source);
      this.pendingAnchor=saved || {locked:index>=0,index:Math.max(0,index),top:0};
      setTimeout(()=>this.restoreStudioPosition(),30);
    } catch (_) {this.readingLock=false;this.state.notice='原乐章暂时没有取回，这一页的草稿仍在。';}
  }
  private returnToArena():void {
    const origin=this.state.branchOrigin.arena;if(!origin)return;
    this.branchConversation=origin.parent_id;this.branchDraft='';this.branchFiles=[];
    this.arenaId=origin.arena_id;this.arenaOpen=true;
  }

  private openReferences(query:string='',typed:boolean=false):void {
    if(!this.state.activeId || this.commandsOpen)return;
    this.referenceConversation=this.state.activeId;this.referenceQuery=query;
    this.referenceDraft=typed?this.state.draft:'';
    this.referencePrefix=typed?this.state.draft.substring(0,this.state.draft.length-query.length-1):'';
    this.referencesOpen=true;
  }
  private closeReferences():void {this.suppressedReferenceDraft=this.state.draft;this.referencesOpen=false;this.focusComposer();}
  private focusComposer():void {
    setTimeout(()=>{if(this.state.page==='chat' && !this.referencesOpen && !this.commandsOpen && !this.artifactOpen && !this.imageOpen && !this.selectionOpen && !this.branchesOpen && !this.arenaOpen) {
      try {this.getUIContext().getFocusController().requestFocus('composer-draft');} catch (_) { /* The draft remains available if the page is leaving. */ }
    }},30);
  }
  private draftUpdated(value:string):void {
    this.client.draftChanged(value);
    if(this.referencesOpen || this.commandsOpen || value===this.suppressedReferenceDraft || value===this.suppressedCommandDraft)return;
    this.suppressedReferenceDraft='';
    this.suppressedCommandDraft='';
    const match=/(^|\s)@([^\s@]{0,120})$/.exec(value);
    if(match){this.openReferences(match[2],true);return;}
    const command=/(^|\s)\/([A-Za-z\u4e00-\u9fff]{0,32})$/.exec(value);
    if(command)this.openCommands(command[2],true);
  }
  private async useReference(file:Artifact):Promise<void> {
    const conversation=this.referenceConversation,draft=this.referenceDraft;
    await this.client.attach(file,conversation);
    if(this.referencesOpen && conversation===this.state.activeId && draft && this.state.draft===draft)
      this.client.draftChanged(this.referencePrefix);
    this.referencesOpen=false;this.focusComposer();
  }
  private openCommands(query:string='',typed:boolean=false):void {
    if(!this.state.activeId || this.referencesOpen)return;
    this.commandGeneration++;this.commandConversation=this.state.activeId;this.commandQuery=query;
    this.commandDraft=typed?this.state.draft:'';
    this.commandPrefix=typed?this.state.draft.substring(0,this.state.draft.length-query.length-1):'';
    this.commandsOpen=true;
  }
  private closeCommands():void {
    this.commandGeneration++;this.suppressedCommandDraft=this.state.draft;
    this.commandsOpen=false;this.focusComposer();
  }
  private async useTemplate(conversation:string,generation:number,text:string):Promise<void> {
    if(conversation!==this.state.activeId || generation!==this.commandGeneration)throw new Error('这一页乐章已经换过，请重新选择起笔。');
    const draft=this.commandDraft && this.state.draft===this.commandDraft?this.commandPrefix:this.state.draft;
    await this.client.draftChanged(draft+(draft && !/\s$/.test(draft)?'\n\n':'')+text);
    if(generation===this.commandGeneration)this.closeCommands();
  }
  private async compactContext(conversation:string,generation:number,operation:string,model:string,effort:string):Promise<void> {
    const draft=generation===this.commandGeneration?this.commandDraft:'',prefix=this.commandPrefix;
    await this.client.compact(conversation,operation,model,effort);
    if(generation===this.commandGeneration && conversation===this.state.activeId) {
      if(draft && this.state.draft===draft)await this.client.draftChanged(prefix);
      this.closeCommands();
    }
  }
  private openCommandSummary(record:CompactionRecord):void {
    this.readerAnchor=this.captureReading();this.closeCommands();
    this.state.readingText=record.summary;this.state.readingMessageId=record.assistant_message_id;
    this.state.readingTitle=this.state.activeTitle;this.state.page='reader';
  }
  private pictures:PictureSource=new PictureSource();

  private captureReading():ReadingAnchor {
    const result:ReadingAnchor={locked:this.state.page==='chat' && !this.state.showProcess && this.readingLock,index:this.chatFirstIndex,top:0};
    if(result.locked) {try {result.top=this.scroll.getItemRect(result.index).y;} catch (_) { /* Keep the visible item anchor. */ }}
    return result;
  }
  private readMessage(message:Message):void {
    this.readerAnchor=this.captureReading();
    this.client.read(message);
  }
  private closeReader():void {
    this.pendingAnchor=this.readerAnchor;
    this.state.page='chat';
  }
  private openImage(file:Artifact,page:number=-1):void {
    this.viewedImage=file;this.imagePage=page;this.imageEditing=false;this.imageOpen=true;
  }
  private closeImage():void {this.imageOpen=false;}
  private async askImage():Promise<void> {
    const file=this.viewedImage;
    if(!file || this.imageAsking)return;
    this.imageAsking=true;
    try {
      let conversation=this.state.activeId;
      if(!conversation) {
        const created=await this.client.create(false);conversation=created?.id || '';
        if(!conversation)throw new Error('先接回琴房，再把这张图放进新乐章。');
      }
      await this.client.attach(file,conversation);
      if(this.state.page!=='chat' || this.state.showProcess)this.pendingAnchor={locked:false,index:0,top:0};
      this.state.showProcess=false;this.imageEditing=false;this.imageOpen=false;this.state.page='chat';
    } catch (_) {this.state.notice='这张图暂时没能放回乐章，原件仍在档案里。';}
    finally {this.imageAsking=false;}
  }
  private annotateImage():void {
    this.studioAnchor=this.captureReading();this.studioConversation=this.state.activeId;
    this.studioArtifact=this.viewedImage;this.studioSession=String(Date.now())+':'+this.viewedImage?.id;
    this.imageEditing=true;
  }
  private async openVault():Promise<void> {
    this.pictures.replace(this.state.artifacts);
    await this.client.loadArtifacts();this.pictures.replace(this.state.artifacts);
  }
  private async importPicture():Promise<void> {
    if(!this.files || this.state.uploadProgress)return;
    try {
      this.state.uploadProgress='正在整理…';
      const file=await this.files.uploadPicked((done:number,total:number)=>{this.state.uploadProgress=total?Math.floor(done/total*100)+'%':'正在整理…';});
      if(file && this.state.page==='vault') {
        await this.openVault();
        if(isPicture(file))this.openImage(file);
        else this.state.notice='原件已收进全部文件，这一份不是图片。';
      }
    } catch (_) {this.state.notice='这份图片暂时没能收进档案，原文件仍在。';}
    finally {this.state.uploadProgress='';}
  }

  private openStudio(file?:Artifact):void {
    this.studioReturnPage=this.state.page;
    this.studioAnchor=this.captureReading();
    this.studioConversation=this.state.page==='chat'||file!==undefined?this.state.activeId:'';
    this.studioArtifact=file;this.studioSession=String(Date.now())+':'+(file?.id||'paper');this.state.page='studio';
  }
  private async useStudio(file:Artifact):Promise<void> {
    const stayingInChat=this.state.page==='chat';
    let conversation=this.studioConversation;
    if(!conversation) {
      const created=await this.client.create(false);
      conversation=created?.id || '';
      if(!conversation) throw new Error('画页已收进档案，先接回琴房，再放回对话。');
    }
    await this.client.attach(file,conversation);
    if(this.state.activeId!==conversation) {
      const item=this.state.conversations.find((item:Conversation)=>item.id===conversation);
      if(item) await this.client.open(item,false);
    }
    this.pendingAnchor=this.studioAnchor;
    this.imageEditing=false;this.imageOpen=false;
    this.state.page='chat';
    if(stayingInChat)this.restoreStudioPosition();
  }
  private closeStudio():void {
    if(this.imageEditing){this.imageEditing=false;return;}
    if(this.studioReturnPage==='chat')this.pendingAnchor=this.studioAnchor;
    this.state.page=this.studioReturnPage;
  }
  private connectStudio():void {
    if(this.imageEditing){this.studioReturnPage=this.state.page;this.imageEditing=false;this.imageOpen=false;}
    this.returnAfterConnect='studio';this.state.page='host';
  }
  private restoreStudioPosition():void {
    const anchor=this.pendingAnchor;if(!anchor)return;
    this.pendingAnchor=undefined;this.readingLock=anchor.locked;
    if(anchor.locked)this.scroll.scrollToIndex(anchor.index,false,ScrollAlign.START,
      {extraOffset:LengthMetrics.vp(-anchor.top)});
    else this.scroll.scrollEdge(Edge.Bottom);
  }

  aboutToAppear(): void {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    this.files = new NativeFiles(context,this.client.gateway);
    this.sensory = new Sensory(context);
    this.startClock();
    this.client.onCue = (cue:'send'|'reply') => {
      this.effect(cue);
      if(cue==='reply') {
        this.pulse('complete'); this.responseGlow=true;
        if(this.responseTimer>=0) clearTimeout(this.responseTimer);
        this.responseTimer=setTimeout(()=>{this.responseGlow=false;},2400);
      }
    };
    this.recorder.onState = (value: string) => { this.state.recordingState = value; };
    this.client.onMessages = () => {
      if (this.readingLock) { this.newContent = true; return; }
      if (this.state.page === 'chat') this.scroll.scrollEdge(Edge.Bottom);
    };
    this.client.initialize(context).then(() => {
      this.primary = this.state.connection.primary; this.fallback = this.state.connection.fallback;
      this.device = this.state.connection.device;
      this.formality = this.state.settings.personality.formality;
      this.detail = this.state.settings.personality.detail;
      this.teasing = this.state.settings.personality.teasing;
      this.applySystemTheme();
    });
  }
  aboutToDisappear(): void {
    this.client.suspend(); this.recorder.release(); this.sensory?.release();
    if(this.clockTimer>=0) clearInterval(this.clockTimer);
    if(this.responseTimer>=0) clearTimeout(this.responseTimer);
  }
  private startClock():void {
    this.wallClock=Date.now();
    if(this.clockTimer>=0) return;
    this.clockTimer=setInterval(()=>{this.wallClock=Date.now();if(this.state.settings.theme==='auto')this.applySystemTheme();},60000);
  }
  private foregroundChanged(): void {
    if (!this.state.ready) return;
    if (this.foreground) { this.startClock(); this.client.resume(); }
    else {
      const active=this.state.conversations.find((item:Conversation)=>item.id===this.state.activeId);
      if(this.state.group==='私密保险箱' || active?.group==='私密保险箱'){this.selectionOpen=false;this.branchesOpen=false;this.arenaOpen=false;}
      this.client.suspend(); if(this.clockTimer>=0) clearInterval(this.clockTimer); this.clockTimer=-1;
    }
  }
  private colors(): Palette { return palette(this.state.settings.theme,this.wallClock); }
  private selectArrow():SymbolGlyphModifier {
    const modifier=new SymbolGlyphModifier(); modifier.fontColor([this.colors().secondary]); return modifier;
  }
  private greeting(): string {
    const hour = new Date(this.wallClock).getHours();
    return hour < 6 ? '夜已经很深了。\n我还在这里。' : hour < 12 ? '早安。\n今天，也一起吧。' : hour < 19 ? '午后的琴房，\n留了一页给你。' : '今夜的乐章，\n慢慢说给我听。';
  }
  private avatar(): Resource {
    if (this.state.recordingState === 'recording') return $r('app.media.listening_attentive');
    if (this.state.runId) {
      if(this.state.conversations.find((item:Conversation)=>item.id===this.state.activeId)?.group==='研发工坊') return $r('app.media.coding_focused');
      return $r('app.media.thinking_deep');
    }
    if(this.responseGlow) return $r('app.media.happy_achieved');
    if (!this.state.online && this.client.gateway.isConfigured()) return $r('app.media.reconnecting_anxious');
    const hour=new Date(this.wallClock).getHours();
    if(hour>=3&&hour<6) return $r('app.media.sleepy_soft');
    if((hour>=23||hour<3)&&this.state.settings.personality.teasing>=70&&this.wallClock-this.openedAt>2700000) return $r('app.media.tsundere_chide');
    if (hour >= 23 || hour < 6) return $r('app.media.late_night_tea');
    return $r('app.media.idle_gentle');
  }
  private selectGroup(group: string): void {
    if (group === '私密保险箱') {
      authenticate('打开私密保险箱').then((success: boolean) => { if (success) this.state.group = group; });
    } else this.state.group = group;
  }
  private async upload(): Promise<void> {
    if (!this.files || this.state.uploadProgress) return;
    const conversation=this.state.activeId;
    try {
      this.state.uploadProgress = '正在整理…';
      const file = await this.files.uploadPicked((done: number,total: number) => {
        this.state.uploadProgress = total > 0 ? Math.floor(done / total * 100) + '%' : '正在整理…';
      });
      if (file) await this.client.attach(file,conversation);
    } catch (error) { this.state.notice = '这份附件还没送达，请保留原文件，再试一次。'; }
    finally { this.state.uploadProgress = ''; }
  }
  private async record(): Promise<void> {
    try {
      if (this.state.recordingState === 'recording' || this.state.recordingState === 'paused') {
        this.state.recordingPath = await this.recorder.stop();
      } else {
        const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
        await this.recorder.start(context);
        this.pulse('record');
      }
      if(this.recorder.currentPath) await this.client.local.put('speech','recorded_path',this.recorder.currentPath);
    } catch (error) { this.state.notice = '还没能收下你的声音。请检查麦克风权限，文字也一直等着你。'; }
  }
  private async attachRecording(): Promise<void> {
    if (!this.files || !this.state.recordingPath) return;
    const conversation=this.state.activeId;
    try {
      const file = await this.files.uploadUri(this.state.recordingPath,'琴房录音.aac','audio/aac',
        (done: number,total: number) => { this.state.uploadProgress = Math.floor(done / Math.max(total,1) * 100) + '%'; });
      await this.client.attach(file,conversation); this.state.recordingPath = '';
    } catch (error) { this.state.notice = '声音已留在手机里，连回琴房后还可以再送一次。'; }
    finally { this.state.uploadProgress = ''; }
  }
  private async copy(text: string): Promise<void> {
    try { await pasteboard.getSystemPasteboard().setData(pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN,text)); this.pulse('copy'); }
    catch (error) { this.state.notice = '剪贴板还没收好，可以先长按这段文字复制。'; }
  }
  private async pauseRecording(): Promise<void> {
    try { if (this.state.recordingState === 'paused') await this.recorder.resume(); else await this.recorder.pause(); }
    catch (error) { this.state.notice = '录音暂时停在这里，先把这一段收好吧。'; }
  }
  private effect(cue: SensoryCue): void {
    if(this.sensory) { this.sensory.enabled=this.state.settings.sound; this.sensory.play(cue).catch(() => {}); }
  }
  private pulse(kind: SensoryPulse): void {
    if(this.sensory) { this.sensory.enabled=this.state.settings.sound; this.sensory.pulse(kind).catch(() => {}); }
  }
  private changeSound(enabled: boolean): void {
    const settings:Settings={theme:this.state.settings.theme,transparency:this.state.settings.transparency,
      personality:this.state.settings.personality,sound:enabled};
    this.client.saveSettings(settings);
    if(this.sensory) this.sensory.enabled=enabled;
  }
  private changeTheme(value: string): void {
    const settings: Settings = { theme: value, transparency: this.state.settings.transparency,
      personality: this.state.settings.personality, sound: this.state.settings.sound };
    this.client.saveSettings(settings);
    this.applySystemTheme();
  }
  private applySystemTheme(): void {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      context.getApplicationContext().setColorMode(this.colors().light ?
        ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT : ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (_) {}
  }
  private changeTransparency(value: string): void {
    const settings: Settings = { theme: this.state.settings.theme, transparency: value,
      personality: this.state.settings.personality, sound: this.state.settings.sound };
    this.client.saveSettings(settings);
  }
  private savePersonality(): void {
    const settings: Settings = { theme: this.state.settings.theme, transparency: this.state.settings.transparency,
      personality: { formality: this.formality, detail: this.detail, teasing: this.teasing }, sound: this.state.settings.sound };
    this.client.saveSettings(settings);
  }
  private fileIcon(file: Artifact): Resource {
    if (/zip|7z|tar|rar/.test(file.name)) return $r('app.media.icon_archive');
    if (/\.(py|ts|js|ets|cpp|rs|go)$/.test(file.name)) return $r('app.media.icon_code');
    return $r('app.media.icon_document');
  }
  private formatSize(value: number): string {
    return value > 1073741824 ? (value/1073741824).toFixed(1) + ' GB' : value > 1048576 ? (value/1048576).toFixed(1) + ' MB' : (value/1024).toFixed(1) + ' KB';
  }
  private eventText(event: StreamEvent): string {
    if(event.kind==='visual_input') return '这张画面已随消息提交。';
    if(event.kind==='image_tool_read') {
      const page=event.payload.page===undefined?'附件':'第'+(event.payload.page+1)+'页';
      const size=event.payload.width && event.payload.height?' · '+event.payload.width+' × '+event.payload.height:'';
      return '工具已返回'+page+'画面'+size+'。';
    }
    return event.payload.text || event.payload.summary || event.payload.name || event.kind;
  }
  private pinLabel(pin:ContextPin):string { return (pin.source?.name||pin.source?.content||pin.content||'上下文锚点').substring(0,30); }
  private openReminders():void { this.utilityReturnPage=this.state.page; this.state.page='reminders'; }
  private openArtifact(file:Artifact):void { this.viewedArtifact=file; this.artifactOpen=true; }
  private async openSpeech(artifact?:Artifact):Promise<void> {
    if(this.state.recordingState==='recording'||this.state.recordingState==='paused') {
      this.state.notice='先把这一段原音收好，再一起整理成手稿。'; return;
    }
    this.utilityReturnPage=this.state.page; this.speechArtifact=artifact; this.speechReturnedText='';
    if(this.state.recordingPath) await this.client.local.put('speech','recorded_path',this.state.recordingPath);
    this.state.page='speech';
  }
  private async closeSpeech():Promise<void> {
    if(!this.speechReturnedText) { this.state.page=this.utilityReturnPage; return; }
    if(!this.state.activeId) await this.client.create();
    if(!this.state.activeId) {
      this.state.notice='手稿已留在原音里。连回琴房、打开一页乐章后，就能接着写。';
      this.state.page=this.utilityReturnPage; return;
    }
    await this.client.draftChanged(this.state.draft+(this.state.draft.length?'\n\n':'')+this.speechReturnedText);
    this.speechReturnedText=''; this.state.page='chat';
  }
  private async openConversation(id:string):Promise<void> {
    let conversation=this.state.conversations.find((item:Conversation)=>item.id===id);
    if(!conversation) { await this.client.refresh(); conversation=this.state.conversations.find((item:Conversation)=>item.id===id); }
    if(conversation) await this.client.open(conversation);
    else this.state.notice='这页乐章还没有取到，请连回琴房后再试。';
  }

  @Builder
  private Heading(title: string, back: boolean = false) {
    Row({space: 12}) {
      if (back) Button('返回').onClick(() => {
        if(this.state.page==='reader')this.closeReader();
        else if(this.state.page==='chat' && this.state.branchOrigin.thread)this.returnToParent();
        else if(this.state.page==='chat' && this.state.branchOrigin.arena)this.returnToArena();
        else this.state.page='hub';
      })
        .backgroundColor(Color.Transparent).fontColor(this.colors().accent).padding(0).height(40)
      if(this.state.page==='reader') Image($r('app.media.thinking_deep')).width(28).height(36).objectFit(ImageFit.Cover).borderRadius(12)
      Column({space: 3}) {
        Text(title).fontSize(22).fontWeight(FontWeight.Medium).fontColor(this.colors().text).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis})
        if (this.state.page === 'hub') Text('HajiSaki').fontSize(11).letterSpacing(1).fontColor(this.colors().gold)
      }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      if (this.state.page !== 'host' && this.state.page !== 'reader') {
        Button(this.state.online ? '琴房灯亮着' : '连接琴房').fontSize(12).fontColor(this.colors().accent)
          .backgroundColor(this.colors().surface).height(36).onClick(() => { this.state.page = 'host'; })
      }
    }.width('100%').padding({left:22,right:22,top:16,bottom:16})
  }

  @Builder
  private Navigation() {
    Row() {
      this.NavigationItem('乐章',$r('app.media.icon_document'),'hub')
      this.NavigationItem('记忆',$r('app.media.icon_bookmark'),'memory')
      this.NavigationItem('档案',$r('app.media.icon_archive'),'vault')
      this.NavigationItem('主机',$r('app.media.icon_code'),'host')
    }.height(66).width('100%').border({width:{top:0.5},color:this.colors().border}).backgroundColor(this.colors().background)
  }

  @Builder
  private NavigationItem(title: string, icon: Resource, page: string) {
    Button() {
      Column({space:3}) {
        Image(icon).width(26).height(26).objectFit(ImageFit.Contain).opacity(this.state.page === page ? 1 : 0.65)
        Text(title).fontSize(11).fontColor(this.state.page === page ? this.colors().accent : this.colors().secondary)
      }
    }.backgroundColor(Color.Transparent).layoutWeight(1).height(60).borderRadius(16)
      .onClick(() => {
        if (page === 'memory') this.client.loadMemories();
        else if (page === 'vault') this.openVault();
        else this.state.page = page;
      })
  }

  @Builder
  private Hub() {
    this.Heading('记忆长廊')
    Scroll() {
      Column({space:24}) {
        Row({space:16}) {
          Column({space:14}) {
            Text(this.greeting()).fontSize(this.wide ? 32 : this.compact ? 24 : 28).lineHeight(this.compact ? 34 : 40).fontWeight(FontWeight.Medium).fontColor(this.colors().text)
            Button(this.compact ? '写新乐章' : '写一页新的乐章').fontColor(this.colors().background).backgroundColor(this.colors().accent).height(44).onClick(() => this.client.create())
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
          Image(this.avatar()).width(this.wide ? 160 : this.compact ? 88 : 116).height(this.wide ? 190 : this.compact ? 118 : 152).objectFit(ImageFit.Cover).borderRadius(28)
        }.width('100%').padding({top:8,bottom:4})
        Row({space:18}) {
          Button('随手画室').fontColor(this.colors().gold).fontSize(14).backgroundColor(Color.Transparent).height(44).padding(0).onClick(()=>this.openStudio())
          Button('原音手稿').fontColor(this.colors().secondary).fontSize(13).backgroundColor(Color.Transparent).height(44).padding(0).onClick(()=>this.openSpeech())
          Button('约定与来信').fontColor(this.colors().secondary).fontSize(13).backgroundColor(Color.Transparent).height(44).padding(0).onClick(()=>this.openReminders())
        }.width('100%')
        TextInput({placeholder:'寻找某一页回忆',text:this.state.query}).height(46).fontColor(this.colors().text).backgroundColor(this.colors().surface)
          .placeholderColor(this.colors().secondary).onChange((value:string) => { this.client.search(value); })
        Scroll() {
          Row({space:8}) {
            ForEach(['全部','专属日常','研发工坊','资料卷宗','私密保险箱'],(group:string) => {
              Button(group).fontSize(13).height(34).fontColor(this.state.group === group ? this.colors().background : this.colors().secondary)
                .backgroundColor(this.state.group === group ? this.colors().accent : Color.Transparent).onClick(() => this.selectGroup(group))
            })
          }
        }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
        if (this.client.filteredConversations(this.state.query,this.state.group,this.state.conversations,this.state.searchConversationIds).length === 0) {
          Column({space:12}) {
            Image(this.state.query ? $r('app.media.search_streetlamp') : this.colors().light ? $r('app.media.day_room') : $r('app.media.rainy_piano_room')).width('100%').height(180).objectFit(ImageFit.Cover).borderRadius(24)
            Text(this.state.query ? '那一页还没找到。' : '钢琴旁，给你留了位置。').fontSize(16).fontColor(this.colors().secondary)
            if (this.state.query) Button('清除搜索').fontColor(this.colors().accent).backgroundColor(Color.Transparent).onClick(() => { this.client.search(''); })
          }.width('100%').padding({bottom:30})
        }
        ForEach(this.client.filteredConversations(this.state.query,this.state.group,this.state.conversations,this.state.searchConversationIds),(item:Conversation) => {
          Column({space:12}) {
            Row({space:12}) {
              Column({space:8}) {
                Row({space:8}) {
                  if (item.pinned) Text('置顶').fontSize(10).fontColor(this.colors().gold)
                  Text(item.title).fontSize(18).fontColor(this.colors().text).maxLines(2)
                }
                Text(item.preview || '这一页，等你慢慢续写。').fontSize(14).fontColor(this.colors().secondary).maxLines(2).lineHeight(23)
                Text(item.group).fontSize(11).fontColor(this.colors().gold)
              }.alignItems(HorizontalAlign.Start).layoutWeight(1).onClick(() => this.client.open(item))
            }.width('100%')
            Row({space:8}) {
              Button(item.pinned ? '取消置顶' : '置顶').fontSize(12).fontColor(this.colors().secondary).backgroundColor(Color.Transparent).height(30).onClick(() => this.client.pin(item))
              Button('归档').fontSize(12).fontColor(this.colors().secondary).backgroundColor(Color.Transparent).height(30).onClick(() => this.client.archive(item))
            }.width('100%').justifyContent(FlexAlign.End)
            Divider().strokeWidth(0.5).color(this.colors().border)
          }.width('100%')
        },(item:Conversation) => item.id)
      }.padding({left:24,right:24,bottom:24}).width('100%').constraintSize({maxWidth:800})
    }.layoutWeight(1).width('100%').align(Alignment.Top).scrollBar(BarState.Off)
    this.Navigation()
  }

  @Builder
  private AttachmentLabel(file: Artifact) {
    if(!isPicture(file)) Image(this.fileIcon(file)).width(42).height(42).objectFit(ImageFit.Contain)
    Column({space:4}) {
      Text(file.name).fontColor(this.colors().text).fontSize(14).maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis})
      Text(this.formatSize(file.size)).fontColor(this.colors().secondary).fontSize(11).maxLines(1)
    }.alignItems(HorizontalAlign.Start).layoutWeight(1)
  }

  @Builder
  private AttachmentActions(file: Artifact) {
    if(readableArtifact(file)) Button('翻阅').fontSize(12).fontColor(this.colors().accent).backgroundColor(Color.Transparent).height(44)
      .onClick(()=>this.openArtifact(file))
    if(/^image\/(png|jpeg|webp)$/.test(file.mime)) Button('批注').fontSize(12).fontColor(this.colors().accent).backgroundColor(Color.Transparent).height(44)
      .onClick(()=>this.openStudio(file))
    Button(this.savingArtifactId===file.id?'正在收好…':'保存').fontSize(12).fontColor(this.colors().accent).backgroundColor(Color.Transparent).height(44)
      .enabled(this.savingArtifactId.length===0).onClick(() => this.saveFile(file))
    if(file.mime.startsWith('audio/')||/\.(wav|mp3|m4a|aac|ogg|opus|flac|webm)$/i.test(file.name))
      Button('听写').fontSize(12).fontColor(this.colors().accent).backgroundColor(Color.Transparent).height(44).onClick(()=>this.openSpeech(file))
  }

  @Builder
  private Attachment(file: Artifact) {
    Column({space:10}) {
    if(isPicture(file)) PicturePreview({artifact:file,gateway:this.client.gateway,local:this.client.local,colors:this.colors(),
      previewHeight:this.compact?180:230,onOpen:()=>this.openImage(file)})
    Column({space:this.compact?8:0}) {
      Row({space:12}) {
        this.AttachmentLabel(file)
        if(!this.compact)this.AttachmentActions(file)
      }.width('100%')
      if(this.compact) Row({space:4}) {
        this.AttachmentActions(file)
      }.width('100%').justifyContent(FlexAlign.End)
    }.padding(12).width('100%').borderRadius(14).backgroundColor(this.colors().raised)
    }.width('100%')
  }

  private async saveFile(file: Artifact): Promise<void> {
    if (!this.files || this.savingArtifactId.length>0) return;
    this.savingArtifactId=file.id; this.state.notice='';
    try { await this.files.saveArtifact(file); }
    catch (error) { this.state.notice=error instanceof NativeFileError ? error.message : '这份文件暂时没能保存，请稍后再试。'; }
    finally { this.savingArtifactId=''; }
  }

  @Builder
  private Process() {
    Scroll(this.processScroll) {
      Column({space:10}) {
        ForEach(this.state.events.filter((event:StreamEvent) => event.layer !== 'system' && event.kind !== 'reply_delta'),(event:StreamEvent) => {
          Column({space:6}) {
            Text(event.layer === 'L1' ? '心声手稿' : event.layer === 'L2' ? '演奏笔记' : event.kind==='image_tool_read' ? '工具取出的画面' : event.kind==='visual_input' ? '随消息附上的画面' : event.layer==='L4' ? '画面与交付' : '页间短笺')
              .fontSize(11).fontColor(this.colors().gold)
            Text(this.eventText(event)).fontSize(14).lineHeight(22).fontColor(this.colors().secondary).copyOption(CopyOptions.InApp)
            if(event.payload.artifact && event.kind==='image_tool_read' && event.payload.page!==undefined) {
              PicturePreview({artifact:event.payload.artifact,page:event.payload.page,gateway:this.client.gateway,local:this.client.local,colors:this.colors(),
                pixelWidth:480,previewHeight:200,onOpen:()=>this.openImage(event.payload.artifact!,event.payload.page!)})
              Button('打开第'+(event.payload.page+1)+'页').fontSize(13).fontColor(this.colors().accent).height(44).backgroundColor(Color.Transparent)
                .onClick(()=>this.openImage(event.payload.artifact!,event.payload.page!))
            } else if (event.payload.artifact) this.Attachment(event.payload.artifact)
            if (this.state.settings.transparency === 'studio' && event.payload.detail) {
              Text(typeof event.payload.detail==='string'?event.payload.detail:JSON.stringify(event.payload.detail)).fontFamily('monospace').fontSize(12).fontColor(this.colors().secondary).copyOption(CopyOptions.InApp)
            }
          }.alignItems(HorizontalAlign.Start).width('100%').padding(14).backgroundColor(this.colors().surface).borderRadius(14)
        },(event:StreamEvent) => String(event.seq))
      }.padding(20).width('100%')
    }.layoutWeight(1).width('100%').align(Alignment.Top)
  }

  @Builder
  private Chat() {
    this.Heading(this.state.activeTitle,true)
    if(this.state.branchOrigin.thread) Row({space:10}) {
      Button() { Row({space:8}) {
        Text(this.state.branchOrigin.thread.quote).fontSize(13).lineHeight(22).fontColor(this.colors().secondary).maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1)
        Text('›').fontSize(22).fontColor(this.colors().accent)
      }.width('100%') }.layoutWeight(1).padding(0).backgroundColor(Color.Transparent).onClick(()=>this.readOriginQuote())
      Button('回主乐章').fontSize(12).height(44).fontColor(this.colors().accent).backgroundColor(Color.Transparent).onClick(()=>this.returnToParent())
    }.width('100%').padding({left:22,right:14,bottom:8})
    else if(this.state.branchOrigin.arena) Row({space:8}) {
      Button('回到对照').fontSize(12).height(44).fontColor(this.colors().accent).backgroundColor(Color.Transparent).onClick(()=>this.returnToArena())
      Blank()
      Button('回主乐章').fontSize(12).height(44).fontColor(this.colors().accent).backgroundColor(Color.Transparent).onClick(()=>this.returnToParent())
    }.width('100%').padding({left:14,right:14,bottom:4})
    Row({space:6}) {
      Select([{value:'伴侣纯净'},{value:'智能平衡'},{value:'极客透视'}])
        .arrowModifier(this.selectArrow())
        .selected(this.state.settings.transparency === 'companion' ? 0 : this.state.settings.transparency === 'studio' ? 2 : 1)
        .value(this.state.settings.transparency === 'companion' ? '伴侣纯净' : this.state.settings.transparency === 'studio' ? '极客透视' : '智能平衡')
        .font({size:12}).fontColor(this.colors().secondary).backgroundColor(Color.Transparent)
        .onSelect((index:number) => this.changeTransparency(['companion','balanced','studio'][index]))
      Blank()
      if (this.state.settings.transparency !== 'companion') Button(this.state.showProcess ? '回到对话' : '演奏过程').fontSize(12).fontColor(this.colors().accent)
        .backgroundColor(Color.Transparent).onClick(() => { this.state.showProcess = !this.state.showProcess; })
    }.padding({left:16,right:16}).width('100%')
    if(this.state.pins.length>0) Scroll() {
      Row({space:8}) {
        ForEach(this.state.pins,(pin:ContextPin) => {
          Row({space:6}) {
            Image($r('app.media.icon_bookmark')).width(22).height(22).objectFit(ImageFit.Contain)
            Text(this.pinLabel(pin)).fontSize(12).fontColor(this.colors().gold).maxLines(1).constraintSize({maxWidth:180})
            Button('撤下').fontSize(11).fontColor(this.colors().secondary).height(32).backgroundColor(Color.Transparent).onClick(() => this.client.unpinContext(pin.id))
          }.padding({left:10,right:4}).border({width:0.5,color:this.colors().gold}).borderRadius(14)
        },(pin:ContextPin)=>pin.id)
      }.padding({left:20,right:20,top:6,bottom:8})
    }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
    if (this.state.showProcess) {
      this.Process()
    } else {
      List({scroller:this.scroll,space:0}) {
        LazyForEach(this.client.messageSource,(part:MessagePart) => {
          ListItem() {
            MessageRow({part:part,colors:this.colors(),avatar:this.avatar(),taskState:this.client.tasksFor(part.message.id,this.state.taskPages),
              onTask:(index:number,checked:boolean)=>this.client.toggleTask(part.message.id,index,checked),
              onRead:(message:Message)=>this.readMessage(message),onCopy:(text:string)=>{this.copy(text);},
              onQuote:(text:string)=>{this.client.draftChanged('> '+text.split('\n').join('\n> ')+'\n\n'+this.state.draft);},
              onSelect:(message:Message)=>this.openSelection(message),
              onFork:(message:Message)=>{this.client.fork(message);},onPin:(message:Message)=>{this.client.pinContext('message',message.id);},
              attachment:(file:Artifact)=>{this.Attachment(file);}})
          }
        },(part:MessagePart) => part.id)
        ForEach(this.state.pending.filter((item:PendingMessage) => item.conversation_id === this.state.activeId),(item:PendingMessage) => {
          ListItem() {
            Column({space:8}) {
              Text(item.content).fontSize(16).lineHeight(26).fontColor(this.colors().text).width('100%').copyOption(CopyOptions.InApp)
              Text(item.last_error ? '暂未送达 · 请检查后重试' : '待送出').fontSize(11).fontColor(this.colors().gold).width('100%')
            }.padding(18).margin({left:20,right:20,bottom:12}).backgroundColor(this.colors().raised).borderRadius(20)
          }
        },(item:PendingMessage) => item.client_id)
        if (this.state.messages.length === 0 && !this.state.branchOrigin.thread && !this.state.branchOrigin.arena) {
          ListItem() {
            Column({space:20}) {
              Image(this.colors().light ? $r('app.media.day_room') : $r('app.media.night_room')).width('100%').height(220).objectFit(ImageFit.Cover).borderRadius(28)
              Text('不必急着组织语言。\n我在听。').fontSize(20).lineHeight(32).fontColor(this.colors().secondary).textAlign(TextAlign.Center)
            }.padding(28).width('100%')
          }
        }
      }.layoutWeight(1).width('100%').cachedCount(3).scrollBar(BarState.Off)
        .onAreaChange(()=>this.restoreStudioPosition())
        .onScrollIndex((start:number)=>{this.chatFirstIndex=start;})
        .onScroll((offset:number,state:ScrollState) => { if (state === ScrollState.Scroll && offset < 0) this.readingLock = true; })
        .onReachEnd(() => { this.readingLock = false; this.newContent = false; })
    }
    if (this.newContent && !this.state.showProcess) Button('回到最新的一页 ↓').fontSize(12).fontColor(this.colors().accent)
      .backgroundColor(this.colors().surface).height(32).onClick(() => { this.readingLock = false; this.newContent = false; this.scroll.scrollEdge(Edge.Bottom); })
    this.Composer()
  }

  @Builder
  private ComposerExtras() {
    Button('画室').fontSize(13).fontColor(this.colors().accent).backgroundColor(Color.Transparent).height(42).padding({left:6,right:6})
      .onClick(()=>this.openStudio())
    Button('@').fontSize(19).fontColor(this.colors().accent).backgroundColor(Color.Transparent).width(44).height(44).padding(0)
      .accessibilityText('引用电脑代码或过往乐章').onClick(()=>this.openReferences())
    Button('/').fontSize(19).fontColor(this.colors().accent).backgroundColor(Color.Transparent).width(44).height(44).padding(0)
      .accessibilityText('常用起笔、乐章语气和上下文整理').onClick(()=>this.openCommands())
    Button('分支').fontSize(13).fontColor(this.colors().accent).backgroundColor(Color.Transparent).height(44).padding({left:6,right:6})
      .accessibilityText('附页与同题对照').onClick(()=>this.openBranches())
  }

  @Builder
  private Composer() {
    Column({space:10}) {
      if (this.state.queued > 0) Row() {
        Text(this.state.queued + ' 封话语待送出').fontSize(12).fontColor(this.colors().gold)
        Blank()
        Button('再送一次').fontSize(12).fontColor(this.colors().accent).backgroundColor(Color.Transparent).onClick(() => this.client.drain(true))
      }.width('100%')
      if (this.state.selectedAttachments.length > 0) Scroll() {
        Row({space:8}) { ForEach(this.state.selectedAttachments,(file:Artifact) => {
          if(isPicture(file) || readableArtifact(file)) Row({space:0}) {
            Button(file.name).fontSize(12).fontColor(this.colors().accent).backgroundColor(Color.Transparent)
              .onClick(()=>{if(isPicture(file))this.openImage(file);else this.openArtifact(file);})
            Button('×').fontSize(20).fontColor(this.colors().secondary).backgroundColor(Color.Transparent).width(40).height(40).padding(0)
              .accessibilityText('移除'+file.name).onClick(()=>this.client.detach(file.id))
          }.backgroundColor(this.colors().raised).borderRadius(20)
          else Button(file.name + ' ×').fontSize(12).fontColor(this.colors().accent).backgroundColor(this.colors().raised)
            .onClick(() => this.client.detach(file.id))
        },(file:Artifact) => file.id) }
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).width('100%')
      if (this.state.recordingState === 'recording' || this.state.recordingState === 'paused') {
        Row({space:12}) {
          Text(this.state.recordingState === 'paused' ? '声音暂歇' : '正在听你说…').fontColor(this.colors().accent).layoutWeight(1)
          Button(this.state.recordingState === 'paused' ? '继续' : '暂停').fontColor(this.colors().accent).backgroundColor(this.colors().raised)
            .onClick(() => this.pauseRecording())
          Button('收好录音').fontColor(this.colors().background).backgroundColor(this.colors().accent).onClick(() => this.record())
        }.width('100%')
      } else if (this.state.recordingPath) {
        Row() {
          Text('录音已留在手机').fontColor(this.colors().secondary).fontSize(13).layoutWeight(1)
          Button('整理手稿').fontColor(this.colors().accent).backgroundColor(Color.Transparent).onClick(()=>this.openSpeech())
          Button('附上原音').fontColor(this.colors().accent).backgroundColor(this.colors().raised).onClick(() => this.attachRecording())
        }.width('100%')
      }
      ForEach([this.state.draftEpoch],(epoch:number)=>{
        TextArea({placeholder:'想说的话，就写在这里…',text:this.state.draft})
          .id('composer-draft').enabled(!this.state.draftLoading && !this.referencesOpen && !this.commandsOpen && !this.artifactOpen && !this.imageOpen && !this.selectionOpen && !this.branchesOpen && !this.arenaOpen)
          .fontSize(16).fontColor(this.colors().text).placeholderColor(this.colors().secondary).backgroundColor(Color.Transparent)
          .constraintSize({minHeight:54,maxHeight:150}).onChange((value:string)=>{if(epoch===this.state.draftEpoch && !this.state.draftLoading)this.draftUpdated(value);})
      },(epoch:number)=>String(epoch))
      if(this.state.uploadProgress) Text(this.state.uploadProgress).fontSize(11).fontColor(this.colors().gold).width('100%')
      Row({space:8}) { this.ComposerExtras() }.width('100%')
      Row({space:8}) {
        Button() { Image($r('app.media.icon_document')).width(30).height(30).objectFit(ImageFit.Contain) }
          .backgroundColor(Color.Transparent).width(42).height(42).accessibilityText('添加附件').onClick(() => this.upload())
        Button() { Image($r('app.media.icon_microphone')).width(30).height(30).objectFit(ImageFit.Contain) }
          .backgroundColor(Color.Transparent).width(42).height(42).accessibilityText('录音').onClick(() => this.record())
        Blank()
        if (this.state.runId) Button(this.state.stopping ? '正在停笔' : '停笔').fontColor(this.colors().danger).backgroundColor(this.colors().raised)
          .onClick(() => this.client.stop())
        Button('送出').fontColor(this.colors().background).backgroundColor(this.colors().accent).height(42)
          .enabled(!this.state.sending && (this.state.draft.trim().length > 0 || this.state.selectedAttachments.length > 0))
          .onClick(() => this.client.send())
      }.width('100%')
      if(this.state.models.length>0) ModelPicker({colors:this.colors(),models:this.state.models,model:this.state.model,effort:this.state.effort,dense:true,
        onSelect:(model:string,effort:string)=>{this.state.model=model;this.state.effort=effort;if(effort==='max'||effort==='xhigh')this.effect('effort');}})
    }.padding({left:16,right:16,top:12,bottom:16}).width('100%').backgroundColor(this.colors().surface)
      .borderRadius({topLeft:28,topRight:28}).border({width:{top:0.5},color:this.colors().border})
  }

  @Builder
  private Reader() {
    this.Heading('静谧手稿',true)
    Scroll() {
      Column({space:24}) {
        Text(this.state.readingTitle).fontSize(28).lineHeight(40).fontColor(this.colors().text).fontWeight(FontWeight.Medium)
        Divider().strokeWidth(0.5).color(this.colors().gold)
        Manuscript({text:this.state.readingText,colors:this.colors(),taskState:this.client.tasksFor(this.state.readingMessageId,this.state.taskPages),
          onTask:(index:number,checked:boolean)=>this.client.toggleTask(this.state.readingMessageId,index,checked)})
      }.padding(28).width('100%').constraintSize({maxWidth:760})
    }.layoutWeight(1).width('100%').align(Alignment.Top)
    Row({space:16}) {
      Button('复制手稿').fontColor(this.colors().accent).backgroundColor(this.colors().surface).onClick(() => this.copy(this.state.readingText))
      Button('带回琴房').fontColor(this.colors().background).backgroundColor(this.colors().accent).onClick(() => {
        this.client.draftChanged(this.state.draft+(this.state.draft.length?'\n\n':'')+'> ' + this.state.readingText.split('\n').join('\n> ') + '\n\n'); this.closeReader();
      })
    }.padding(20).width('100%').justifyContent(FlexAlign.Center)
  }

  @Builder
  private MemoryRoom() {
    this.Heading('记忆星空')
    Scroll() {
      Column({space:22}) {
        Row({space:18}) {
          Image($r('app.media.late_night_tea')).width(90).height(112).objectFit(ImageFit.Cover).borderRadius(24)
          Text('关于你的事，\n我想好好记住。').fontSize(23).lineHeight(35).fontColor(this.colors().text).layoutWeight(1)
        }.width('100%')
        Column({space:10}) {
          TextArea({text:this.memoryDraft,placeholder:'希望我记住的事'}).fontColor(this.colors().text).placeholderColor(this.colors().secondary)
            .backgroundColor(this.colors().surface).height(90).onChange((value:string) => { this.memoryDraft = value; })
          Row({space:12}) {
            if (this.memoryId) Button('取消修改').fontColor(this.colors().secondary).backgroundColor(Color.Transparent).onClick(() => { this.memoryId=''; this.memoryDraft=''; })
            Blank()
            Button(this.memoryId ? '收好修改' : '记住这件事').fontColor(this.colors().background).backgroundColor(this.colors().accent)
              .onClick(() => {
                const content=this.memoryDraft; const id=this.memoryId;
                this.client.saveMemory(content,id).then((saved:boolean) => {
                  if (saved && this.memoryDraft===content && this.memoryId===id) { this.memoryId=''; this.memoryDraft=''; this.effect('bookmark'); }
                });
              })
          }.width('100%')
        }.width('100%')
        ForEach(this.state.memories.filter((item:Memory) => item.content.length > 0),(item:Memory) => {
          Column({space:12}) {
            Text(item.content).fontSize(16).lineHeight(26).fontColor(this.colors().text).width('100%')
            Row({space:8}) {
              Blank()
              Button('修改').fontSize(12).fontColor(this.colors().accent).backgroundColor(Color.Transparent).onClick(() => { this.memoryDraft=item.content; this.memoryId=item.id; })
              Button('移至主机回收站').fontSize(12).fontColor(this.colors().secondary).backgroundColor(Color.Transparent).onClick(() => this.client.recycleMemory(item.id))
            }.width('100%')
          }.padding(18).width('100%').borderRadius(18).backgroundColor(this.colors().surface).border({width:0.5,color:this.colors().border})
        },(item:Memory) => item.id)
        Text('灵魂调律').fontSize(22).fontColor(this.colors().text).width('100%')
        this.Tuning('卸防温柔', '端庄严谨', this.formality, 0)
        this.Tuning('克制留白', '事无巨细', this.detail, 1)
        this.Tuning('安静陪伴', '傲娇轻嗔', this.teasing, 2)
        Button('记下这样的我').fontColor(this.colors().background).backgroundColor(this.colors().accent).onClick(() => this.savePersonality())
        Column({space:10}) {
          Text('光线').fontSize(16).fontColor(this.colors().text).width('100%')
          Row({space:8}) {
            this.ThemeChoice('随昼夜','auto')
            this.ThemeChoice('月下剧场','night')
            this.ThemeChoice('初春琴房','day')
          }.width('100%')
        }.width('100%')
        Row({space:12}) {
          Text('有线耳机琴音与轻触反馈').fontSize(14).fontColor(this.colors().text).layoutWeight(1)
          Toggle({type:ToggleType.Switch,isOn:this.state.settings.sound}).selectedColor(this.colors().accent)
            .onChange((value:boolean) => this.changeSound(value))
        }.width('100%')
      }.padding(24).width('100%').constraintSize({maxWidth:800})
    }.layoutWeight(1).width('100%').align(Alignment.Top)
    this.Navigation()
  }

  @Builder
  private ThemeChoice(title: string, value: string) {
    Button(title).fontSize(12).height(36).padding({left:10,right:10}).layoutWeight(1)
      .fontColor(this.state.settings.theme===value ? this.colors().background : this.colors().accent)
      .backgroundColor(this.state.settings.theme===value ? this.colors().accent : this.colors().surface)
      .onClick(() => this.changeTheme(value))
  }

  @Builder
  private Tuning(left: string,right: string,value: number,axis: number) {
    Column({space:5}) {
      Row() { Text(left).fontSize(13).fontColor(this.colors().secondary); Blank(); Text(right).fontSize(13).fontColor(this.colors().secondary) }.width('100%')
      Slider({value:value,min:0,max:100,step:1}).selectedColor(this.colors().accent).trackColor(this.colors().border)
        .onChange((next:number) => { if(axis===0) this.formality=next; else if(axis===1) this.detail=next; else this.teasing=next; })
    }.width('100%')
  }

  @Builder
  private Vault() {
    this.Heading('档案保险箱')
    Row({space:6}) {
      Button('全部').fontSize(14).height(40).fontColor(!this.galleryMode?this.colors().background:this.colors().secondary)
        .backgroundColor(!this.galleryMode?this.colors().accent:Color.Transparent).onClick(()=>{this.galleryMode=false;})
      Button('图片').fontSize(14).height(40).fontColor(this.galleryMode?this.colors().background:this.colors().secondary)
        .backgroundColor(this.galleryMode?this.colors().accent:Color.Transparent)
        .onClick(()=>{this.pictures.replace(this.state.artifacts);this.galleryMode=true;})
      Blank()
      if(this.galleryMode) Button(this.state.uploadProgress || '导入图片').fontSize(13).height(44).fontColor(this.colors().gold)
        .backgroundColor(Color.Transparent).enabled(!this.state.uploadProgress).onClick(()=>this.importPicture())
    }.width('100%').padding({left:20,right:16,bottom:10})
    if(this.galleryMode) {
      if(this.pictures.totalCount()===0) Column() {
        Text('还没有图片。').fontSize(16).fontColor(this.colors().secondary)
      }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      else Grid() {
        LazyForEach(this.pictures,(file:Artifact)=>{
          GridItem() {
            PicturePreview({artifact:file,gateway:this.client.gateway,local:this.client.local,colors:this.colors(),
              pixelWidth:480,previewHeight:168,onOpen:()=>this.openImage(file)})
          }.height(168)
        },(file:Artifact)=>file.id)
      }.columnsTemplate(this.wide?'1fr 1fr 1fr':'1fr 1fr').columnsGap(12).rowsGap(14).cachedCount(2)
        .layoutWeight(1).width('100%').padding({left:20,right:20,bottom:20})
    } else {
    Scroll() {
      Column({space:14}) {
        Row({space:16}) {
          Image($r('app.media.proud_smug')).width(80).height(106).objectFit(ImageFit.Cover).borderRadius(24)
          Text('每一份交付，\n都留在这里。').fontSize(24).lineHeight(35).fontColor(this.colors().text).layoutWeight(1)
        }.padding({bottom:15}).width('100%')
        if (this.state.artifacts.length === 0) Text('还没有收到文件。').fontColor(this.colors().secondary).padding(30)
        ForEach(this.state.artifacts,(file:Artifact) => {
          this.Attachment(file)
          if (this.state.activeId) Button('带回对话').fontSize(12).fontColor(this.colors().accent).backgroundColor(Color.Transparent)
            .onClick(() => { this.client.attach(file); this.state.page='chat'; })
        },(file:Artifact) => file.id)
      }.padding(24).width('100%').constraintSize({maxWidth:800})
    }.layoutWeight(1).width('100%').align(Alignment.Top)
    }
    this.Navigation()
  }

  @Builder
  private Host() {
    this.Heading('主机指挥台')
    Scroll() {
      Column({space:20}) {
        Row({space:16}) {
          Image(this.avatar()).width(80).height(100).objectFit(ImageFit.Cover).borderRadius(22)
          Column({space:8}) {
            Text(this.state.online ? '琴房的灯，亮着。' : '把琴房的钥匙交给我。').fontSize(23).fontColor(this.colors().text)
            if (this.state.status) Text(this.state.status.provider.name).fontSize(13).fontColor(this.colors().secondary)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%')
        Column({space:10}) {
          Text('主通道地址').fontSize(13).fontColor(this.colors().secondary).width('100%')
          TextInput({text:this.primary,placeholder:'https://your-private-host'}).fontColor(this.colors().text).placeholderColor(this.colors().secondary).backgroundColor(this.colors().surface).onChange((value:string) => { this.primary=value; })
          Text('另一条直连地址').fontSize(13).fontColor(this.colors().secondary).width('100%')
          TextInput({text:this.fallback,placeholder:'可留空'}).fontColor(this.colors().text).placeholderColor(this.colors().secondary).backgroundColor(this.colors().surface).onChange((value:string) => { this.fallback=value; })
          Text('设备编号').fontSize(13).fontColor(this.colors().secondary).width('100%')
          TextInput({text:this.device,placeholder:'来自配对设置的设备编号'}).fontColor(this.colors().text).placeholderColor(this.colors().secondary).backgroundColor(this.colors().surface).onChange((value:string) => { this.device=value; })
          Text('配对令牌').fontSize(13).fontColor(this.colors().secondary).width('100%')
          Row({space:8}) {
            TextInput({text:this.token,placeholder:'来自主机的配对设置'}).type(this.revealToken ? InputType.Normal : InputType.Password).showPasswordIcon(false)
              .fontColor(this.colors().text).placeholderColor(this.colors().secondary).backgroundColor(this.colors().surface).layoutWeight(1).onChange((value:string) => { this.token=value; })
            Button(this.revealToken ? '隐藏' : '显示').fontSize(13).fontColor(this.colors().accent).backgroundColor(this.colors().surface)
              .onClick(() => { this.revealToken=!this.revealToken; })
          }.width('100%')
          Button(this.state.connecting ? '正在接回琴房…' : this.state.online && !this.token ? '已连接琴房' : '连接琴房').fontColor(this.colors().background).backgroundColor(this.colors().accent).width('100%').height(46)
            .enabled(!this.state.connecting && this.primary.trim().length>0 && this.device.trim().length>0 && this.token.trim().length>0)
            .onClick(() => { this.client.connect(this.primary,this.fallback,this.token,this.device).then(() => {
              if(this.state.online) { this.token=''; if(this.returnAfterConnect) { this.state.page=this.returnAfterConnect; this.returnAfterConnect=''; } }
            }); })
        }.width('100%')
        Column({space:10}) {
          Row() {
            Text('备用通道').fontSize(16).fontColor(this.colors().text).layoutWeight(1)
            Text(this.state.relayActive?'正在使用':this.state.relayConfigured?'已导入':'未导入').fontSize(13).fontColor(this.colors().secondary)
          }.width('100%')
          if(this.state.relayNotice) Text(this.state.relayNotice).fontSize(13).lineHeight(21).fontColor(this.colors().secondary).width('100%')
          Button('配置备用琴房').fontSize(14).fontColor(this.colors().accent).backgroundColor(Color.Transparent)
            .height(44).onClick(()=>{this.state.page='relay';})
        }.padding(18).backgroundColor(this.colors().surface).borderRadius(20).width('100%')
        if (this.state.status) {
          Column({space:15}) {
            Row() { Text('模型接入').fontColor(this.colors().secondary); Blank(); Text(this.state.status.provider.available ? '已找到' : '待接入').fontColor(this.colors().text) }.width('100%')
            Row() { Text('登录状态').fontColor(this.colors().secondary); Blank(); Text(this.state.status.provider.authenticated ? '已登录' : '待主机确认').fontColor(this.colors().text) }.width('100%')
            if (this.state.status.host.memory_mb !== undefined) Row() {
              Text('网关内存').fontColor(this.colors().secondary); Blank(); Text(this.state.status.host.memory_mb.toFixed(1) + ' MB').fontColor(this.colors().text)
            }.width('100%')
            Button('刷新主机状态').fontColor(this.colors().accent).backgroundColor(Color.Transparent).onClick(() => this.client.refresh())
          }.padding(18).backgroundColor(this.colors().surface).borderRadius(20).width('100%')
        }
      }.padding(24).width('100%').constraintSize({maxWidth:680})
    }.layoutWeight(1).width('100%').align(Alignment.Top)
    this.Navigation()
  }

  build() {
    WithTheme({colorMode:this.colors().light ? ThemeColorMode.LIGHT : ThemeColorMode.DARK}) {
    Stack() {
    if(this.state.page==='chat' && this.state.ready)
      Image(this.colors().light?$r('app.media.day_room'):$r('app.media.night_room'))
        .width('100%').height('100%').objectFit(ImageFit.Cover).opacity(0.045).hitTestBehavior(HitTestMode.None)
    Column() {
      if (!this.state.ready) {
        Stack() {
          Image($r('app.media.moonlit_piano_splash')).width('100%').height('100%').objectFit(ImageFit.Cover)
          Text('哈基祥').fontSize(36).fontColor('#EDF1FA').letterSpacing(8)
        }.width('100%').layoutWeight(1)
      } else {
        if(this.state.previewStorage) Text('临时预览 · 本机记录关闭后清空').fontSize(12).fontColor(this.colors().gold).padding(8).width('100%')
        if (this.state.status?.provider.simulated) Text('本地演练 · 非 AI 回复').fontSize(12).fontColor(this.colors().gold).padding(8).width('100%')
        if (this.state.notice) Row({space:8}) {
          Text(this.state.notice).fontSize(13).lineHeight(20).fontColor(this.colors().secondary).layoutWeight(1)
          Button(this.state.pendingRelayId ? '查询回执' : '收起').fontSize(12).fontColor(this.colors().accent).backgroundColor(Color.Transparent)
            .onClick(() => { if(this.state.pendingRelayId) this.client.retryRelay(); else this.client.clearNotice(); })
        }.padding({left:20,right:14,top:10,bottom:10}).backgroundColor(this.colors().surface).width('100%')
        if (this.state.page === 'hub') this.Hub()
        else if (this.state.page === 'chat') {
          ForEach([this.state.activeId+':'+this.state.draftEpoch],(_key:string)=>{this.Chat();},(key:string)=>key)
        }
        else if (this.state.page === 'reader') this.Reader()
        else if (this.state.page === 'relay') {
          Column() { RelayRoom({colors:this.colors(),origin:this.state.relayOrigin,configured:this.state.relayConfigured,
            active:this.state.relayActive,restoredNotice:this.state.relayNotice,
            onImport:(source:string)=>this.client.importRelay(source),onClose:()=>{this.state.page='host';}}) }.layoutWeight(1).width('100%')
        }
        else if (this.state.page === 'studio') {
          ForEach([this.studioSession],(_key:string)=>{
            Column() { StudioRoom({artifact:this.studioArtifact,conversationId:this.studioConversation,
              gateway:this.client.gateway,local:this.client.local,colors:this.colors(),
              onClose:()=>this.closeStudio(),onUse:(file:Artifact)=>this.useStudio(file),
              onConnect:()=>this.connectStudio(),
              onPick:(file:Artifact)=>{this.studioArtifact=file;this.studioSession=String(Date.now())+':'+file.id;}}) }
              .layoutWeight(1).width('100%')
          },(key:string)=>key)
        }
        else if (this.state.page === 'memory') this.MemoryRoom()
        else if (this.state.page === 'vault') this.Vault()
        else if (this.state.page === 'speech') {
          Column() { SpeechRoom({gateway:this.client.gateway,local:this.client.local,
            artifact:this.speechArtifact,colors:this.colors(),compact:this.compact,onUseText:(text:string)=>{this.speechReturnedText=text;},
            onClose:()=>{this.closeSpeech();},onConnect:()=>{this.returnAfterConnect='speech';this.state.page='host';}}) }
            .layoutWeight(1).width('100%')
        }
        else if (this.state.page === 'reminders') {
          Column() { ReminderRoom({gateway:this.client.gateway,local:this.client.local,colors:this.colors(),
            conversationId:this.utilityReturnPage==='chat'?this.state.activeId:'',onClose:()=>{this.state.page=this.utilityReturnPage;},
            onOpenConversation:(id:string)=>{this.openConversation(id);}}) }.layoutWeight(1).width('100%')
        }
        else this.Host()
      }
    }.width('100%').height('100%').backgroundColor(Color.Transparent)
      .onAreaChange((oldValue:Area,newValue:Area) => { this.wide = Number(newValue.width) >= 700; this.compact=Number(newValue.width)<360; })
    if(this.selectionOpen) Column() {
      if(this.state.previewStorage) Text('临时预览 · 本机记录关闭后清空').fontSize(12).fontColor(this.colors().gold).padding(8).width('100%')
      Column() { SelectionRoom({colors:this.colors(),gateway:this.client.gateway,local:this.client.local,
        messageId:this.selectionMessage,conversationId:this.selectionConversation,onQuote:(text:string)=>this.quoteSelection(text),
        onThread:(item:Conversation)=>this.enterThread(item),onClose:()=>this.closeSelection()}) }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(this.colors().background).hitTestBehavior(HitTestMode.Default)
    if(this.branchesOpen) Column() {
      if(this.state.previewStorage) Text('临时预览 · 本机记录关闭后清空').fontSize(12).fontColor(this.colors().gold).padding(8).width('100%')
      Column() { BranchRoom({colors:this.colors(),gateway:this.client.gateway,local:this.client.local,conversationId:this.branchConversation,
        models:this.state.models,realModel:this.state.status?.provider.available===true && this.state.status?.provider.simulated!==true,
        initialDraft:this.branchDraft,initialFiles:this.branchFiles,initialModel:this.state.model,initialEffort:this.state.effort,initialTab:this.branchTab,
        onClose:()=>{this.branchesOpen=false;this.focusComposer();},onThread:(id:string)=>this.enterKnownThread(id),onArena:(id:string)=>this.openArena(id),
        onFile:(file:Artifact)=>{if(isPicture(file))this.openImage(file);else this.openArtifact(file);}}) }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(this.colors().background).hitTestBehavior(HitTestMode.Default)
    if(this.arenaOpen) Column() {
      if(this.state.previewStorage) Text('临时预览 · 本机记录关闭后清空').fontSize(12).fontColor(this.colors().gold).padding(8).width('100%')
      Column() { ArenaRoom({colors:this.colors(),models:this.state.models,gateway:this.client.gateway,local:this.client.local,arenaId:this.arenaId,
        onClose:()=>this.closeArena(),onContinue:(side:ArenaSide,parent:string)=>this.continueArena(side,parent),
        onFile:(file:Artifact)=>{if(isPicture(file))this.openImage(file);else this.openArtifact(file);}}) }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(this.colors().background).hitTestBehavior(HitTestMode.Default)
    if(this.referencesOpen) Column() {
      if(this.state.previewStorage) Text('临时预览 · 本机记录关闭后清空').fontSize(12).fontColor(this.colors().gold).padding(8).width('100%')
      Column() { ReferenceRoom({gateway:this.client.gateway,colors:this.colors(),initialQuery:this.referenceQuery,
        onClose:()=>this.closeReferences(),onUse:(file:Artifact)=>this.useReference(file)}) }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(this.colors().background).hitTestBehavior(HitTestMode.Default)
    if(this.commandsOpen) Column() {
      if(this.state.previewStorage) Text('临时预览 · 本机记录关闭后清空').fontSize(12).fontColor(this.colors().gold).padding(8).width('100%')
      Column() { CommandRoom({local:this.client.local,colors:this.colors(),conversation:this.commandConversation,generation:this.commandGeneration,
        initialQuery:this.commandQuery,currentTone:this.state.toneId,busy:this.state.runId.length>0,
        realModel:this.state.status?.provider.available===true && this.state.status?.provider.simulated!==true,
        model:this.state.model,effort:this.state.effort,
        onCatalog:()=>this.client.composerCatalog(),onState:(conversation:string)=>this.client.refreshComposer(conversation),
        onTemplate:(conversation:string,generation:number,text:string)=>this.useTemplate(conversation,generation,text),onTone:(conversation:string,tone:string)=>this.client.setTone(conversation,tone),
        onCompact:(conversation:string,generation:number,operation:string,model:string,effort:string)=>this.compactContext(conversation,generation,operation,model,effort),
        onStop:(run:string)=>this.client.stopContext(run),onSummary:(record:CompactionRecord)=>this.openCommandSummary(record),
        onArchive:(file:Artifact)=>{this.closeCommands();this.openArtifact(file);},onClose:()=>this.closeCommands()}) }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(this.colors().background).hitTestBehavior(HitTestMode.Default)
    if(this.artifactOpen && this.viewedArtifact) Column() {
      if(this.state.previewStorage) Text('临时预览 · 本机记录关闭后清空').fontSize(12).fontColor(this.colors().gold).padding(8).width('100%')
      if(this.state.notice) Row({space:8}) {
        Text(this.state.notice).fontSize(13).lineHeight(20).fontColor(this.colors().secondary).layoutWeight(1)
        Button('收起').fontSize(12).fontColor(this.colors().accent).backgroundColor(Color.Transparent).onClick(()=>this.client.clearNotice())
      }.padding({left:20,right:14,top:10,bottom:10}).backgroundColor(this.colors().surface).width('100%')
      Column() { ArtifactRoom({artifact:this.viewedArtifact,gateway:this.client.gateway,local:this.client.local,colors:this.colors(),
        onClose:()=>{this.artifactOpen=false;}}) }.layoutWeight(1).width('100%')
    }.width('100%').height('100%').backgroundColor(this.colors().background).hitTestBehavior(HitTestMode.Default)
    if(this.imageOpen && this.viewedImage) Column() {
      if(this.state.previewStorage) Text('临时预览 · 本机记录关闭后清空').fontSize(12).fontColor(this.colors().gold).padding(8).width('100%')
      if(this.state.notice) Row({space:8}) {
        Text(this.state.notice).fontSize(13).lineHeight(20).fontColor(this.colors().secondary).layoutWeight(1)
        Button('收起').fontSize(12).fontColor(this.colors().accent).backgroundColor(Color.Transparent).onClick(()=>this.client.clearNotice())
      }.padding({left:20,right:14,top:10,bottom:10}).backgroundColor(this.colors().surface).width('100%')
      Stack() {
      ImageRoom({artifact:this.viewedImage,page:this.imagePage,gateway:this.client.gateway,local:this.client.local,
        colors:this.colors(),saving:this.savingArtifactId===this.viewedImage.id,asking:this.imageAsking,
        onClose:()=>this.closeImage(),onAnnotate:()=>this.annotateImage(),onSave:()=>this.saveFile(this.viewedImage!),onAsk:()=>this.askImage()})
      if(this.imageEditing) ForEach([this.studioSession],(_key:string)=>{
        StudioRoom({artifact:this.studioArtifact,conversationId:this.studioConversation,gateway:this.client.gateway,local:this.client.local,colors:this.colors(),
          onClose:()=>this.closeStudio(),onUse:(file:Artifact)=>this.useStudio(file),onConnect:()=>this.connectStudio(),
          onPick:(file:Artifact)=>{this.studioArtifact=file;this.studioSession=String(Date.now())+':'+file.id;}})
      },(key:string)=>key)
      }
        .width('100%').layoutWeight(1)
    }.width('100%').height('100%').backgroundColor(this.colors().background)
    }.width('100%').height('100%').backgroundColor(this.colors().background)
    }
  }
}
