import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { common } from '@kit.AbilityKit';
import { Artifact } from '../model/Types';
import { previewMode } from '../model/BuildMode';
import { StudioPoint, StudioOperation, StudioStep, StudioDraft, StudioPreview, StudioRequest, StudioExport,
  studioTransform, studioCheckpoint, studioDraftValid, studioPreviewValid } from '../model/StudioTypes';
import { Palette } from '../design/Theme';
import { Gateway, GatewayError } from '../services/Gateway';
import { LocalStore } from '../services/LocalStore';
import { NativeFiles } from '../platform/NativeFiles';

let studioSequence: number = 0;

@Component
export struct StudioRoom {
  @Prop colors: Palette = new Palette();
  artifact: Artifact | undefined = undefined;
  conversationId: string = '';
  gateway: Gateway = new Gateway();
  local: LocalStore = new LocalStore();
  onClose: () => void = () => {};
  onUse: (file: Artifact) => Promise<void> = async (_file: Artifact) => {};
  onConnect: () => void = () => {};
  onPick: (file: Artifact) => void = (_file: Artifact) => {};
  @State steps: StudioStep[] = [];
  @State cursor: number = 0;
  @State tool: string = 'pen';
  @State ink: string = '#385B92FF';
  @State brush: number = 3;
  @State ready: boolean = false;
  @State busy: boolean = false;
  @State exporting: boolean = false;
  @State notice: string = '';
  @State unsaved: boolean = false;
  @State viewportWidth: number = 300;
  @State viewportHeight: number = 400;
  @State ratio: number = 1.25;
  @State baseImage: string = '';
  @State canRetry: boolean = false;
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private baseCount: number = 0;
  private closed: boolean = false;
  private loaded: boolean = false;
  private canvasReady: boolean = false;
  private draftKey: string = '';
  private exportId: string = '';
  private requestVersion: number = 0;
  private writes: Promise<void> = Promise.resolve();
  private active: StudioPoint[] = [];
  private activePointer: number = -1;
  private corners: StudioPoint[] = [];
  private corner: number = -1;
  private retryJob?: () => Promise<void>;

  private failed(message: string, job: () => Promise<void>): void {
    this.retryJob=job;this.canRetry=true;this.notice=message;
  }
  private clearFailure(): void { this.retryJob=undefined;this.canRetry=false;this.notice=''; }

  aboutToAppear(): void {
    this.draftKey = (this.conversationId || 'loose') + ':' + (this.artifact?.sha256 || 'paper');
    this.restore();
  }
  aboutToDisappear(): void {
    this.closed = true; this.requestVersion++;
  }
  private operations(): StudioOperation[] { return this.steps.slice(0,this.cursor).map((step: StudioStep) => step.operation); }
  private uuid(): string {
    // The desktop SDK's UUID mock is not an identifier. Preview-only keys use
    // the same public uniqueness scheme as the existing message outbox.
    return previewMode() ? 'preview-'+Date.now().toString(36)+'-'+(++studioSequence)+'-'+Math.random().toString(36).substring(2,12)
      : util.generateRandomUUID(true);
  }
  private checkpoint(count: number): string { return this.draftKey + ':' + (count ? this.steps[count-1].key : 'original'); }
  private paperW(): number { return Math.max(1,Math.min(this.viewportWidth,this.viewportHeight/this.ratio)); }
  private paperH(): number { return this.paperW()*this.ratio; }

