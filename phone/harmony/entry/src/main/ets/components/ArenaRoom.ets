import { http } from '@kit.NetworkKit';
import { Palette } from '../design/Theme';
import { Artifact, Message, ModelOption, StreamEvent } from '../model/Types';
import { ArenaResult, ArenaSide } from '../model/BranchTypes';
import { Gateway, GatewayError } from '../services/Gateway';
import { EventStream } from '../services/EventStream';
import { LocalStore } from '../services/LocalStore';
import { Manuscript } from './Manuscript';
import { selectedFamily, strengthName } from '../model/ModelFamilies';

@Observed
class ArenaSideState { item:ArenaSide; constructor(item:ArenaSide){this.item=item;} }

function activeSide(status:string):boolean {return ['preparing','queued','running','streaming','stopping'].includes(status);}

@Component
struct ArenaAnswer {
  @ObjectLink state:ArenaSideState;
  @Prop colors:Palette=new Palette();
  @Prop revealed:boolean=false;
  @Prop models:ModelOption[]=[];
  onFile:(file:Artifact)=>void=()=>{};
  onContinue:(side:ArenaSide)=>void=()=>{};
  @State readingLock:boolean=false;
  private scroll:Scroller=new Scroller();
  private body():string {return this.state.item.messages.map((message:Message)=>message.content).join('\n\n');}
  private label():string {return selectedFamily(this.models,this.state.item.model || '').name;}
  private status():string {
    const value=this.state.item.status;
    return value==='stopped'?'已停笔':value==='failed'||value==='interrupted'?'这一份尚未完成':value==='preparing'?'正在接好':value==='not_started'?'未开始':value==='queued'?'等待开始':value==='stopping'?'正在停笔':activeSide(value)?'正在写…':'';
  }
  build() {
    Column({space:0}) {
      Row({space:12}) {
        Text(this.state.item.side).fontSize(24).fontColor(this.colors.accent)
        if(this.revealed) Text(this.label()).fontSize(13).fontColor(this.colors.secondary).maxLines(2).layoutWeight(1)
        else Blank()
        if(this.status()) Text(this.status()).fontSize(12).fontColor(this.colors.secondary)
      }.width('100%').padding({left:22,right:22,top:12,bottom:12})
      if(this.revealed && this.state.item.effort) Text('思考强度 · '+strengthName(this.state.item.effort)).fontSize(12).fontColor(this.colors.secondary).width('100%').padding({left:22,right:22,bottom:8})
      Scroll(this.scroll) {
        Column({space:16}) {
          if(this.body().trim()) Manuscript({text:this.body(),colors:this.colors})
          else if(activeSide(this.state.item.status)) LoadingProgress().width(28).height(28).color(this.colors.accent)
          else Text(this.state.item.status==='stopped'?'这一份已经停笔。':'这一份还没有写下正文。').fontSize(14).lineHeight(23).fontColor(this.colors.secondary).width('100%')
          ForEach(this.state.item.messages,(message:Message)=>{
            ForEach(message.attachments,(file:Artifact)=>{
              Button(file.name).fontSize(13).fontColor(this.colors.accent).backgroundColor(this.colors.raised).height(44).onClick(()=>this.onFile(file))
            },(file:Artifact)=>file.id)
          },(message:Message)=>message.id)
          if(this.revealed && !activeSide(this.state.item.status)) Button('继续这一页').fontSize(14).height(44)
            .fontColor(this.colors.accent).backgroundColor(this.colors.raised).onClick(()=>this.onContinue(this.state.item))
        }.width('100%').padding({left:22,right:22,top:6,bottom:22})
          .onAreaChange(()=>{if(!this.readingLock)this.scroll.scrollEdge(Edge.Bottom);})
      }.width('100%').layoutWeight(1).align(Alignment.Top)
        .onScrollFrameBegin((offset:number,state:ScrollState)=>{if(offset<0 && state!==ScrollState.Idle)this.readingLock=true;return {offsetRemain:offset};})
        .onReachEnd(()=>{this.readingLock=false;})
    }.width('100%').height('100%')
  }
}

@Component
export struct ArenaRoom {
  @Prop colors:Palette=new Palette();
  @Prop models:ModelOption[]=[];
  gateway:Gateway=new Gateway();
  local:LocalStore=new LocalStore();
  arenaId:string='';
  onClose:()=>void=()=>{};
  onFile:(file:Artifact)=>void=()=>{};
  onContinue:(side:ArenaSide,parent:string)=>Promise<void>=async()=>{};
  @StorageLink('foreground') @Watch('foregroundChanged') foreground:boolean=true;
  @State record:ArenaResult | undefined=undefined;
  @State sides:ArenaSideState[]=[];
  @State notice:string='';
  @State loading:boolean=false;
  @State working:string='';
  @State connected:boolean=false;
  @State selected:number=0;
  @State questionOpen:boolean=false;
  private closed:boolean=false;
  private timer:number=-1;
  private flushTimer:number=-1;
  private flushing:boolean=false;
  private queue:StreamEvent[]=[];
  private streams:Map<string,EventStream>=new Map();
  private fetching:Promise<void> | undefined=undefined;
  private metadataVersion:number=0;

