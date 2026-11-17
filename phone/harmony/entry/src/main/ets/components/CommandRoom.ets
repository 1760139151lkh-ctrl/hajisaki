import { util } from '@kit.ArkTS';
import { Palette } from '../design/Theme';
import { Artifact } from '../model/Types';
import { ComposerCatalog, ComposerState, ComposerTemplate, ToneOption, CompactionRecord } from '../model/CommandTypes';
import { previewMode } from '../model/BuildMode';
import { LocalStore } from '../services/LocalStore';
import { GatewayError } from '../services/Gateway';

interface CompactIntent { operation_id:string; model:string; effort:string }
let commandSequence:number=0;

@Component
export struct CommandRoom {
  local:LocalStore=new LocalStore();
  @Prop colors:Palette=new Palette();
  @Prop currentTone:string='inherit';
  @Prop busy:boolean=false;
  @Prop realModel:boolean=true;
  @Prop model:string='default';
  @Prop effort:string='medium';
  conversation:string='';
  generation:number=0;
  initialQuery:string='';
  onCatalog:()=>Promise<ComposerCatalog>=async()=>{return {templates:[],tones:[]};};
  onState:(conversation:string)=>Promise<ComposerState | undefined>=async()=>undefined;
  onTemplate:(conversation:string,generation:number,text:string)=>Promise<void>=async()=>{};
  onTone:(conversation:string,tone:string)=>Promise<void>=async()=>{};
  onCompact:(conversation:string,generation:number,operation:string,model:string,effort:string)=>Promise<void>=async()=>{};
  onStop:(run:string)=>Promise<void>=async()=>{};
  onSummary:(record:CompactionRecord)=>void=()=>{};
  onArchive:(file:Artifact)=>void=()=>{};
  onClose:()=>void=()=>{};
  @State tab:string='templates';
  @State query:string='';
  @State catalog:ComposerCatalog={templates:[],tones:[]};
  @State metadata:ComposerState={tone_id:'inherit',active_compaction:null,latest_compaction:null,busy:false,has_history:false};
  @State catalogLoading:boolean=true;
  @State stateLoading:boolean=true;
  @State stateKnown:boolean=false;
  @State intentReady:boolean=false;
  @State connected:boolean=false;
  @State working:string='';
  @State catalogNotice:string='';
  @State stateNotice:string='';
  @State actionNotice:string='';
  private closed:boolean=false;
  private stateVersion:number=0;
  private pollTimer:number=-1;
  private pending:CompactIntent | undefined=undefined;