  private async restore(): Promise<void> {
    this.busy = true;
    try {
      const saved = await this.local.get('studio_draft_v1',this.draftKey,'');
      if (saved) {
        const draft = JSON.parse(saved) as StudioDraft;
        if (!studioDraftValid(draft)) throw new Error('这份画稿暂时没能完整打开，原记录仍在。');
        this.steps=draft.steps; this.cursor=draft.cursor; this.exportId=draft.exportId;
      }
      this.loaded=true;
      await this.loadBase();
    } catch (error) { if(!this.closed) this.failed(error instanceof GatewayError ? error.message : '这份画稿暂时没能完整打开，原记录仍在。',()=>this.restore()); }
    finally { if(!this.closed) this.busy=false; }
  }
  private save(): Promise<void> {
    const snapshot: StudioDraft = { version:1,steps:this.steps,cursor:this.cursor,exportId:this.exportId };
    const body=JSON.stringify(snapshot);
    const write=this.writes.then(()=>this.local.put('studio_draft_v1',this.draftKey,body));
    this.writes=write.catch(()=>{});
    return write.then(()=>{if(!this.closed)this.unsaved=false;}).catch(()=>{
      if(!this.closed) { this.unsaved=true; this.failed('画稿暂未收进手机，先留在这一页，再试一次。',()=>this.save()); }
      throw new Error('画稿暂未收好。');
    });
  }
  private async leave(): Promise<void> {
    if(!this.loaded) { this.onClose(); return; }
    try { await this.save(); this.onClose(); } catch (_) { /* Keep the visible draft available for retry. */ }
  }
  private async connect(): Promise<void> {
    try { if(this.loaded) await this.save(); this.onConnect(); } catch (_) { /* Preserve the unsaved canvas. */ }
  }
  private async loadBase(): Promise<void> {
    const version=++this.requestVersion;
    let index=0;
    for(let i=this.cursor-1;i>=0;i--) if(studioCheckpoint(this.steps[i].operation.kind)) { index=i+1; break; }
    if(index===0 && !this.artifact) {
      this.baseImage=''; this.baseCount=0; this.ratio=1.25; this.ready=true; this.redraw(); return;
    }
    let preview: StudioPreview | undefined;
    try {
      const saved=await this.local.get('studio_image_v1',this.checkpoint(index),'');
      if(saved) { const value=JSON.parse(saved) as StudioPreview; if(studioPreviewValid(value)) preview=value; }
    } catch (_) { /* Fetch the immutable original or exact edit checkpoint below. */ }
    if(!preview) {
      const body: StudioRequest = { source_id:this.artifact?.id || '',operations:this.steps.slice(0,index).map((step:StudioStep)=>step.operation) };
      preview=await this.gateway.request<StudioPreview>('/api/image-studio/preview',http.RequestMethod.POST,JSON.stringify(body),45000);
      if(!studioPreviewValid(preview)) throw new Error('这一张画页还没有完整收齐，请再展开一次。');
      await this.local.put('studio_image_v1',this.checkpoint(index),JSON.stringify(preview));
    }
    if(this.closed || version!==this.requestVersion) return;
    this.baseImage='data:'+preview.mime+';base64,'+preview.image_base64; this.baseCount=index;
    this.ratio=preview.height/preview.width; this.ready=true; this.redraw();
  }
  private canAdd(operation: StudioOperation): boolean {
    const kept=this.steps.slice(0,this.cursor);
    const points=kept.reduce((sum:number,step:StudioStep)=>sum+step.operation.points.length,0);
    const transforms=kept.filter((step:StudioStep)=>studioTransform(step.operation.kind)).length;
    if(kept.length>=400 || points+operation.points.length>32000 || (studioTransform(operation.kind) && transforms>=12)) {
      this.notice='这张画页已写得很满，先把它放回对话吧。'; return false;
    }
    return true;
  }
  private async commit(operation: StudioOperation): Promise<void> {
    if(this.closed || this.busy || !this.ready || !this.canAdd(operation)) { this.redraw(); return; }
    const prior=this.steps;
    const previous=this.cursor;
    this.steps=this.steps.slice(0,this.cursor).concat([{key:this.uuid(),operation:operation}]);
    this.cursor=this.steps.length; this.exportId=''; this.clearFailure();
    if(studioCheckpoint(operation.kind)) {
      this.busy=true;
      try {
        await this.save();
        await this.loadBase();
      } catch(error) {
        if(!this.closed) {
          this.steps=prior; this.cursor=previous;
          try { await this.save(); } catch (_) { /* Unsaved state remains visible. */ }
          this.failed(error instanceof GatewayError ? error.message : '这张画页暂时没有展开，原稿仍在。',()=>this.commit(operation));
          this.redraw();
        }
      } finally { if(!this.closed)this.busy=false; }
    } else { this.redraw(); this.save().catch(()=>{}); }
  }
  private async history(direction: number): Promise<void> {
    if(this.busy || this.exporting || !this.ready) return;
    const target=this.cursor+direction;
    if(target<0 || target>this.steps.length) return;
    const previous=this.cursor;
    const crossing=studioCheckpoint(this.steps[direction<0?target:previous].operation.kind);
    this.cursor=target; this.exportId=''; this.active=[]; this.clearFailure();
    if(crossing || target<this.baseCount) {
      this.busy=true;
      try { await this.loadBase(); }
      catch(error) { this.cursor=previous; this.failed(error instanceof GatewayError ? error.message : '这一步暂时没有展开，原稿仍在。',()=>this.history(direction)); }
      finally { if(!this.closed)this.busy=false; }
    }
    this.redraw(); this.save().catch(()=>{});
  }
  private op(kind: string, points: StudioPoint[] = []): StudioOperation {
    return {kind:kind,points:points,color:this.ink,width:Math.max(0.001,Math.min(0.08,this.brush/Math.min(this.paperW(),this.paperH()))),
      number:Math.min(999,this.operations().filter((op:StudioOperation)=>op.kind==='number').length+1)};
  }
  private selectTool(tool: string): void {
    if(this.busy || this.exporting) return;
    this.clearFailure();
    this.tool=tool; this.active=[]; this.activePointer=-1;
    if(tool==='perspective') this.corners=[{x:0.08,y:0.08},{x:0.92,y:0.08},{x:0.92,y:0.92},{x:0.08,y:0.92}];
    this.redraw();
  }
  private touch(event: TouchEvent): void {
    if(!this.ready || this.busy || this.exporting || !this.loaded) return;
    const touch=event.changedTouches.length ? event.changedTouches[0] : event.touches[0];
    if(!touch) return;
    const p: StudioPoint={x:Math.max(0,Math.min(1,touch.x/this.paperW())),y:Math.max(0,Math.min(1,touch.y/this.paperH()))};
    if(event.type===TouchType.Down) {
      if(this.activePointer!==-1) return;
      this.activePointer=touch.id;
      if(this.tool==='perspective') {
        let nearest=0;
        for(let i=1;i<4;i++) if(Math.hypot(p.x-this.corners[i].x,p.y-this.corners[i].y)<Math.hypot(p.x-this.corners[nearest].x,p.y-this.corners[nearest].y)) nearest=i;
        this.corner=nearest; this.corners[nearest]=p; this.redraw();
      } else { this.active=[p]; this.redraw(); }
    } else if(touch.id===this.activePointer && event.type===TouchType.Move) {
      if(this.tool==='perspective') { this.corners[this.corner]=p; this.redraw(); }
      else if(this.tool==='mosaic') { this.active=[this.active[0],p]; this.redraw(); }
      else if(this.tool==='pen' && this.active.length<2048) {
        const last=this.active[this.active.length-1];
        if(Math.hypot((p.x-last.x)*this.paperW(),(p.y-last.y)*this.paperH())>=0.7) { this.active.push(p); this.drawSegment(last,p); }
      }
    } else if(touch.id===this.activePointer && (event.type===TouchType.Up || event.type===TouchType.Cancel)) {
      this.activePointer=-1;
      if(this.tool==='perspective') return;
      const points=this.active; this.active=[];
      if(event.type===TouchType.Cancel || !points.length) { this.redraw(); return; }
      if(this.tool==='number') this.commit(this.op('number',[points[0]]));
      else if(this.tool==='mosaic') {
        if(Math.abs(p.x-points[0].x)*this.paperW()<4 || Math.abs(p.y-points[0].y)*this.paperH()<4) { this.redraw(); return; }
        this.commit(this.op('mosaic',[points[0],p]));
      } else {
        if(points.length<2048) points.push(p);
        this.commit(this.op('pen',points));
      }
    }
  }
  private drawSegment(a: StudioPoint,b: StudioPoint): void {
    const ctx=this.context;
    ctx.strokeStyle=this.ink.substring(0,7);ctx.lineWidth=this.brush;ctx.lineCap='round';ctx.lineJoin='round';
    ctx.beginPath();ctx.moveTo(a.x*this.paperW(),a.y*this.paperH());ctx.lineTo(b.x*this.paperW(),b.y*this.paperH());ctx.stroke();
  }
  private drawOperation(operation: StudioOperation): void {
    const ctx=this.context;
    const width=this.paperW(),height=this.paperH();
    ctx.strokeStyle=operation.color.substring(0,7);ctx.fillStyle=operation.color.substring(0,7);
    ctx.lineWidth=operation.width*Math.min(width,height);ctx.lineCap='round';ctx.lineJoin='round';
    if(operation.kind==='pen') {
      ctx.beginPath();
      operation.points.forEach((p:StudioPoint,index:number)=>{if(index===0)ctx.moveTo(p.x*width,p.y*height);else ctx.lineTo(p.x*width,p.y*height);});
      ctx.stroke();
      if(operation.points.length===1) { const p=operation.points[0];ctx.beginPath();ctx.arc(p.x*width,p.y*height,ctx.lineWidth/2,0,Math.PI*2);ctx.fill(); }
    } else if(operation.kind==='number') {
      const p=operation.points[0],radius=Math.min(width,height)*0.032;
      ctx.beginPath();ctx.arc(p.x*width,p.y*height,radius,0,Math.PI*2);ctx.fill();
      ctx.fillStyle='#FFFFFF';ctx.font='bold '+(radius*1.1)+'vp sans-serif';ctx.textAlign='center';ctx.textBaseline='middle';
      ctx.fillText(String(operation.number),p.x*width,p.y*height);
    }
  }
  private redraw(): void {
    if(!this.canvasReady || !this.ready || this.closed) return;
    const ctx=this.context,width=this.paperW(),height=this.paperH();
    ctx.clearRect(0,0,width,height);
    if(!this.baseImage) {ctx.fillStyle='#F6F7FB';ctx.fillRect(0,0,width,height);}
    for(let index=this.baseCount;index<this.cursor;index++) this.drawOperation(this.steps[index].operation);
    if(this.active.length && this.tool==='pen') this.drawOperation(this.op('pen',this.active));
    if(this.active.length && this.tool==='mosaic') {
      const a=this.active[0],b=this.active[this.active.length-1];
      ctx.strokeStyle='#385B92';ctx.lineWidth=1.5;ctx.setLineDash([5,4]);
      ctx.strokeRect(Math.min(a.x,b.x)*width,Math.min(a.y,b.y)*height,Math.abs(a.x-b.x)*width,Math.abs(a.y-b.y)*height);ctx.setLineDash([]);
    }
    if(this.tool==='perspective' && this.corners.length===4) {
      ctx.strokeStyle='#385B92';ctx.lineWidth=2;ctx.fillStyle='#385B92';ctx.beginPath();
      this.corners.forEach((p:StudioPoint,index:number)=>{if(index===0)ctx.moveTo(p.x*width,p.y*height);else ctx.lineTo(p.x*width,p.y*height);});
      ctx.closePath();ctx.stroke();
      this.corners.forEach((p:StudioPoint)=>{ctx.beginPath();ctx.arc(p.x*width,p.y*height,7,0,Math.PI*2);ctx.fill();});
    }
  }
  private async applyEdit(kind: string): Promise<void> {
    const op=this.op(kind,kind==='perspective'?this.corners.map((p:StudioPoint)=>({x:p.x,y:p.y} as StudioPoint)):[]);
    if(kind==='perspective') {
      let area=0;
      for(let i=0;i<4;i++) {
        const a=op.points[i],b=op.points[(i+1)%4],c=op.points[(i+2)%4];
        if((b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)<0.001) { this.notice='把四个角重新贴住纸张，边线不能交叉。';return; }
        area+=a.x*b.y-b.x*a.y;
      }
      if(area<0.02) { this.notice='这四个角靠得太近了，请重新框住纸张。';return; }
    }
    await this.commit(op);
    if(!this.closed) {this.tool='pen';this.redraw();}
  }
  private async pick(): Promise<void> {
    if(this.busy || this.exporting) return;
    this.busy=true;this.clearFailure();
    try {
      await this.save();
      const files=new NativeFiles(this.getUIContext().getHostContext() as common.UIAbilityContext,this.gateway);
      const file=await files.uploadPicked((_done:number,_total:number)=>{});
      if(file) {
        if(!/^image\/(png|jpeg|webp)$/.test(file.mime) && !/\.(png|jpe?g|webp)$/i.test(file.name))
          this.notice='画室里先放 PNG、JPEG 或 WebP 图片吧，原文件已经收进档案。';
        else this.onPick(file);
      }
    } catch(error) {if(!this.closed)this.failed(error instanceof GatewayError?error.message:'照片暂时没有导入，原稿仍在。',()=>this.pick());}
    finally {if(!this.closed)this.busy=false;}
  }
  private async use(): Promise<void> {
    if(!this.ready || this.busy || this.exporting || !this.loaded) return;
    if(!this.cursor && !this.artifact) return;
    this.exporting=true;this.clearFailure();
    try {
      if(this.cursor===0 && this.artifact) {await this.save();await this.onUse(this.artifact);return;}
      if(!this.exportId)this.exportId=this.uuid();
      await this.save();
      const body: StudioExport={source_id:this.artifact?.id || '',operations:this.operations(),operation_id:this.exportId};
      const file=await this.gateway.request<Artifact>('/api/image-studio/export',http.RequestMethod.POST,JSON.stringify(body),45000);
      await this.onUse(file);
    } catch(error) {if(!this.closed)this.failed(error instanceof GatewayError?error.message:'画页暂时没能放回对话，原稿仍在，可以再试一次。',()=>this.use());}
    finally {if(!this.closed)this.exporting=false;}
  }
  private async retry(): Promise<void> {
    if(this.busy || this.exporting) return;
    const job=this.retryJob;this.clearFailure();
    if(job) {try {await job();} catch (_) { /* The original operation retains its own recovery. */ } return;}
    if(this.unsaved) {this.save().catch(()=>{});return;}
    if(!this.loaded) {this.restore();return;}
    this.busy=true;
    try {await this.loadBase();} catch(error) {this.failed(error instanceof GatewayError?error.message:'这张画页暂时没有展开，原稿仍在。',()=>this.retryLoad());}
    finally {if(!this.closed)this.busy=false;}
  }
  private async retryLoad(): Promise<void> { this.retryJob=undefined;await this.retry(); }

