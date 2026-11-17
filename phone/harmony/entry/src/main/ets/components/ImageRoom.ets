import { Artifact } from '../model/Types';
import { Palette } from '../design/Theme';
import { Gateway,GatewayError } from '../services/Gateway';
import { LocalStore } from '../services/LocalStore';
import { ImagePreviews,pictureUri } from '../services/ImagePreviews';

@Component
export struct ImageRoom {
  artifact:Artifact={id:'',name:'',mime:'',size:0,sha256:'',url:''};
  page:number=-1;
  gateway:Gateway=new Gateway();
  local:LocalStore=new LocalStore();
  @Prop colors:Palette=new Palette();
  @Prop saving:boolean=false;
  @Prop asking:boolean=false;
  onClose:()=>void=()=>{};
  onAnnotate:()=>void=()=>{};
  onSave:()=>void=()=>{};
  onAsk:()=>void=()=>{};
  @State image:string='';
  @State busy:boolean=false;
  @State notice:string='';
  @State zoom:number=1;
  @State x:number=0;
  @State y:number=0;
  @State animated:boolean=false;
  @State soft:boolean=false;
  private reader?:ImagePreviews;
  private closed:boolean=false;
  private panX:number=0;
  private panY:number=0;
  private startZoom:number=1;
  private viewportWidth:number=300;
  private viewportHeight:number=400;
  aboutToAppear():void {this.reader=new ImagePreviews(this.gateway,this.local);this.load();}
  aboutToDisappear():void {this.closed=true;}
  private async load(force:boolean=false):Promise<void> {
    if(this.busy || !this.reader)return;
    this.busy=true;this.notice='';
    try {
      const result=await this.reader.read(this.artifact,960,this.page,true,force);
      if(this.closed)return;
      this.image=pictureUri(result.data);this.animated=result.data.animated===true;
      if(!result.stored)this.notice='画面已展开，暂时未能收进手机供离线查看。';
    } catch(error) {if(!this.closed)this.notice=error instanceof GatewayError?error.message:'这张画面暂时没有取到，原件仍在。';}
    finally {if(!this.closed)this.busy=false;}
  }
  private setZoom(value:number):void {this.zoom=Math.max(1,Math.min(3,value));this.constrain();}
  private constrain():void {
    const horizontal=(this.zoom-1)*this.viewportWidth/2,vertical=(this.zoom-1)*this.viewportHeight/2;
    this.x=Math.max(-horizontal,Math.min(horizontal,this.x));this.y=Math.max(-vertical,Math.min(vertical,this.y));
  }
  build() {
    Column({space:0}) {
      Row({space:10}) {
        Text(this.artifact.name+(this.page>=0?' · 第'+(this.page+1)+'页':'')).fontSize(18).fontColor(this.colors.text).maxLines(2).layoutWeight(1)
        Button('返回').fontSize(14).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44).onClick(()=>this.onClose())
      }.width('100%').padding({left:22,right:12,top:12,bottom:8})
      if(this.animated) Text('动图首帧').fontSize(12).fontColor(this.colors.secondary).width('100%').padding({left:22,bottom:8})
      if(this.notice) Row({space:6}) {
        Text(this.notice).fontSize(13).lineHeight(21).fontColor(this.colors.secondary).layoutWeight(1)
        Button('重新取图').fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44)
          .enabled(!this.busy).onClick(()=>this.load(true))
      }.width('100%').padding({left:22,right:12,bottom:8})
      Stack() {
        if(this.image) Image(this.image).width('100%').height('100%').objectFit(ImageFit.Contain)
          .invert(this.soft?0.88:0).brightness(this.soft?0.85:1)
          .scale({x:this.zoom,y:this.zoom}).translate({x:this.x,y:this.y})
          .onError(()=>{this.notice='这一张画面暂时没有显示出来，请重新取一次。';})
        if(this.busy) LoadingProgress().width(28).height(28).color(this.colors.accent)
      }.width('100%').layoutWeight(1).clip(true)
        .onAreaChange((_old:Area,next:Area)=>{this.viewportWidth=Number(next.width);this.viewportHeight=Number(next.height);this.constrain();})
        .gesture(GestureGroup(GestureMode.Parallel,
          PinchGesture().onActionStart(()=>{this.startZoom=this.zoom;}).onActionUpdate((event:GestureEvent)=>this.setZoom(this.startZoom*event.scale)),
          PanGesture().onActionStart(()=>{this.panX=this.x;this.panY=this.y;}).onActionUpdate((event:GestureEvent)=>{
            if(this.zoom>1){this.x=this.panX+event.offsetX;this.y=this.panY+event.offsetY;this.constrain();}
          })
        ))
      Row({space:10}) {
        Button('−').fontSize(22).fontColor(this.colors.accent).backgroundColor(Color.Transparent).width(44).height(44)
          .enabled(this.zoom>1).onClick(()=>this.setZoom(this.zoom-0.5))
        Button(Math.round(this.zoom*100)+'%').fontSize(14).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).height(44)
          .onClick(()=>{this.zoom=1;this.x=0;this.y=0;})
        Button('+').fontSize(22).fontColor(this.colors.accent).backgroundColor(Color.Transparent).width(44).height(44)
          .enabled(this.zoom<3).onClick(()=>this.setZoom(this.zoom+0.5))
        Blank()
        Button(this.soft?'原色':'柔光').fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44)
          .onClick(()=>{this.soft=!this.soft;})
      }.width('100%').padding({left:16,right:22,top:8})
      if(this.page<0) Row() {
        Button(this.asking?'正在放回乐章…':'围绕这张图追问').fontSize(15).fontColor(this.colors.background)
          .backgroundColor(this.colors.accent).height(46).layoutWeight(1).enabled(!this.asking).onClick(()=>this.onAsk())
      }.width('100%').padding({left:22,right:22,top:8})
      Row({space:12}) {
        if(this.page<0 && this.artifact.mime!=='image/gif') Button('批注').fontSize(15)
          .fontColor(this.colors.accent).backgroundColor(this.colors.surface).height(46).layoutWeight(1).onClick(()=>this.onAnnotate())
        Button(this.saving?'正在收好…':'保存原件').fontSize(15).fontColor(this.colors.accent).backgroundColor(this.colors.surface)
          .height(46).layoutWeight(1).enabled(!this.saving).onClick(()=>this.onSave())
      }.width('100%').padding({left:22,right:22,top:8,bottom:20})
    }.width('100%').height('100%').backgroundColor(this.colors.background)
  }
}
