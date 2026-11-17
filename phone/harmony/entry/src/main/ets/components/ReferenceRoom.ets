import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { SymbolGlyphModifier } from '@kit.ArkUI';
import { Artifact } from '../model/Types';
import { previewMode } from '../model/BuildMode';
import { Palette } from '../design/Theme';
import { Gateway,GatewayError } from '../services/Gateway';

interface ReferenceRoot { id:string; name:string; enabled:boolean; available:boolean }
interface RootPage { roots:ReferenceRoot[] }
interface SourceEntry { name:string; path:string; kind:string; size:number }
interface EntryPage { root_id:string; path:string; entries:SourceEntry[]; partial:boolean }
interface HistoryEntry { id:string; conversation_id:string; title:string; role:string; created_at:string; excerpt:string; characters:number; archived:boolean }
interface HistoryPage { messages:HistoryEntry[]; more:boolean }
interface SnapshotRequest { kind:string; root_id?:string; path?:string; message_id?:string; operation_id:string }
interface SnapshotResult { artifact:Artifact; origin:string }
let referenceSequence:number=0;

@Component
export struct ReferenceRoom {
  gateway:Gateway=new Gateway();
  @Prop colors:Palette=new Palette();
  initialQuery:string='';
  onClose:()=>void=()=>{};
  onUse:(artifact:Artifact)=>Promise<void>=async (_file:Artifact)=>{};
  @State query:string='';
  @State tab:string='files';
  @State roots:ReferenceRoot[]=[];
  @State rootId:string='';
  @State path:string='';
  @State entries:SourceEntry[]=[];
  @State messages:HistoryEntry[]=[];
  @State partial:boolean=false;
  @State more:boolean=false;
  @State historyOffset:number=0;
  @State loading:boolean=false;
  @State rootsLoading:boolean=false;
  @State adding:string='';
  @State notice:string='';
  private requestVersion:number=0;
  private rootVersion:number=0;
  private retrySnapshot:SnapshotRequest | undefined=undefined;
  private closed:boolean=false;
  private queryTimer:number=-1;
  private operations:Map<string,string>=new Map();
  private scroller:Scroller=new Scroller();

