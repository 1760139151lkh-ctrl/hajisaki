import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { ModelPicker } from './ModelPicker';
import { Palette } from '../design/Theme';
import { Artifact, ModelOption } from '../model/Types';
import { ThreadRecord, ThreadPage, ArenaRecord, ArenaPage, ArenaDraft, ArenaResult } from '../model/BranchTypes';
import { Gateway, GatewayError } from '../services/Gateway';
import { LocalStore } from '../services/LocalStore';
import { previewMode } from '../model/BuildMode';

interface SavedArenaDraft { content:string; files:Artifact[]; modelA:string; modelB:string; effortA:string; effortB:string }
let arenaSequence:number=0;

@Component
export struct BranchRoom {
  @Prop colors:Palette=new Palette();
  @Prop models:ModelOption[]=[];
  @Prop realModel:boolean=true;
  gateway:Gateway=new Gateway();
  local:LocalStore=new LocalStore();
  conversationId:string='';
  initialDraft:string='';
  initialFiles:Artifact[]=[];
  initialModel:string='default';
  initialEffort:string='medium';
  initialTab:string='threads';
  onClose:()=>void=()=>{};
  onThread:(id:string)=>Promise<void>=async()=>{};
  onArena:(id:string)=>void=()=>{};
  onFile:(file:Artifact)=>void=()=>{};
  @State tab:string='threads';
  @State threads:ThreadRecord[]=[];
  @State arenas:ArenaRecord[]=[];
  @State composing:boolean=false;
  @State content:string='';
  @State files:Artifact[]=[];
  @State modelA:string='';
  @State modelB:string='';
  @State effortA:string='';
  @State effortB:string='';
  @State notice:string='';
  @State loading:boolean=false;
  @State working:boolean=false;
  @State pending:boolean=false;
  private operation:ArenaDraft | undefined=undefined;
  private closed:boolean=false;
  private ready:boolean=false;

