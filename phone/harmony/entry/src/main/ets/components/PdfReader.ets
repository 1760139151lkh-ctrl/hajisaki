import { Artifact } from '../model/Types';
import { Palette } from '../design/Theme';
import { Gateway } from '../services/Gateway';
import { LocalStore } from '../services/LocalStore';
import { ArtifactPages, PdfPage } from '../services/ArtifactPages';

@Component
export struct PdfReader {
  @Prop artifact: Artifact = {id:'',name:'',size:0,mime:'',sha256:'',url:''};
  @Prop colors: Palette = new Palette();
  gateway: Gateway = new Gateway();
  local: LocalStore = new LocalStore();
  @State image: string = '';
  @State page: number = 0;
  @State count: number = 0;
  @State pageDraft: string = '1';
  @State ratio: number = 1.414;
  @State zoom: number = 1;
  @State viewport: number = 360;
  @State soft: boolean = false;
  @State ready: boolean = false;
  @State loading: boolean = false;
  @State notice: string = '';
  private pages?: ArtifactPages;
  private closed: boolean = false;
  private target: number = 0;
  private scroll: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pages=new ArtifactPages(this.gateway,this.local); this.soft=!this.colors.light; this.start();
  }
  aboutToDisappear(): void { this.closed=true; }
  private async start(): Promise<void> {
    const place = await this.pages!.place(this.artifact,'pdf');
    if (!this.closed) {this.zoom=place.zoom;await this.load(place.page);}
  }
  private async remember(): Promise<void> {
    try { await this.pages?.remember(this.artifact,'pdf',{page:this.page,sheet:0,offset:0,zoom:this.zoom}); }
    catch (_) { if(!this.closed) this.notice='这一页已展开，暂时还不能记住阅读位置。'; }
  }
  private async load(index: number): Promise<void> {
    if (this.loading || this.closed || !this.pages) return;
    this.loading=true;this.notice='';this.target=index;
    try {
      const result=await this.pages.read<PdfPage>('artifact_pdf_v1',this.artifact,index+':2048',
        '/api/artifacts/'+encodeURIComponent(this.artifact.id)+'/page-image?page='+index+'&width=2048',
        (value:PdfPage):boolean=>value.page===index && Number.isSafeInteger(value.pages) && value.pages>index &&
          Number.isSafeInteger(value.width) && value.width>0 && Number.isSafeInteger(value.height) && value.height>0 &&
          value.width*value.height<=6100000 && value.source_sha256===this.artifact.sha256 &&
          (value.mime==='image/png'||value.mime==='image/jpeg') && typeof value.image_base64==='string' &&
          value.image_base64.length<=4*1024*1024 && /^[A-Za-z0-9+/]+={0,2}$/.test(value.image_base64),45000);
      if (this.closed) return;
      const data=result.data;
      this.page=data.page;this.count=data.pages;this.pageDraft=String(data.page+1);this.ratio=data.height/data.width;
      this.image='data:'+data.mime+';base64,'+data.image_base64;this.ready=true;
      try { this.scroll.scrollTo({xOffset:0,yOffset:0}); } catch (_) {}
      if (!result.stored) this.notice='这张纸页已展开，暂时还不能留到离线。';
      await this.remember();
    } catch (error) {
      if (!this.closed) {this.notice=error instanceof Error?error.message:'这一页暂时没能展开，原件仍可保存。';this.pageDraft=String(this.page+1);}
    } finally {if(!this.closed)this.loading=false;}
  }
  private jump(): void {
    const value=Number(this.pageDraft);
    if (Number.isSafeInteger(value)&&value>=1&&value<=this.count) this.load(value-1);
    else {this.notice='请翻到1至'+this.count+'页之间。';this.pageDraft=String(this.page+1);}
  }
  private changeZoom(delta: number): void {
    this.zoom=Math.max(1,Math.min(3,this.zoom+delta));this.remember();
  }
  build() {
    Column({space:0}) {
      if (this.ready) {
        Row({space:8}) {
          Button('上一页').fontSize(13).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
            .enabled(!this.loading&&this.page>0).onClick(()=>this.load(this.page-1))
          TextInput({text:this.pageDraft}).type(InputType.Number).fontSize(14).fontColor(this.colors.text)
            .backgroundColor(this.colors.raised).width(62).height(40).textAlign(TextAlign.Center).enabled(!this.loading)
            .onChange((value:string)=>{this.pageDraft=value;}).onSubmit(()=>this.jump())
          Text('/ '+this.count).fontSize(13).fontColor(this.colors.secondary)
          Button('下一页').fontSize(13).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
            .enabled(!this.loading&&this.page+1<this.count).onClick(()=>this.load(this.page+1))
        }.width('100%').justifyContent(FlexAlign.Center)
        Row({space:10}) {
          Button('−').fontSize(18).height(42).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
            .enabled(!this.loading&&this.zoom>1).onClick(()=>this.changeZoom(-0.5))
          Text(Math.round(this.zoom*100)+'%').fontSize(12).fontColor(this.colors.secondary).width(48).textAlign(TextAlign.Center)
          Button('＋').fontSize(18).height(42).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
            .enabled(!this.loading&&this.zoom<3).onClick(()=>this.changeZoom(0.5))
          Button(this.soft?'原色':'柔光').fontSize(13).height(42).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
            .onClick(()=>{this.soft=!this.soft;})
          if(this.loading) LoadingProgress().width(18).height(18).color(this.colors.accent)
        }.width('100%').justifyContent(FlexAlign.Center).padding({bottom:8})
      }
      if (this.notice) Row({space:8}) {
        Text(this.notice).fontSize(13).fontColor(this.colors.secondary).layoutWeight(1)
        Button(this.ready?'再翻一次':'从第一页翻开').fontSize(12).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
          .enabled(!this.loading).onClick(()=>this.load(this.ready?this.target:0))
      }.width('100%').padding({left:20,right:12,bottom:10})
      if (!this.ready && this.loading) Column() {
        LoadingProgress().width(28).height(28).color(this.colors.accent)
      }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      else if (this.ready) Scroll(this.scroll) {
        Image(this.image).width(this.viewport*this.zoom).height(this.viewport*this.zoom*this.ratio)
          .objectFit(ImageFit.Fill).opacity(this.soft?0.76:1).draggable(false)
          .onError(()=>{if(!this.closed)this.notice='这一张纸页暂时没能显现，原件仍可保存。';})
      }.scrollable(ScrollDirection.FREE).scrollBar(BarState.Auto).align(Alignment.TopStart).width('100%').layoutWeight(1)
        .onAreaChange((_old:Area,area:Area)=>{const width=Number(area.width);if(Number.isFinite(width)&&width>100)this.viewport=width;})
      else Blank().layoutWeight(1)
    }.width('100%').height('100%')
  }
}