  aboutToAppear():void {
    this.query=this.initialQuery;
    this.loadCatalog();this.initializeState();
    this.pollTimer=setInterval(()=>{if(!this.closed && !this.working && !this.stateLoading)this.loadState();},3000);
  }
  aboutToDisappear():void {this.closed=true;this.stateVersion++;if(this.pollTimer>=0)clearInterval(this.pollTimer);}
  private copy(error:Error):string {
    return error instanceof GatewayError?error.message:'这一页暂时没能接好，已经写下的话仍在。';
  }
  private async initializeState():Promise<void> {await this.restoreIntent();if(!this.closed)this.loadState();}
  private async restoreIntent():Promise<void> {
    try {
      const saved=await this.local.get('compact-operation',this.conversation,'');
      if(!this.closed){if(saved)this.pending=JSON.parse(saved) as CompactIntent;this.intentReady=true;}
    } catch (_) {if(!this.closed)this.actionNotice='上次整理的编号暂时没有取出，请重新打开这一页。';}
  }
  private async loadCatalog():Promise<void> {
    this.catalogLoading=true;this.catalogNotice='';
    try {
      const saved=await this.local.get('snapshot','composer-catalog','');
      if(!this.closed && saved)this.catalog=JSON.parse(saved) as ComposerCatalog;
      const result=await this.onCatalog();
      if(!this.closed)this.catalog=result;
    } catch(error) {
      if(!this.closed && this.catalog.templates.length===0)this.catalogNotice=this.copy(error as Error);
    } finally {if(!this.closed)this.catalogLoading=false;}
  }
  private async loadState():Promise<void> {
    const version=++this.stateVersion;this.stateLoading=true;
    try {
      const cached=await this.local.get('composer',this.conversation,'');
      if(!this.closed && version===this.stateVersion && cached){this.metadata=JSON.parse(cached) as ComposerState;this.stateKnown=true;}
      if(this.closed || version!==this.stateVersion)return;
      const result=await this.onState(this.conversation);
      if(this.closed || version!==this.stateVersion)return;
      if(result){this.metadata=result;this.stateKnown=true;}
      this.connected=true;this.stateNotice='';
      if(this.pending && this.metadata.latest_compaction?.operation_id===this.pending.operation_id) {
        await this.local.put('compact-operation',this.conversation,'');
        this.pending=undefined;
      }
    } catch(error) {
      if(!this.closed && version===this.stateVersion){this.connected=false;this.stateNotice=this.copy(error as Error);}
    } finally {if(!this.closed && version===this.stateVersion)this.stateLoading=false;}
  }
  private activate(tab:string):void {this.tab=tab;this.actionNotice='';}
  private templates():ComposerTemplate[] {
    const term=this.query.trim().toLowerCase();
    return this.catalog.templates.filter((item:ComposerTemplate)=>(item.id+' '+item.title+' '+item.description).toLowerCase().includes(term));
  }
  private matches(id:string,title:string):boolean {const term=this.query.trim().toLowerCase();return !term || (id+' '+title).toLowerCase().includes(term);}
  private async useTemplate(text:string):Promise<void> {
    if(this.working)return;this.working='template';this.actionNotice='';
    try {await this.onTemplate(this.conversation,this.generation,text);}catch(error){if(!this.closed)this.actionNotice=this.copy(error as Error);}
    finally {if(!this.closed)this.working='';}
  }
  private async chooseTone(id:string):Promise<void> {
    if(this.working || !this.connected)return;this.working='tone';this.actionNotice='';
    try {await this.onTone(this.conversation,id);if(!this.closed)await this.loadState();}
    catch(error){if(!this.closed)this.actionNotice=this.copy(error as Error);}
    finally {if(!this.closed)this.working='';}
  }
  private async start():Promise<void> {
    if(this.working || this.busy || this.metadata.busy || !this.connected || !this.realModel || !this.intentReady)return;
    this.working='compact';this.actionNotice='';
    try {
      if(!this.pending) {
        this.pending={operation_id:previewMode()?'compact-'+Date.now().toString(36)+'-'+(++commandSequence)+'-'+Math.random().toString(36).substring(2,12):util.generateRandomUUID(true),
          model:this.model,effort:this.effort};
        await this.local.put('compact-operation',this.conversation,JSON.stringify(this.pending));
      }
      await this.onCompact(this.conversation,this.generation,this.pending.operation_id,this.pending.model,this.pending.effort);
      if(!this.closed){this.pending=undefined;await this.loadState();}
    } catch(error) {
      if(!this.closed){this.actionNotice=this.copy(error as Error);await this.loadState();}
    } finally {if(!this.closed)this.working='';}
  }
  private active(record:CompactionRecord | null):boolean {return record!==null && ['queued','running','stopping'].includes(record.status);}
  private resultTitle():string {
    const previous=this.metadata.active_compaction?.id!==this.metadata.latest_compaction?.id;
    return this.metadata.active_compaction?.method==='native'?(previous?'上次整理结果':'整理结果'):(previous?'上一份交接':'这一页的交接');
  }
  private async stop():Promise<void> {
    const run=this.metadata.latest_compaction?.run_id;
    if(!run || this.working)return;this.working='stop';this.actionNotice='';
    try {await this.onStop(run);if(!this.closed)await this.loadState();}
    catch(error){if(!this.closed)this.actionNotice=this.copy(error as Error);}
    finally {if(!this.closed)this.working='';}
  }
  private notice():string {return this.actionNotice || (this.tab==='templates'?this.catalogNotice:this.stateNotice);}
  private retry():void {if(this.tab==='templates')this.loadCatalog();else if(!this.intentReady)this.initializeState();else this.loadState();}