  aboutToAppear():void {this.tab=this.initialTab;this.initialize();}
  aboutToDisappear():void {this.closed=true;}
  private choices():ModelOption[] {const explicit=this.models.filter((model:ModelOption)=>model.id!=='default');return explicit.length?explicit:this.models;}
  private copy(error:Error):string {return error instanceof GatewayError?error.message:'这一页暂时没有接好，原来的草稿仍在。';}
  private async initialize():Promise<void> {
    try {
      const saved=await this.local.get('arena-compose',this.conversationId,'');
      const operation=await this.local.get('arena-operation',this.conversationId,'');
      if(this.closed)return;
      const options=this.choices();
      const first=options.find((model:ModelOption)=>model.id===this.initialModel) || options.find((model:ModelOption)=>model.efforts.includes(this.initialEffort)) || options[0];
      const second=options.find((model:ModelOption)=>model.id!==first?.id && model.efforts.includes('low')) || options.find((model:ModelOption)=>model.id!==first?.id);
      this.content=this.initialDraft;this.files=this.initialFiles.slice();this.modelA=first?.id || '';this.effortA=first?.efforts[0] || '';
      this.modelB=second?.id || '';this.effortB=second?.efforts[0] || '';
      if(saved) {
        const draft=JSON.parse(saved) as SavedArenaDraft;
        this.content=draft.content;this.files=draft.files;this.modelA=draft.modelA;this.modelB=draft.modelB;this.effortA=draft.effortA;this.effortB=draft.effortB;
      }
      if(operation) {
        this.operation=JSON.parse(operation) as ArenaDraft;this.pending=true;this.composing=true;this.tab='arenas';
        this.content=this.operation.content;this.modelA=this.operation.choices[0].model;this.effortA=this.operation.choices[0].effort;
        this.modelB=this.operation.choices[1].model;this.effortB=this.operation.choices[1].effort;
      }
      this.ready=true;await this.load();
    } catch(error){if(!this.closed)this.notice=this.copy(error as Error);}
  }
  private saveDraft():void {
    if(!this.ready || this.pending)return;
    const saved:SavedArenaDraft={content:this.content,files:this.files,modelA:this.modelA,modelB:this.modelB,effortA:this.effortA,effortB:this.effortB};
    this.local.put('arena-compose',this.conversationId,JSON.stringify(saved)).catch((error:Error)=>{if(!this.closed)this.notice=this.copy(error);});
  }
  private async load():Promise<void> {
    if(this.loading)return;this.loading=true;this.notice='';
    try {
      const cachedThreads=await this.local.get('thread-list',this.conversationId,'');
      const cachedArenas=await this.local.get('arena-list',this.conversationId,'');
      if(this.closed)return;
      if(cachedThreads)this.threads=(JSON.parse(cachedThreads) as ThreadPage).threads;
      if(cachedArenas)this.arenas=(JSON.parse(cachedArenas) as ArenaPage).arenas;
      const threads=await this.gateway.request<ThreadPage>('/api/conversations/'+encodeURIComponent(this.conversationId)+'/threads');
      const arenas=await this.gateway.request<ArenaPage>('/api/conversations/'+encodeURIComponent(this.conversationId)+'/arenas');
      if(this.closed)return;this.threads=threads.threads;this.arenas=arenas.arenas;
      await this.local.put('thread-list',this.conversationId,JSON.stringify(threads));
      await this.local.put('arena-list',this.conversationId,JSON.stringify(arenas));
      if(this.operation) {
        const prior=arenas.arenas.find((item:ArenaRecord)=>item.client_id===this.operation?.client_id);
        if(prior){await this.local.put('arena-operation',this.conversationId,'');await this.local.put('arena-compose',this.conversationId,'');this.operation=undefined;this.pending=false;this.composing=false;}
      }
    } catch(error){if(!this.closed)this.notice=this.copy(error as Error);}
    finally {if(!this.closed)this.loading=false;}
  }
  private distinct():boolean {return !!this.modelA && !!this.modelB && !!this.effortA && !!this.effortB && (this.modelA!==this.modelB || this.effortA!==this.effortB);}
  private async begin():Promise<void> {
    if(this.working || !this.ready || !this.realModel || !this.distinct() || (!this.content.trim() && !this.files.length) || this.files.length>20)return;
    this.working=true;this.notice='';
    try {
      if(!this.operation) {
        this.operation={content:this.content,choices:[{model:this.modelA,effort:this.effortA},{model:this.modelB,effort:this.effortB}],
          client_id:previewMode()?'arena-'+Date.now().toString(36)+'-'+(++arenaSequence)+'-'+Math.random().toString(36).substring(2,12):util.generateRandomUUID(true),
          attachments:this.files.map((file:Artifact)=>file.id)};
        await this.local.put('arena-operation',this.conversationId,JSON.stringify(this.operation));this.pending=true;
      }
      const record=await this.gateway.request<ArenaResult>('/api/conversations/'+encodeURIComponent(this.conversationId)+'/arenas',
        http.RequestMethod.POST,JSON.stringify(this.operation));
      await this.local.put('arena-result',record.id,JSON.stringify(record));
      await this.local.put('arena-operation',this.conversationId,'');
      await this.local.put('arena-compose',this.conversationId,'');
      this.operation=undefined;this.pending=false;
      if(!this.closed)this.onArena(record.id);
    } catch(error) {
      if(error instanceof GatewayError && !error.outcomeUncertain && error.status>=400 && error.status<500) {
        await this.local.put('arena-operation',this.conversationId,'');this.operation=undefined;this.pending=false;
      }
      if(!this.closed)this.notice=this.copy(error as Error);
    } finally {if(!this.closed)this.working=false;}
  }
  private async openThread(id:string):Promise<void> {
    if(this.working)return;this.working=true;this.notice='';
    try {await this.onThread(id);}catch(error){if(!this.closed)this.notice=this.copy(error as Error);}
    finally {if(!this.closed)this.working=false;}
  }
  @Builder
  private ModelChoice(title:string,first:boolean) {
    Column({space:8}) {
      Text(title).fontSize(14).fontColor(this.colors.text).width('100%')
      ModelPicker({colors:this.colors,models:this.models,model:first?this.modelA:this.modelB,effort:first?this.effortA:this.effortB,
        interactive:!this.pending && !this.working,onSelect:(model:string,effort:string)=>{
          if(first){this.modelA=model;this.effortA=effort;}else{this.modelB=model;this.effortB=effort;}this.saveDraft();
        }})
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
  build() {
    Column({space:0}) {
      Row() {
        Text(this.composing?'同题对照':'分支乐章').fontSize(21).fontColor(this.colors.text).layoutWeight(1)
        Button('返回').fontSize(14).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
          .onClick(()=>{if(this.composing && !this.pending)this.composing=false;else this.onClose();})
      }.width('100%').padding({left:22,right:12,top:12,bottom:8})
      if(this.notice) Row({space:8}) {
        Text(this.notice).fontSize(13).lineHeight(21).fontColor(this.colors.secondary).layoutWeight(1)
        Button('重试').fontSize(13).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent).enabled(!this.working && !this.loading)
          .onClick(()=>{if(this.pending)this.begin();else this.load();})
      }.width('100%').padding({left:22,right:12,bottom:8})
      if(!this.composing) Row({space:10}) {
        Button('附页').fontSize(14).height(40).layoutWeight(1).fontColor(this.tab==='threads'?this.colors.background:this.colors.accent)
          .backgroundColor(this.tab==='threads'?this.colors.accent:this.colors.surface).onClick(()=>{this.tab='threads';})
        Button('对照').fontSize(14).height(40).layoutWeight(1).fontColor(this.tab==='arenas'?this.colors.background:this.colors.accent)
          .backgroundColor(this.tab==='arenas'?this.colors.accent:this.colors.surface).onClick(()=>{this.tab='arenas';})
      }.width('100%').padding({left:22,right:22,bottom:16})
      Scroll() {
        Column({space:18}) {
          if(this.composing) {
            TextArea({text:this.content,placeholder:'同一道题，让两份回答各自展开…'}).fontSize(16).fontColor(this.colors.text)
              .placeholderColor(this.colors.secondary).backgroundColor(this.colors.surface).constraintSize({minHeight:130,maxHeight:240})
              .enabled(!this.pending && !this.working).onChange((value:string)=>{this.content=value;this.saveDraft();})
            ForEach(this.files,(file:Artifact)=>{
              Row({space:8}) {
                Button(file.name).fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).layoutWeight(1).onClick(()=>this.onFile(file))
                Button('×').fontSize(20).width(44).height(44).padding(0).fontColor(this.colors.secondary).backgroundColor(Color.Transparent)
                  .enabled(!this.pending && !this.working).onClick(()=>{this.files=this.files.filter((item:Artifact)=>item.id!==file.id);this.saveDraft();})
              }.width('100%')
            },(file:Artifact)=>file.id)
            this.ModelChoice('第一份',true)
            this.ModelChoice('第二份',false)
            if(!this.distinct() && this.modelA && this.modelB) Text('选两种不同的模型或思考档位。').fontSize(13).fontColor(this.colors.secondary).width('100%')
            if(this.files.length>20) Text('这份对照最多带二十个原件，先收起几份再开始。').fontSize(13).fontColor(this.colors.secondary).width('100%')
            if(!this.realModel) Text('接回真实模型后，再听听两份回答。').fontSize(13).fontColor(this.colors.secondary).width('100%')
            Button(this.working?'正在送出…':this.pending?'接回这次对照':'开始盲选对照').fontSize(15).height(46).fontColor(this.colors.background).backgroundColor(this.colors.accent)
              .enabled(this.ready && this.realModel && this.distinct() && !this.working && (this.content.trim().length>0 || this.files.length>0) && this.files.length<=20).onClick(()=>this.begin())
          } else if(this.tab==='threads') {
            ForEach(this.threads,(item:ThreadRecord)=>{
              Button() { Column({space:8}) {
                Text(item.title || '附页').fontSize(16).fontColor(this.colors.text).width('100%')
                Text(item.quote).fontSize(13).lineHeight(23).fontColor(this.colors.secondary).maxLines(4).textOverflow({overflow:TextOverflow.Ellipsis}).width('100%')
              }.padding(18).width('100%').alignItems(HorizontalAlign.Start) }.width('100%').backgroundColor(this.colors.surface).borderRadius(18)
                .enabled(!this.working).onClick(()=>this.openThread(item.id))
            },(item:ThreadRecord)=>item.id)
            if(!this.threads.length && !this.loading && !this.notice) Text('从回复的“选文”留一句，便能在这里接着聊。').fontSize(14).lineHeight(23).fontColor(this.colors.secondary).width('100%')
          } else {
            Button('同题对照').fontSize(15).height(46).fontColor(this.colors.background).backgroundColor(this.colors.accent)
              .enabled(this.ready).onClick(()=>{this.composing=true;this.saveDraft();})
            ForEach(this.arenas,(item:ArenaRecord)=>{
              Button() { Column({space:8}) {
                Text(item.content || '带着原件的一题').fontSize(16).lineHeight(25).fontColor(this.colors.text).maxLines(4).textOverflow({overflow:TextOverflow.Ellipsis}).width('100%')
                if(item.choice) Text(item.choice==='tie'?'难分高下':'已选 '+item.choice).fontSize(12).fontColor(this.colors.gold)
              }.padding(18).width('100%').alignItems(HorizontalAlign.Start) }.width('100%').backgroundColor(this.colors.surface).borderRadius(18).onClick(()=>this.onArena(item.id))
            },(item:ArenaRecord)=>item.id)
          }
          if(this.loading && !this.threads.length && !this.arenas.length) LoadingProgress().width(28).height(28).color(this.colors.accent)
        }.width('100%').padding({left:22,right:22,top:4,bottom:24}).alignItems(HorizontalAlign.Start)
      }.width('100%').layoutWeight(1).align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor(this.colors.background)
  }
}
