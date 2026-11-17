import { MessagePart } from '../model/MessageParts';
import { Artifact, Message, TaskPage } from '../model/Types';
import { Palette } from '../design/Theme';
import { Manuscript } from './Manuscript';

/** Observe the semantic row itself so a stable LazyForEach key can receive deltas. */
@Component
export struct MessageRow {
  @ObjectLink part:MessagePart;
  @Prop colors:Palette=new Palette();
  @Prop avatar:Resource=$r('app.media.thinking_deep');
  @Prop taskState:TaskPage={tasks:{},items:[],editable:false};
  onTask:(index:number,checked:boolean)=>Promise<boolean>=async()=>false;
  onRead:(message:Message)=>void=()=>{};
  onCopy:(text:string)=>void=()=>{};
  onQuote:(text:string)=>void=()=>{};
  onSelect:(message:Message)=>void=()=>{};
  onFork:(message:Message)=>void=()=>{};
  onPin:(message:Message)=>void=()=>{};
  @BuilderParam attachment:(file:Artifact)=>void;

  build() {
    Column({space:10}) {
      if (this.part.first) Row({space:8}) {
        if (this.part.message.role !== 'user') Image(this.part.message.status==='streaming'?this.avatar:$r('app.media.idle_gentle')).width(25).height(25).borderRadius(13).objectFit(ImageFit.Cover)
        Text(this.part.message.role === 'user' ? '你' : '祥子').fontSize(12).fontColor(this.part.message.role === 'user' ? this.colors.secondary : this.colors.accent)
      }.width('100%')
      Column({space:12}) {
        if(this.part.message.role==='assistant' && this.part.message.status==='failed' && this.part.message.content.trim().length===0)
          Text('这一页暂时没能写完，你的话和原件都还在。').fontSize(14).lineHeight(22).fontColor(this.colors.secondary)
        else if(this.part.message.role==='assistant' && this.part.message.status==='streaming' && this.part.message.content.trim().length===0)
          Text('我正在把这些线索连起来，写好后放在这里。').fontSize(14).lineHeight(22).fontColor(this.colors.secondary)
        else if(this.part.message.role==='assistant' && this.part.message.status==='stopped' && this.part.message.content.trim().length===0)
          Text('已经停笔，你的话和原件都还在。').fontSize(14).lineHeight(22).fontColor(this.colors.secondary)
        else Manuscript({text:this.part.text,colors:this.colors,taskState:this.taskState,onTask:this.onTask})
        if (this.part.last) ForEach(this.part.message.attachments || [],(file:Artifact) => { this.attachment(file) },(file:Artifact) => file.id)
      }.width('100%').padding({left:18,right:18,top:this.part.first?18:5,bottom:this.part.last?18:5})
        .borderRadius({topLeft:this.part.first?20:0,topRight:this.part.first?20:0,bottomLeft:this.part.last?20:0,bottomRight:this.part.last?20:0})
        .backgroundColor(this.part.message.role === 'user' ? this.colors.raised : this.colors.surface)
        .priorityGesture(TapGesture({count:2}).onAction(() => this.onRead(this.part.message)))
      if (this.part.last) Row({space:4}) {
        if(this.part.message.content.trim().length>0) {
          Button('复制').fontSize(12).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).height(44).constraintSize({minWidth:44}).padding({left:6,right:6}).onClick(() => this.onCopy(this.part.message.content))
          Button('引用').fontSize(12).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).height(44).constraintSize({minWidth:44}).padding({left:6,right:6}).onClick(() => this.onQuote(this.part.message.content))
          if(this.part.message.role==='assistant') Button('选文').fontSize(12).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44).constraintSize({minWidth:44}).padding({left:6,right:6}).onClick(()=>this.onSelect(this.part.message))
        }
        Button('分叉').fontSize(12).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).height(44).constraintSize({minWidth:44}).padding({left:6,right:6}).onClick(() => this.onFork(this.part.message))
        Button('钉住').fontSize(12).fontColor(this.colors.gold).backgroundColor(Color.Transparent).height(44).constraintSize({minWidth:44}).padding({left:6,right:6}).onClick(() => this.onPin(this.part.message))
      }.width('100%')
      if(this.part.last && this.part.message.status==='stopped') Text('停在这里').fontSize(11).fontColor(this.colors.secondary).width('100%')
    }.width('100%').padding({left:20,right:20,top:this.part.first?12:0,bottom:this.part.last?12:0})
  }
}