  aboutToAppear():void {this.query=this.initialQuery;this.loadRoots();}
  aboutToDisappear():void {this.closed=true;this.requestVersion++;if(this.queryTimer>=0)clearTimeout(this.queryTimer);}
  private operation(key:string):string {
    let value=this.operations.get(key);
    if(!value) {
      value=previewMode()?'reference-'+Date.now().toString(36)+'-'+(++referenceSequence)+'-'+Math.random().toString(36).substring(2,12):util.generateRandomUUID(true);
      this.operations.set(key,value);
    }
    return value;
  }
  private fail(error:Error):void {
    if(error instanceof GatewayError) {
      if(error.status===403)this.notice='这份内容还没有开放引用，请在主机确认目录。';
      else if(error.status===404)this.notice='这份来源刚刚移动或停用了，请返回后重新选择。';
      else if(error.status===409)this.notice='这份内容刚刚有变化，稍等片刻再取一次。';
      else if(error.status===413)this.notice='引用最多收录 1 MiB 文字、64 份文件，请选一份更小的文件或子目录。';
      else if(error.status===422)this.notice='这一份暂时不能作为文字引用，请换一份代码或子目录。';
      else if(error.status===429)this.notice='还有一份内容正在收好，稍后再试。';
      else this.notice=error.message;
    } else this.notice='这一份内容暂时没能取到，请保留输入，稍后再试。';
  }
  private async loadRoots():Promise<void> {
    const version=++this.rootVersion;this.rootsLoading=true;this.notice='';
    try {
      const result=await this.gateway.request<RootPage>('/api/references/roots');
      if(this.closed || version!==this.rootVersion)return;
      this.roots=result.roots;this.rootId=result.roots.find((item:ReferenceRoot)=>item.available)?.id || '';
    } catch(error) {if(!this.closed && version===this.rootVersion && this.tab==='files')this.fail(error as Error);}
    finally {if(!this.closed && version===this.rootVersion)this.rootsLoading=false;}
    if(!this.closed && version===this.rootVersion && this.rootId && this.tab==='files')this.refresh();
  }
  private changed(value:string):void {
    this.query=value;this.historyOffset=0;this.retrySnapshot=undefined;this.loading=true;
    if(this.queryTimer>=0)clearTimeout(this.queryTimer);
    this.requestVersion++;
    this.queryTimer=setTimeout(()=>{this.queryTimer=-1;this.refresh();},180);
  }
  private activate(tab:string):void {if(this.adding)return;this.tab=tab;this.historyOffset=0;this.notice='';this.refresh();}
  private async refresh():Promise<void> {
    const version=++this.requestVersion,tab=this.tab,query=this.query;
    this.retrySnapshot=undefined;
    if(tab==='files' && !this.rootId){this.loading=false;return;}
    this.loading=true;this.notice='';
    if(tab==='files'){this.entries=[];this.partial=false;}
    else {this.messages=[];this.more=false;}
    try {
      if(tab==='files') {
        const page=await this.gateway.request<EntryPage>('/api/references/roots/'+this.rootId+'/entries?path='+encodeURIComponent(this.path)+'&q='+encodeURIComponent(query));
        if(this.closed || version!==this.requestVersion)return;
        this.entries=page.entries;this.path=page.path;this.partial=page.partial;
      } else {
        const page=await this.gateway.request<HistoryPage>('/api/references/history?q='+encodeURIComponent(query)+'&offset='+this.historyOffset);
        if(this.closed || version!==this.requestVersion)return;
        this.messages=page.messages;this.more=page.more;
      }
      this.scroller.scrollEdge(Edge.Top);
    } catch(error) {if(!this.closed && version===this.requestVersion)this.fail(error as Error);}
    finally {if(!this.closed && version===this.requestVersion)this.loading=false;}
  }
  private enter(path:string):void {if(this.adding)return;this.path=path;this.query='';this.entries=[];this.refresh();}
  private up():void {this.enter(this.path.split('/').slice(0,-1).join('/'));}
  private async choose(kind:string,path:string='',message:string=''):Promise<void> {
    if(this.adding)return;
    const key=kind+':'+this.rootId+':'+path+':'+message;
    this.adding=key;this.notice='';this.retrySnapshot=undefined;
    const request:SnapshotRequest={kind:kind,root_id:kind==='message'?undefined:this.rootId,path:kind==='message'?undefined:path,
      message_id:message || undefined,operation_id:this.operation(key)};
    try {
      const result=await this.gateway.request<SnapshotResult>('/api/references/snapshots',http.RequestMethod.POST,JSON.stringify(request),45000);
      if(!this.closed)await this.onUse(result.artifact);
    } catch(error) {if(!this.closed){this.fail(error as Error);this.retrySnapshot=request;}}
    finally {if(!this.closed)this.adding='';}
  }
  private retry():void {
    const attempt=this.retrySnapshot;
    if(attempt)this.choose(attempt.kind,attempt.path || '',attempt.message_id || '');
    else if(this.roots.length===0 && this.tab==='files')this.loadRoots();
    else this.refresh();
  }
  private formatFileSize(value:number):string {return value>=1048576?(value/1048576).toFixed(1)+' MB':(value/1024).toFixed(1)+' KB';}
  private selectArrow():SymbolGlyphModifier {const modifier=new SymbolGlyphModifier();modifier.fontColor([this.colors.secondary]);return modifier;}
  build() {
    Column({space:0}) {
      Row({space:12}) {
        Text('带一段内容回来').fontSize(21).fontColor(this.colors.text).layoutWeight(1)
        Button('返回').fontSize(14).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44).onClick(()=>this.onClose())
      }.width('100%').padding({left:22,right:12,top:12,bottom:8})
      Row({space:8}) {
        Button('电脑代码').fontSize(14).fontColor(this.tab==='files'?this.colors.background:this.colors.secondary)
          .backgroundColor(this.tab==='files'?this.colors.accent:Color.Transparent).height(40).onClick(()=>this.activate('files'))
        Button('过往乐章').fontSize(14).fontColor(this.tab==='history'?this.colors.background:this.colors.secondary)
          .backgroundColor(this.tab==='history'?this.colors.accent:Color.Transparent).height(40).onClick(()=>this.activate('history'))
      }.width('100%').padding({left:18,right:18,bottom:10})
      TextInput({text:this.query,placeholder:this.tab==='files'?'查找文件或文件夹':'寻找说过的某句话'})
        .id('reference-query')
        .fontSize(15).fontColor(this.colors.text).placeholderColor(this.colors.secondary).backgroundColor(this.colors.raised)
        .height(46).maxLength(120).defaultFocus(true).onChange((value:string)=>this.changed(value))
        .onAppear(()=>{this.getUIContext().getFocusController().requestFocus('reference-query');})
        .enabled(!this.adding)
        .margin({left:20,right:20,bottom:12})
      if(this.tab==='files' && this.roots.length>0) Row({space:8}) {
        Select(this.roots.map((item:ReferenceRoot):SelectOption=>{return {value:item.name+(item.available?'':' · 未连接')};}))
          .arrowModifier(this.selectArrow())
          .selected(this.roots.findIndex((item:ReferenceRoot)=>item.id===this.rootId))
          .value(this.roots.find((item:ReferenceRoot)=>item.id===this.rootId)?.name || '选择代码目录')
          .font({size:13}).fontColor(this.colors.accent).backgroundColor(this.colors.surface).layoutWeight(1)
          .enabled(!this.adding).onSelect((index:number)=>{this.rootId=this.roots[index].id;this.path='';this.entries=[];this.refresh();})
        Button('上一级').fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44)
          .enabled(this.path.length>0 && !this.adding).onClick(()=>this.up())
      }.width('100%').padding({left:20,right:12,bottom:6})
      if(this.tab==='files' && this.rootId) Column({space:2}) {
        Text(this.path || this.roots.find((item:ReferenceRoot)=>item.id===this.rootId)?.name || '当前目录')
          .fontSize(12).lineHeight(20).fontColor(this.colors.secondary).maxLines(2).width('100%')
        Row() {
          Button(this.adding?'正在收好…':'引用这个文件夹').fontSize(12).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
            .width(145).height(44).padding({left:8,right:8}).enabled(!this.adding && !this.loading).onClick(()=>this.choose('folder',this.path))
        }.width('100%').justifyContent(FlexAlign.End)
      }.width('100%').padding({left:22,right:12,bottom:6})
      if(this.notice) Row({space:8}) {
        Text(this.notice).fontSize(13).lineHeight(21).fontColor(this.colors.secondary).layoutWeight(1)
        Button('重试').fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44)
          .enabled(!this.loading && !this.adding && !this.rootsLoading).onClick(()=>this.retry())
      }.width('100%').padding({left:22,right:12,bottom:8})
      Scroll(this.scroller) {
        Column({space:8}) {
          if(this.tab==='files') {
            if(!this.loading && !this.rootsLoading && this.roots.length===0) Text('还没有开放代码目录，请在电脑主机台添加。').fontSize(14).lineHeight(23).fontColor(this.colors.secondary).padding(22)
            if(!this.loading && this.rootId && this.entries.length===0 && !this.notice) Text('这里还没有找到匹配的代码。').fontSize(14).fontColor(this.colors.secondary).padding(22)
            ForEach(this.entries,(item:SourceEntry)=>{
              Button() {
                Row({space:12}) {
                  Image(item.kind==='folder'?$r('app.media.icon_archive'):$r('app.media.icon_code')).width(30).height(30).objectFit(ImageFit.Contain)
                  Column({space:5}) {
                    Text(item.name).fontSize(15).fontColor(this.colors.text).maxLines(2).textOverflow({overflow:TextOverflow.Ellipsis})
                    Text(this.query?item.path:item.kind==='folder'?'文件夹':this.formatFileSize(item.size)).fontSize(11).fontColor(this.colors.secondary).maxLines(2)
                  }.alignItems(HorizontalAlign.Start).layoutWeight(1)
                  Text(item.kind==='folder'?'进入':'引用').fontSize(12).fontColor(this.colors.accent)
                }.width('100%').padding(14)
              }.width('100%').backgroundColor(this.colors.surface).borderRadius(14).enabled(!this.adding && !this.loading)
                .onClick(()=>{if(item.kind==='folder')this.enter(item.path);else this.choose('file',item.path);})
            },(item:SourceEntry)=>item.kind+':'+item.path)
            if(this.partial) Text('还有内容未展开，试试子目录或更具体的名字。').fontSize(12).lineHeight(20).fontColor(this.colors.secondary).padding(12)
          } else {
            if(!this.loading && this.messages.length===0 && !this.notice) Text('这一页还没有找到匹配的话。').fontSize(14).fontColor(this.colors.secondary).padding(22)
            ForEach(this.messages,(item:HistoryEntry)=>{
              Button() {
                Column({space:7}) {
                  Row({space:8}) {
                    Text(item.title).fontSize(14).fontColor(this.colors.text).maxLines(1).textOverflow({overflow:TextOverflow.Ellipsis}).layoutWeight(1)
                    Text(item.created_at.substring(0,10)).fontSize(10).fontColor(this.colors.secondary)
                  }.width('100%')
                  Text((item.role==='user'?'你：':'祥子：')+item.excerpt).fontSize(13).lineHeight(21).fontColor(this.colors.secondary).maxLines(4).textOverflow({overflow:TextOverflow.Ellipsis})
                }.width('100%').alignItems(HorizontalAlign.Start).padding(14)
              }.width('100%').backgroundColor(this.colors.surface).borderRadius(14).enabled(!this.adding && !this.loading).onClick(()=>this.choose('message','',item.id))
            },(item:HistoryEntry)=>item.id)
            if(this.more || this.historyOffset>0) Row({space:12}) {
              Button('上一页').fontSize(13).fontColor(this.colors.accent).backgroundColor(this.colors.surface).height(44)
                .enabled(this.historyOffset>0 && !this.loading).onClick(()=>{this.historyOffset=Math.max(0,this.historyOffset-40);this.refresh();})
              Button('更多往事').fontSize(13).fontColor(this.colors.accent).backgroundColor(this.colors.surface).height(44)
                .enabled(this.more && !this.loading).onClick(()=>{this.historyOffset+=40;this.refresh();})
            }.width('100%').justifyContent(FlexAlign.Center)
          }
          if(this.loading || (this.tab==='files' && this.rootsLoading)) LoadingProgress().width(26).height(26).color(this.colors.accent).margin(16)
        }.width('100%').padding({left:20,right:20,bottom:18})
      }.width('100%').layoutWeight(1).align(Alignment.Top)
      Text(this.adding?'正在把选中的内容收进附件…':'把选中内容收成这一刻的附件，发送后一起读。')
        .fontSize(12).lineHeight(20).fontColor(this.colors.secondary).width('100%').padding({left:22,right:22,top:10,bottom:18})
    }.width('100%').height('100%').backgroundColor(this.colors.background)
  }
}
