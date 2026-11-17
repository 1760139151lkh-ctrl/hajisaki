import { util } from '@kit.ArkTS';
import { http } from '@kit.NetworkKit';
import { Palette } from '../design/Theme';
import { Conversation } from '../model/Types';
import { SelectionSource, ThreadIntent, BranchOrigin } from '../model/BranchTypes';
import { Gateway, GatewayError } from '../services/Gateway';
import { LocalStore } from '../services/LocalStore';
import { previewMode } from '../model/BuildMode';

let selectionSequence:number=0;

@Component
export struct SelectionRoom {
  @Prop colors:Palette=new Palette();
  gateway:Gateway=new Gateway();
  local:LocalStore=new LocalStore();
  messageId:string='';
  conversationId:string='';
  onQuote:(text:string)=>Promise<void>=async()=>{};
  onThread:(item:Conversation)=>Promise<void>=async()=>{};
  onClose:()=>void=()=>{};
  @State source:SelectionSource={message_id:'',conversation_id:'',text:'',source_sha256:'',status:''};
  @State quote:string='';
  @State notice:string='';
  @State loading:boolean=false;
  @State working:boolean=false;
  @State connected:boolean=false;
  private closed:boolean=false;
  private intent:ThreadIntent | undefined=undefined;

  aboutToAppear():void {this.load();}
  aboutToDisappear():void {this.closed=true;}
  private copy(error:Error):string {return error instanceof GatewayError?error.message:'这一页暂时没有接好，原来的话仍在。';}
  private async load():Promise<void> {
    if(this.loading)return;this.loading=true;this.notice='';
    try {
      const cached=await this.local.get('selection',this.messageId,'');
      const pending=await this.local.get('thread-operation',this.messageId,'');
      if(this.closed)return;
      if(cached)this.source=JSON.parse(cached) as SelectionSource;
      if(pending){this.intent=JSON.parse(pending) as ThreadIntent;this.quote=this.intent.quote;}
      const result=await this.gateway.request<SelectionSource>('/api/messages/'+encodeURIComponent(this.messageId)+'/selection');
      if(this.closed)return;
      if(!this.intent && result.source_sha256!==this.source.source_sha256)this.quote='';
      this.source=result;this.connected=true;
      await this.local.put('selection',this.messageId,JSON.stringify(result));
    } catch(error) {if(!this.closed){this.connected=false;this.notice=this.copy(error as Error);}}
    finally {if(!this.closed)this.loading=false;}
  }
  private selected(start:number,end:number):void {
    if(this.intent || this.working || start<0 || end<=start)return;
    this.quote=this.source.text.substring(start,end);
  }
  private async useQuote():Promise<void> {
    if(!this.quote.trim() || this.working)return;
    this.working=true;
    try {await this.onQuote(this.quote);}catch(error){if(!this.closed)this.notice=this.copy(error as Error);}
    finally {if(!this.closed)this.working=false;}
  }
  private async thread():Promise<void> {
    if(!this.quote.trim() || this.working || !this.connected)return;
    this.working=true;this.notice='';
    try {
      if(!this.intent) {
        this.intent={message_id:this.messageId,quote:this.quote,source_sha256:this.source.source_sha256,
          client_id:previewMode()?'thread-'+Date.now().toString(36)+'-'+(++selectionSequence)+'-'+Math.random().toString(36).substring(2,12):util.generateRandomUUID(true)};
        await this.local.put('thread-operation',this.messageId,JSON.stringify(this.intent));
      }
      const result=await this.gateway.request<Conversation>('/api/conversations/'+encodeURIComponent(this.conversationId)+'/threads',
        http.RequestMethod.POST,JSON.stringify(this.intent));
      result.branch_parent_id=this.conversationId;result.branch_kind='thread';
      await this.local.saveConversations([result]);
      const origin:BranchOrigin={thread:{id:result.id,parent_id:this.conversationId,
        source_message_id:this.messageId,quote:this.intent.quote},arena:null};
      await this.local.put('branch-origin',result.id,JSON.stringify(origin));
      await this.local.put('thread-operation',this.messageId,'');
      if(!this.closed)await this.onThread(result);
    } catch(error) {
      if(error instanceof GatewayError && !error.outcomeUncertain && error.status>=400 && error.status<500) {
        await this.local.put('thread-operation',this.messageId,'');this.intent=undefined;
      }
      if(!this.closed)this.notice=this.copy(error as Error);
    } finally {if(!this.closed)this.working=false;}
  }
  build() {
    Column({space:0}) {
      Row() {
        Text('选文').fontSize(21).fontColor(this.colors.text).layoutWeight(1)
        Button('返回').fontSize(14).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent).onClick(()=>this.onClose())
      }.width('100%').padding({left:22,right:12,top:12,bottom:8})
      if(this.notice) Row({space:8}) {
        Text(this.notice).fontSize(13).lineHeight(21).fontColor(this.colors.secondary).layoutWeight(1)
        Button('重试').height(44).fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
          .enabled(!this.loading && !this.working).onClick(()=>{if(this.intent)this.thread();else this.load();})
      }.width('100%').padding({left:22,right:12,bottom:10})
      Scroll() {
        if(this.source.text) Text(this.source.text).fontSize(16).lineHeight(28).fontColor(this.colors.text).width('100%')
          .copyOption(CopyOptions.InApp).onTextSelectionChange((start:number,end:number)=>this.selected(start,end))
          .padding(22)
        else if(this.loading) LoadingProgress().width(28).height(28).color(this.colors.accent)
      }.width('100%').layoutWeight(1).align(Alignment.Top)
      if(this.quote) Text(this.quote).fontSize(13).lineHeight(21).fontColor(this.colors.secondary)
        .maxLines(3).textOverflow({overflow:TextOverflow.Ellipsis}).width('100%').padding({left:22,right:22,top:10})
      Row({space:12}) {
        Button('引用选文').fontSize(14).height(46).fontColor(this.colors.accent).backgroundColor(this.colors.surface)
          .enabled(this.quote.trim().length>0 && !this.working).onClick(()=>this.useQuote())
        Button(this.working?'正在接好…':'开附页').fontSize(14).height(46).fontColor(this.colors.background).backgroundColor(this.colors.accent)
          .enabled(this.quote.trim().length>0 && this.quote.length<=12000 && this.connected && !this.working).onClick(()=>this.thread())
      }.width('100%').justifyContent(FlexAlign.End).padding(20)
    }.width('100%').height('100%').backgroundColor(this.colors.background)
  }
}