  @Builder
  private Tab(title:string,id:string) {
    Button(title).fontSize(14).height(40).fontColor(this.tab===id?this.colors.background:this.colors.secondary)
      .backgroundColor(this.tab===id?this.colors.accent:Color.Transparent).padding({left:14,right:14}).onClick(()=>this.activate(id))
  }
  @Builder
  private Compaction() {
    Column({space:16}) {
      if(this.metadata.latest_compaction?.status==='verifying') {
        Text('整理命令已完成，继续对话后核对实际用量。').fontSize(15).lineHeight(25).fontColor(this.colors.secondary).width('100%')
        Button('回到对话').fontSize(15).height(46).fontColor(this.colors.background).backgroundColor(this.colors.accent).onClick(()=>this.onClose())
      } else if(this.active(this.metadata.latest_compaction)) {
        Row({space:12}) {
          LoadingProgress().width(24).height(24).color(this.colors.accent)
          Text(this.metadata.latest_compaction?.status==='stopping'?'正在停笔':'正在整理上下文…').fontSize(16).fontColor(this.colors.text).layoutWeight(1)
          Button('停笔').fontColor(this.colors.danger).backgroundColor(this.colors.surface).height(44).enabled(!this.working).onClick(()=>this.stop())
        }.width('100%')
      } else {
        if(this.metadata.latest_compaction && !this.metadata.latest_compaction.activated_at)
          Text(this.metadata.latest_compaction.status==='stopped'?'这次整理已停笔，原始记录已保留。':this.metadata.latest_compaction.failure || '这一份还没有确认完成，原始记录仍在。').fontSize(14).lineHeight(23).fontColor(this.colors.secondary).width('100%')
        if(!this.realModel) Text('接回真实模型后，再来整理这一页。').fontSize(14).fontColor(this.colors.secondary).width('100%')
        else if(!this.metadata.has_history) Text('这一页还没有需要整理的对话。').fontSize(14).fontColor(this.colors.secondary).width('100%')
        else {
          if(!this.metadata.latest_compaction || this.metadata.latest_compaction.activated_at)
            Text(this.metadata.active_compaction?.method==='native'?'保留当前乐章与原始记录，在同一会话中继续。':'保留原始记录，让后续对话从交接和新消息继续。').fontSize(15).lineHeight(25).fontColor(this.colors.secondary).width('100%')
          Button(this.working==='compact'?'正在送出…':this.metadata.latest_compaction?'再整理一次':'整理长上下文')
            .fontSize(15).height(46).fontColor(this.colors.background).backgroundColor(this.colors.accent)
            .enabled(!this.working && this.connected && this.intentReady && !this.busy && !this.metadata.busy).onClick(()=>this.start())
          if(this.busy || this.metadata.busy) Text('这一段还在写，写完或停笔后再整理。').fontSize(13).lineHeight(21).fontColor(this.colors.secondary).width('100%')
        }
      }
      if(this.metadata.active_compaction) Column({space:12}) {
        Text(this.resultTitle()).fontSize(17).fontColor(this.colors.text).width('100%')
        if(this.metadata.active_compaction.tokens_before!==null && this.metadata.active_compaction.tokens_before!==undefined && this.metadata.active_compaction.tokens_after!==null && this.metadata.active_compaction.tokens_after!==undefined)
          Text(String(this.metadata.active_compaction.tokens_before)+' → '+String(this.metadata.active_compaction.tokens_after)+' tokens').fontSize(13).fontColor(this.colors.accent).width('100%')
        Text(this.metadata.active_compaction.summary).fontSize(14).lineHeight(23).fontColor(this.colors.secondary).maxLines(5).textOverflow({overflow:TextOverflow.Ellipsis}).width('100%')
        Row({space:12}) {
          Button(this.metadata.active_compaction.method==='native'?'查看结果':'翻阅交接').fontSize(14).fontColor(this.colors.accent).backgroundColor(this.colors.surface).height(44)
            .onClick(()=>{if(this.metadata.active_compaction)this.onSummary(this.metadata.active_compaction);})
          if(this.metadata.active_compaction.archive) Button('原始记录').fontSize(14).fontColor(this.colors.accent).backgroundColor(this.colors.surface).height(44)
            .onClick(()=>{const file=this.metadata.active_compaction?.archive;if(file)this.onArchive(file);})
        }.width('100%')
      }.width('100%').padding(16).backgroundColor(this.colors.surface).borderRadius(18)
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Column({space:0}) {
      Row({space:12}) {
        Text('换一种起笔').fontSize(21).fontColor(this.colors.text).layoutWeight(1)
        Button('返回').fontSize(14).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44).onClick(()=>this.onClose())
      }.width('100%').padding({left:22,right:12,top:12,bottom:8})
      Row({space:8}) {this.Tab('常用起笔','templates');this.Tab('乐章语气','tone');this.Tab('整理上下文','compact');}
        .width('100%').padding({left:18,right:18,bottom:12})
      if(this.tab==='templates') TextInput({text:this.query,placeholder:'找一种起笔'})
        .id('command-query').fontSize(15).fontColor(this.colors.text).placeholderColor(this.colors.secondary).backgroundColor(this.colors.raised)
        .height(46).maxLength(32).defaultFocus(true).onChange((value:string)=>{this.query=value;})
        .onAppear(()=>{this.getUIContext().getFocusController().requestFocus('command-query');})
        .margin({left:20,right:20,bottom:12})
      if(this.notice()) Row({space:8}) {
        Text(this.notice()).fontSize(13).lineHeight(21).fontColor(this.colors.secondary).layoutWeight(1)
        Button('重试').fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44).enabled(!this.working)
          .onClick(()=>{if(this.pending && this.tab==='compact')this.start();else this.retry();})
      }.width('100%').padding({left:22,right:12,bottom:8})
      Scroll() {
        Column({space:12}) {
          if(this.tab==='templates') {
            ForEach(this.templates(),(item:ComposerTemplate)=>{
              Button() {
                Column({space:7}) {
                  Text(item.title).fontSize(17).fontColor(this.colors.text)
                  Text(item.description).fontSize(13).lineHeight(21).fontColor(this.colors.secondary)
                }.width('100%').alignItems(HorizontalAlign.Start).padding(18)
              }.width('100%').backgroundColor(this.colors.surface).borderRadius(18).enabled(!this.working).onClick(()=>this.useTemplate(item.text))
            },(item:ComposerTemplate)=>item.id)
            if(this.query.trim() && this.matches('tone','乐章语气')) Button('换一种语气').fontSize(15).height(46).fontColor(this.colors.accent).backgroundColor(this.colors.surface).width('100%').onClick(()=>this.activate('tone'))
            if(this.query.trim() && this.matches('compact','整理长上下文')) Button('整理长上下文').fontSize(15).height(46).fontColor(this.colors.accent).backgroundColor(this.colors.surface).width('100%').onClick(()=>this.activate('compact'))
            if(!this.catalogLoading && this.templates().length===0 && !this.matches('tone','乐章语气') && !this.matches('compact','整理长上下文') && !this.catalogNotice)
              Text('没有匹配的起笔。').fontSize(14).fontColor(this.colors.secondary).padding(18)
            if(this.catalogLoading && this.catalog.templates.length===0) LoadingProgress().width(26).height(26).color(this.colors.accent)
          } else if(this.tab==='tone') {
            ForEach(this.catalog.tones,(item:ToneOption)=>{
              Button() {
                Row({space:12}) {
                  Column({space:7}) {
                    Text(item.title).fontSize(17).fontColor(this.colors.text)
                    Text(item.description).fontSize(13).lineHeight(21).fontColor(this.colors.secondary)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  if(item.id===(this.metadata.tone_id || this.currentTone)) Text('已选').fontSize(12).fontColor(this.colors.accent)
                }.width('100%').padding(18)
              }.width('100%').backgroundColor(this.colors.surface).borderRadius(18).enabled(this.connected && !this.working).onClick(()=>this.chooseTone(item.id))
            },(item:ToneOption)=>item.id)
            if((this.stateLoading || this.catalogLoading) && this.catalog.tones.length===0) LoadingProgress().width(26).height(26).color(this.colors.accent)
          } else {
            if(this.stateKnown)this.Compaction()
            else if(this.stateLoading) LoadingProgress().width(26).height(26).color(this.colors.accent)
          }
        }.width('100%').padding({left:20,right:20,top:4,bottom:24})
      }.layoutWeight(1).width('100%').align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor(this.colors.background)
  }
}