  @Builder
  private Tool(name: string,kind: string) {
    Button(name).fontSize(14).height(44).fontColor(this.tool===kind?this.colors.background:this.colors.secondary)
      .backgroundColor(this.tool===kind?this.colors.accent:Color.Transparent).padding({left:16,right:16})
      .enabled(this.ready && !this.busy && !this.exporting).onClick(()=>this.selectTool(kind))
  }

  build() {
    Column({space:0}) {
      Row({space:12}) {
        Text(this.artifact?'照片批注':'随手画室').fontSize(23).fontColor(this.colors.text).layoutWeight(1)
        Button('返回').fontSize(14).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44)
          .enabled(!this.exporting).onClick(()=>this.leave())
      }.width('100%').padding({left:22,right:14,top:12,bottom:4})
      Row({space:6}) {
        Button('导入照片').fontSize(13).fontColor(this.colors.gold).backgroundColor(Color.Transparent).height(44)
          .enabled(this.loaded && !this.busy && !this.exporting).onClick(()=>{if(!this.gateway.isConfigured())this.connect();else this.pick();})
        Blank()
        Button('撤销').fontSize(13).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).height(44)
          .enabled(this.cursor>0 && !this.busy && !this.exporting).onClick(()=>this.history(-1))
        Button('重做').fontSize(13).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).height(44)
          .enabled(this.cursor<this.steps.length && !this.busy && !this.exporting).onClick(()=>this.history(1))
      }.width('100%').padding({left:12,right:12,bottom:8})
      if(this.notice) Row({space:6}) {
        Text(this.notice).fontSize(13).lineHeight(21).fontColor(this.colors.secondary).layoutWeight(1)
        Button(this.canRetry || !this.ready || this.unsaved?'重试':'收起').fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44)
          .onClick(()=>{if(this.canRetry || !this.ready || this.unsaved)this.retry();else this.clearFailure();})
      }.width('100%').padding({left:22,right:12,bottom:8})
      Stack() {
        if(this.ready && this.baseImage) Image(this.baseImage).width(this.paperW()).height(this.paperH()).objectFit(ImageFit.Fill)
          .hitTestBehavior(HitTestMode.None).onError(()=>{this.ready=false;this.notice='这一张画页暂时没有显示出来，请重新展开。';
            this.local.put('studio_image_v1',this.checkpoint(this.baseCount),'').catch(()=>{});})
        if(this.ready) Canvas(this.context).width(this.paperW()).height(this.paperH()).backgroundColor(Color.Transparent)
          .border({width:0.5,color:this.colors.border})
          .onReady(()=>{this.canvasReady=true;this.redraw();})
          .onAreaChange(()=>{this.redraw();})
          .onTouch((event:TouchEvent)=>{this.touch(event);event.stopPropagation();})
        if(this.busy) LoadingProgress().width(28).height(28).color(this.colors.accent).hitTestBehavior(HitTestMode.None)
      }.layoutWeight(1).width('100%').padding({left:18,right:18,top:6,bottom:6})
        .onAreaChange((_old:Area,next:Area)=>{this.viewportWidth=Math.max(1,Number(next.width)-36);this.viewportHeight=Math.max(1,Number(next.height)-12);})
      Scroll() {
        Row({space:4}) {
          this.Tool('画笔','pen')
          this.Tool('编号','number')
          this.Tool('马赛克','mosaic')
          this.Tool('拉正','perspective')
          Button('旋转').fontSize(14).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).height(44)
            .enabled(this.ready && !this.busy && !this.exporting).onClick(()=>this.applyEdit('rotate'))
          Button('纸张增强').fontSize(14).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).height(44)
            .enabled(this.ready && !this.busy && !this.exporting).onClick(()=>this.applyEdit('paper'))
        }.padding({left:16,right:16})
      }.width('100%').scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).padding({top:12})
      if(this.tool==='perspective') Row({space:10}) {
        Button('取消拉正').fontSize(14).fontColor(this.colors.secondary).backgroundColor(Color.Transparent).height(44)
          .onClick(()=>this.selectTool('pen'))
        Button('应用四角').fontSize(14).fontColor(this.colors.background).backgroundColor(this.colors.accent).height(44)
          .enabled(!this.busy && !this.exporting).onClick(()=>this.applyEdit('perspective'))
      }.width('100%').padding({left:20,right:20,top:10,bottom:10}).justifyContent(FlexAlign.End)
      else Row({space:12}) {
        ForEach(['#385B92FF','#C24864FF','#89682DFF','#1B233AFF'],(color:string)=>{
          Button() { Circle().width(26).height(26).fill(color.substring(0,7)) }
            .width(36).height(36).backgroundColor(Color.Transparent).padding(0)
            .border({width:2,color:this.ink===color?this.colors.accent:Color.Transparent})
            .accessibilityText(color==='#385B92FF'?'苍蓝画笔':color==='#C24864FF'?'红茶画笔':color==='#89682DFF'?'金色画笔':'墨色画笔')
            .onClick(()=>{this.ink=color;})
        })
        Slider({value:this.brush,min:1,max:9,step:1}).layoutWeight(1).selectedColor(this.colors.accent).trackColor(this.colors.border)
          .accessibilityText('笔画粗细').onChange((value:number)=>{this.brush=value;})
      }.width('100%').padding({left:24,right:24,top:12,bottom:14})
      Row() {
        Button(this.exporting?'正在收好画页…':this.gateway.isConfigured()?'放回对话':'连接琴房')
          .fontSize(16).fontColor(this.colors.background).backgroundColor(this.colors.accent).width('100%').height(48)
          .enabled(!this.busy && !this.exporting && (this.cursor>0 || this.artifact!==undefined || !this.gateway.isConfigured()))
          .onClick(()=>{if(!this.gateway.isConfigured())this.connect();else this.use();})
      }.width('100%').padding({left:22,right:22,bottom:18,top:4})
    }.width('100%').height('100%').backgroundColor(this.colors.background)
  }
}