  aboutToAppear():void {this.initialize();this.timer=setInterval(()=>{
    const missing=this.sides.some((state:ArenaSideState)=>activeSide(state.item.status) && !this.streams.has(state.item.conversation_id));
    if(this.foreground && !this.working && !this.loading && (!this.record || !this.connected || missing))this.load();
  },2000);}
  aboutToDisappear():void {this.closed=true;this.stopStreams();if(this.timer>=0)clearInterval(this.timer);}
  private foregroundChanged():void {if(this.foreground)this.load();else this.stopStreams();}
  private copy(error:Error):string {return error instanceof GatewayError?error.message:'这一组暂时没有接好，已写下的回答仍在。';}
  private stopStreams():void {this.streams.forEach((stream:EventStream)=>stream.close());this.streams.clear();if(this.flushTimer>=0)clearTimeout(this.flushTimer);this.flushTimer=-1;this.queue=[];}
  private async initialize():Promise<void> {
    try {const saved=await this.local.get('arena-result',this.arenaId,'');if(!this.closed && saved)this.apply(JSON.parse(saved) as ArenaResult);}catch (_) {}
    if(!this.closed)this.load();
  }
  private withSides(record:ArenaResult,sides:ArenaSide[]):ArenaResult {
    return {id:record.id,parent_id:record.parent_id,client_id:record.client_id,content:record.content,created_at:record.created_at,
      revealed:record.revealed,choice:record.choice,stopped_at:record.stopped_at,attachments:record.attachments,sides:sides};
  }
  private copySide(side:ArenaSide,messages:Message[],cursor:number,status:string):ArenaSide {
    return {side:side.side,conversation_id:side.conversation_id,run_id:side.run_id,status:status,cursor:cursor,messages:messages,
      question_message_id:side.question_message_id,question_created_at:side.question_created_at,model:side.model,effort:side.effort};
  }
  private apply(record:ArenaResult):void {
    const states:ArenaSideState[]=[];
    for(const side of record.sides) {
      const prior=this.sides.find((item:ArenaSideState)=>item.item.conversation_id===side.conversation_id);
      if(prior) {
        if(prior.item.cursor>side.cursor) {
          const value=this.copySide(prior.item,prior.item.messages,prior.item.cursor,prior.item.status);
          value.model=record.revealed?(side.model || prior.item.model):undefined;
          value.effort=record.revealed?(side.effort || prior.item.effort):undefined;prior.item=value;
        } else {
          const value=this.copySide(side,side.messages,side.cursor,side.status);
          value.model=record.revealed?(side.model || prior.item.model):undefined;
          value.effort=record.revealed?(side.effort || prior.item.effort):undefined;prior.item=value;
        }
        states.push(prior);
      } else states.push(new ArenaSideState(side));
    }
    this.sides=states;this.record=this.withSides(record,states.map((item:ArenaSideState)=>item.item));
  }
  private load():Promise<void> {
    if(this.fetching)return this.fetching;
    this.fetching=this.fetch();
    this.fetching.then(()=>{this.fetching=undefined;});
    return this.fetching;
  }
  private async fetch():Promise<void> {
    if(this.closed)return;this.loading=true;
    const version=this.metadataVersion;
    try {
      let record=await this.gateway.request<ArenaResult>('/api/arenas/'+encodeURIComponent(this.arenaId));
      if(this.closed)return;
      if(version!==this.metadataVersion && this.record)record=this.withSides(this.record,record.sides);
      this.apply(record);this.connected=true;this.notice='';
      await this.persist();this.connectStreams();
    } catch(error) {if(!this.closed){this.connected=false;this.notice=this.copy(error as Error);}}
    finally {if(!this.closed)this.loading=false;}
  }
  private async persist():Promise<void> {
    const record=this.record;if(!record)return;
    await this.local.put('arena-result',this.arenaId,JSON.stringify(record));
    for(const side of record.sides) {
      if(!activeSide(side.status) && side.question_message_id && (await this.local.messages(side.conversation_id)).length===0) {
        const question:Message={id:side.question_message_id,conversation_id:side.conversation_id,role:'user',content:record.content,
          status:'completed',created_at:side.question_created_at,attachments:record.attachments};
        await this.local.savePrefetchedMessages(side.conversation_id,[question].concat(side.messages),side.cursor);
      }
    }
  }
  private connectStreams():void {
    if(!this.foreground || this.closed || !this.gateway.canStreamDirectly())return;
    for(const state of this.sides) {
      const side=state.item;
      if(!side.run_id || !activeSide(side.status) || this.streams.has(side.conversation_id))continue;
      const stream=new EventStream();this.streams.set(side.conversation_id,stream);
      stream.onEvent=(event:StreamEvent)=>{if(!this.closed){this.queue.push(event);this.schedule();}};
      stream.onDisconnect=()=>{this.streams.delete(side.conversation_id);};
      stream.open(this.gateway,side.conversation_id,side.cursor);
    }
  }
  private schedule():void {if(this.flushTimer<0)this.flushTimer=setTimeout(()=>{this.flushTimer=-1;this.flush();},12);}
  private async flush():Promise<void> {
    if(this.flushing){this.schedule();return;}if(!this.record || this.closed || !this.queue.length)return;
    this.flushing=true;const received=this.queue;this.queue=[];
    try {
      if(received.some((event:StreamEvent)=>event.layer==='L4' || event.kind==='message_created')) {
        await this.load();if(!this.connected)throw new Error('这一份还没有补齐。');
      }
      const next:ArenaSide[]=[];
      for(const state of this.sides) {
        const side=state.item;
        const batch=received.filter((event:StreamEvent)=>event.conversation_id===side.conversation_id && event.seq>side.cursor).sort((a:StreamEvent,b:StreamEvent)=>a.seq-b.seq);
        if(!batch.length){next.push(side);continue;}
        const messages=side.messages.map((message:Message):Message=>{return {id:message.id,conversation_id:message.conversation_id,role:message.role,
          content:message.content,status:message.status,created_at:message.created_at,attachments:message.attachments};});
        let status=side.status,cursor=side.cursor;
        for(const event of batch) {
          if(event.seq<=cursor)continue;cursor=event.seq;
          if(event.run_id!==side.run_id)continue;
          const message=messages.find((message:Message)=>message.id===event.payload.message_id);
          if(event.kind==='reply_delta' && message)message.content+=event.payload.text || '';
          if(event.kind==='run_started'){status='running';if(message)message.status='streaming';}
          if(['run_finished','run_failed','run_stopped'].includes(event.kind)) {
            status=event.payload.status || (event.kind==='run_failed'?'failed':event.kind==='run_stopped'?'stopped':'completed');
            if(message)message.status=status;
          }
        }
        next.push(this.copySide(side,messages,cursor,status));
      }
      const record=this.withSides(this.record,next);
      // Commit the paired answers and their cursors before acknowledging the UI.
      await this.local.put('arena-result',this.arenaId,JSON.stringify(record));
      if(this.closed)return;
      this.apply(this.withSides(this.record,next));
      for(const side of next)if(!activeSide(side.status)){this.streams.get(side.conversation_id)?.close();this.streams.delete(side.conversation_id);}
      if(next.every((side:ArenaSide)=>!activeSide(side.status)))await this.persist();
    } catch(error) {if(!this.closed){this.notice=this.copy(error as Error);this.connected=false;this.stopStreams();}}
    finally {this.flushing=false;if(this.queue.length)this.schedule();}
  }
  private busy():boolean {return this.sides.some((state:ArenaSideState)=>activeSide(state.item.status));}
  private preparing():boolean {return this.sides.some((state:ArenaSideState)=>state.item.status==='preparing');}
  private async action(action:string,choice:string=''):Promise<void> {
    if(this.working)return;this.working=action;this.notice='';
    this.metadataVersion++;
    try {
      const record=await this.gateway.request<ArenaResult>('/api/arenas/'+encodeURIComponent(this.arenaId)+'/'+action,
        http.RequestMethod.POST,choice?JSON.stringify({choice:choice}):'{}');
      if(this.closed)return;this.apply(record);this.connected=true;await this.persist();this.connectStreams();
    } catch(error){if(!this.closed)this.notice=this.copy(error as Error);}
    finally {if(!this.closed)this.working='';}
  }
  private async continueSide(side:ArenaSide):Promise<void> {
    if(!this.record || this.working)return;this.working='continue';
    try {await this.onContinue(side,this.record.parent_id);}catch(error){if(!this.closed)this.notice=this.copy(error as Error);}
    finally {if(!this.closed)this.working='';}
  }
  build() {
    Column({space:0}) {
      Row() {
        Text('对照乐章').fontSize(21).fontColor(this.colors.text).layoutWeight(1)
        Button(this.questionOpen?'回到回答':'返回').height(44).fontSize(14).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
          .onClick(()=>{if(this.questionOpen)this.questionOpen=false;else this.onClose();})
      }.width('100%').padding({left:22,right:12,top:12,bottom:8})
      if(this.notice) Row({space:8}) {
        Text(this.notice).fontSize(13).lineHeight(21).fontColor(this.colors.secondary).layoutWeight(1)
        Button('重试').height(44).fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).enabled(!this.working && !this.loading).onClick(()=>this.load())
      }.width('100%').padding({left:22,right:12,bottom:8})
      if(this.record) {
        if(this.questionOpen) Scroll() {
          Column({space:16}) {
            Text(this.record.content).fontSize(16).lineHeight(28).fontColor(this.colors.text).width('100%').copyOption(CopyOptions.InApp)
            ForEach(this.record.attachments,(file:Artifact)=>{Button(file.name).fontSize(13).height(44).fontColor(this.colors.accent).backgroundColor(this.colors.surface).onClick(()=>this.onFile(file));},(file:Artifact)=>file.id)
          }.padding(22).width('100%')
        }.layoutWeight(1).width('100%').align(Alignment.Top)
        else {
          Button() { Row({space:10}) {
            Text(this.record.content || '原件').fontSize(13).lineHeight(22).fontColor(this.colors.secondary).maxLines(3).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1)
            Text('›').fontSize(22).fontColor(this.colors.accent)
          }.width('100%') }.width('100%').padding({left:22,right:22,bottom:12}).backgroundColor(Color.Transparent).onClick(()=>{this.questionOpen=true;})
          Row({space:10}) {
            Button('A').fontSize(15).height(40).layoutWeight(1).fontColor(this.selected===0?this.colors.background:this.colors.accent)
              .backgroundColor(this.selected===0?this.colors.accent:this.colors.surface).onClick(()=>{this.selected=0;})
            Button('B').fontSize(15).height(40).layoutWeight(1).fontColor(this.selected===1?this.colors.background:this.colors.accent)
              .backgroundColor(this.selected===1?this.colors.accent:this.colors.surface).onClick(()=>{this.selected=1;})
          }.width('100%').padding({left:22,right:22,bottom:6})
          Swiper() {
            ForEach(this.sides,(state:ArenaSideState)=>{
              ArenaAnswer({state:state,colors:this.colors,revealed:this.record?.revealed===true,models:this.models,
                onFile:this.onFile,onContinue:(side:ArenaSide)=>this.continueSide(side)})
            },(state:ArenaSideState)=>state.item.side)
          }.index(this.selected).indicator(false).loop(false).width('100%').layoutWeight(1).onChange((index:number)=>{this.selected=index;})
          if(this.record.choice) Text(this.record.choice==='tie'?'这一次，难分高下。':'这一次选了 '+this.record.choice+'。').fontSize(13).fontColor(this.colors.gold).width('100%').padding({left:22,right:22,top:8})
          Row({space:8}) {
            Button('选 A').fontSize(13).height(44).layoutWeight(1).padding(6).fontColor(this.colors.accent).backgroundColor(this.colors.surface)
              .enabled(this.connected && !this.busy() && !this.working).onClick(()=>this.action('vote','A'))
            Button('难分高下').fontSize(13).height(44).layoutWeight(1).padding(6).fontColor(this.colors.accent).backgroundColor(this.colors.surface)
              .enabled(this.connected && !this.busy() && !this.working).onClick(()=>this.action('vote','tie'))
            Button('选 B').fontSize(13).height(44).layoutWeight(1).padding(6).fontColor(this.colors.accent).backgroundColor(this.colors.surface)
              .enabled(this.connected && !this.busy() && !this.working).onClick(()=>this.action('vote','B'))
          }.width('100%').padding({left:20,right:20,top:10,bottom:8})
          Row({space:12}) {
            if(this.preparing()) Button('接好另一份').fontSize(13).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent).enabled(this.connected && !this.working).onClick(()=>this.action('resume'))
            if(!this.record.revealed) Button('揭晓模型').fontSize(13).height(44).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).enabled(this.connected && !this.working).onClick(()=>this.action('reveal'))
            Blank()
            if(this.busy()) Button('停下两份').fontSize(13).height(44).fontColor(this.colors.danger).backgroundColor(this.colors.surface).enabled(this.connected && !this.working).onClick(()=>this.action('stop'))
          }.width('100%').padding({left:14,right:20,bottom:14})
        }
      } else if(this.loading) LoadingProgress().width(28).height(28).color(this.colors.accent)
      else Blank()
    }.width('100%').height('100%').backgroundColor(this.colors.background)
  }
}
