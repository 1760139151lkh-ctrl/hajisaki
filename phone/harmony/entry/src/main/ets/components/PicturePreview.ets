import { Artifact } from '../model/Types';
import { Palette } from '../design/Theme';
import { Gateway } from '../services/Gateway';
import { LocalStore } from '../services/LocalStore';
import { ImagePreviews,pictureUri } from '../services/ImagePreviews';

@Component
export struct PicturePreview {
  @Prop @Watch('sourceChanged') artifact:Artifact={id:'',name:'',mime:'',size:0,sha256:'',url:''};
  @Prop colors:Palette=new Palette();
  @Prop previewHeight:number=220;
  @Prop pixelWidth:number=960;
  @Prop page:number=-1;
  gateway:Gateway=new Gateway();
  local:LocalStore=new LocalStore();
  onOpen:()=>void=()=>{};
  @State image:string='';
  @State placeholder:string='';
  @State loaded:boolean=false;
  @State failed:boolean=false;
  @State savingFailed:boolean=false;
  @State boxWidth:number=0;
  @State imageRatio:number=1;
  private reader?:ImagePreviews;
  private generation:number=0;
  private visible:boolean=false;
  private busy:boolean=false;
  private closed:boolean=false;
  private identity:string='';

  aboutToAppear():void {this.closed=false;this.identity='';this.reader=new ImagePreviews(this.gateway,this.local);this.sourceChanged();}
  aboutToDisappear():void {this.closed=true;this.generation++;this.image='';}
  private sourceChanged():void {
    const identity=this.artifact.sha256+':'+this.page+':'+this.pixelWidth;
    if(identity===this.identity)return;
    this.identity=identity;
    this.generation++;this.busy=false;this.image='';this.placeholder='';this.loaded=false;this.failed=false;
    this.restorePlaceholder();if(this.visible)this.load();
  }
  private async restorePlaceholder():Promise<void> {
    const ticket=this.generation;
    const meta=await this.reader?.meta(this.artifact,this.page);
    if(!this.closed && ticket===this.generation && meta){this.placeholder=meta.placeholder;this.imageRatio=meta.width/meta.height;}
  }
  private async load(force:boolean=false):Promise<void> {
    if(this.busy || this.closed || !this.reader || (!force && this.image))return;
    this.busy=true;this.failed=false;const ticket=this.generation;
    try {
      const meta=await this.reader.prepare(this.artifact,this.page);
      if(this.closed || ticket!==this.generation)return;
      if(meta){this.placeholder=meta.placeholder;this.imageRatio=meta.width/meta.height;}
      const result=await this.reader.read(this.artifact,this.pixelWidth,this.page,false,force);
      if(this.closed || ticket!==this.generation)return;
      this.imageRatio=result.data.width/result.data.height;
      this.savingFailed=!result.stored;this.image=pictureUri(result.data);
    } catch (_) {if(!this.closed && ticket===this.generation)this.failed=true;}
    finally {if(ticket===this.generation)this.busy=false;}
  }
  build() {
    Stack() {
      if(this.image) Image(this.image).width('100%').height('100%').objectFit(ImageFit.Contain)
        .onComplete(()=>{this.loaded=true;this.failed=false;})
        .onError(()=>{this.failed=true;this.loaded=false;})
      if(this.placeholder) Image(this.placeholder).width(Math.min(this.boxWidth,this.previewHeight*this.imageRatio))
        .height(Math.min(this.boxWidth/this.imageRatio,this.previewHeight)).objectFit(ImageFit.Fill)
        .opacity(this.loaded?0:1).animation({duration:180,curve:Curve.EaseInOut})
        .hitTestBehavior(HitTestMode.None)
      if(this.failed) Button('重新取图').fontSize(13).fontColor(this.colors.accent).backgroundColor(this.colors.surface)
        .height(44).onClick(()=>this.load(true))
      if(this.savingFailed && this.loaded) Text('尚未收进手机').fontSize(11).fontColor(this.colors.secondary)
        .backgroundColor(this.colors.surface).padding(6).align(Alignment.BottomEnd)
    }.width('100%').height(this.previewHeight).backgroundColor(this.colors.surface).borderRadius(12).clip(true)
      .border({width:0.5,color:this.colors.border}).accessibilityText(this.artifact.name)
      .onAreaChange((_old:Area,next:Area)=>{this.boxWidth=Number(next.width);})
      .onClick(()=>{if(this.image && !this.failed)this.onOpen();})
      .onVisibleAreaChange([0.01],(visible:boolean)=>{this.visible=visible;if(visible)this.load();})
  }
}
