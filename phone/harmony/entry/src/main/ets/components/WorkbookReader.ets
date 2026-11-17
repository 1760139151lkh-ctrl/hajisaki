import { Artifact } from '../model/Types';
import { Palette } from '../design/Theme';
import { Gateway } from '../services/Gateway';
import { LocalStore } from '../services/LocalStore';
import { ArtifactPages, SheetPage, SheetCell, cellText } from '../services/ArtifactPages';

@Component
export struct WorkbookReader {
  @Prop artifact: Artifact = {id:'',name:'',size:0,mime:'',sha256:'',url:''};
  @Prop colors: Palette = new Palette();
  gateway: Gateway = new Gateway();
  local: LocalStore = new LocalStore();
  @State page: SheetPage = {supported:false,sheet_names:[],sheet:0,name:'',columns:0,total_columns:0,
    header:[],rows:[],row_offset:0,data_rows:0,complete:true};
  @State ready: boolean = false;
  @State loading: boolean = false;
  @State notice: string = '';
  @State viewport: number = 360;
  @State rowHeights: number[] = [];
  @State headerHeight: number = 64;
  @State soft: boolean = false;
  private pages?: ArtifactPages;
  private targetSheet: number = 0;
  private targetOffset: number = 0;
  private closed: boolean = false;
  private headerScroll: Scroller = new Scroller();
  private bodyScroll: Scroller = new Scroller();
  private vertical: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pages = new ArtifactPages(this.gateway,this.local); this.soft=!this.colors.light; this.start();
  }
  aboutToDisappear(): void { this.closed=true; }
  private async start(): Promise<void> {
    const place = await this.pages!.place(this.artifact,'sheet');
    if (!this.closed) await this.load(place.sheet,place.offset);
  }
  private firstWidth(): number { return this.page.columns===1 ? this.viewport : Math.min(120,this.viewport*0.30); }
  private otherWidth(): number { return Math.max(180,Math.min(260,this.viewport-this.firstWidth())); }
  private color(value: string|null, fallback: string): string { return value && /^#[0-9a-f]{6}$/i.test(value) ? value : fallback; }
  private cellAlignment(cell: SheetCell): TextAlign { return cell.align==='right'?TextAlign.End:cell.align==='center'?TextAlign.Center:TextAlign.Start; }
  private value(cell: SheetCell): string { return cellText(cell)+(cell.truncated?'\n本格仅展开前2,000字；完整内容在原件中。':''); }
  private measure(row: SheetCell[], header: boolean): number {
    let height = header?52:42;
    row.forEach((cell:SheetCell,index:number)=>{
      const measured = this.getUIContext().getMeasureUtils().measureTextSize({
        textContent:this.value(cell),constraintWidth:(index===0?this.firstWidth():this.otherWidth())-24,
        fontSize:13,lineHeight:21,fontWeight:header||cell.bold?FontWeight.Medium:FontWeight.Normal,wordBreak:WordBreak.BREAK_ALL
      });
      height=Math.max(height,Math.ceil(this.getUIContext().px2vp(Number(measured.height)))+(index===0?42:24));
    });
    return height;
  }
  private measureRows(): void {
    if (!this.ready) return;
    this.headerHeight=this.measure(this.page.header,true);
    this.rowHeights=this.page.rows.map((row:SheetCell[])=>this.measure(row,false));
  }
  private sync(source: Scroller, destination: Scroller): void {
    try {
      const value=source.currentOffset().xOffset;
      if (Math.abs(value-destination.currentOffset().xOffset)>0.5) destination.scrollTo({xOffset:value,yOffset:0});
    } catch (_) { /* The other scroll surface may still be attaching. */ }
  }
  private resetScroll(): void {
    if (!this.ready) return;
    try {
      this.headerScroll.scrollTo({xOffset:0,yOffset:0}); this.bodyScroll.scrollTo({xOffset:0,yOffset:0});
      this.vertical.scrollTo({xOffset:0,yOffset:0});
    } catch (_) {}
  }
  private async load(sheet: number, offset: number): Promise<void> {
    if (this.loading || this.closed || !this.pages) return;
    this.loading=true; this.notice=''; this.targetSheet=sheet; this.targetOffset=offset;
    try {
      const result = await this.pages.read<SheetPage>('artifact_sheet_v1',this.artifact,sheet+':'+offset,
        '/api/artifacts/'+encodeURIComponent(this.artifact.id)+'/sheet?sheet='+sheet+'&offset='+offset+'&limit=20',
        (value:SheetPage):boolean=>value.sheet===sheet && value.row_offset===offset && Array.isArray(value.rows) && value.rows.length<=20 &&
          Array.isArray(value.header) && value.header.length>=1 && value.header.length<=64 &&
          Array.isArray(value.sheet_names) && value.sheet_names.length>sheet && Number.isSafeInteger(value.data_rows) && value.data_rows>=0);
      if (this.closed) return;
      this.resetScroll(); this.page=result.data; this.ready=true; this.measureRows();
      if (!result.stored) this.notice='这张表已展开，暂时还不能留到离线。';
      await this.pages.remember(this.artifact,'sheet',{page:0,sheet:sheet,offset:offset,zoom:1});
    } catch (error) {
      if (!this.closed) this.notice=error instanceof Error?error.message:'这一页暂时没有取到，当前这页还在。';
    } finally { if (!this.closed) this.loading=false; }
  }

  @Builder
  private FirstCell(cell: SheetCell, row: number, height: number, heading: boolean) {
    Column({space:4}) {
      Text(String(row)).fontSize(10).fontColor(heading?'#BBCBE5':'#64748B')
      Text(this.value(cell)).fontSize(13).lineHeight(21).fontWeight(heading||cell.bold?FontWeight.Medium:FontWeight.Normal)
        .fontColor(this.color(cell.color,heading?'#FFFFFF':'#1B233A')).width('100%').wordBreak(WordBreak.BREAK_ALL)
        .textAlign(this.cellAlignment(cell)).copyOption(CopyOptions.InApp)
    }.alignItems(HorizontalAlign.Start).width(this.firstWidth()).height(height).padding(12)
      .backgroundColor(this.color(cell.background,heading?'#1B233A':row%2?'#F3F6FC':'#FFFFFF'))
      .border({width:{right:0.5,bottom:0.5},color:'#D4DEEC'})
  }
  @Builder
  private OtherCell(cell: SheetCell, height: number, heading: boolean, row: number) {
    Text(this.value(cell)).fontSize(13).lineHeight(21).fontWeight(heading||cell.bold?FontWeight.Medium:FontWeight.Normal)
      .fontColor(this.color(cell.color,heading?'#FFFFFF':'#1B233A')).width(this.otherWidth()).height(height)
      .padding(12).align(Alignment.TopStart).wordBreak(WordBreak.BREAK_ALL).textAlign(this.cellAlignment(cell)).copyOption(CopyOptions.InApp)
      .backgroundColor(this.color(cell.background,heading?'#1B233A':row%2?'#F3F6FC':'#FFFFFF'))
      .border({width:{right:0.5,bottom:0.5},color:'#D4DEEC'})
  }
  build() {
    Column({space:0}) {
      if (this.ready) Column({space:8}) {
        Row({space:10}) {
          Select(this.page.sheet_names.map((name:string):SelectOption=>({value:name}))).selected(this.page.sheet).value(this.page.name)
            .font({size:14}).fontColor(this.colors.text).backgroundColor(this.colors.raised).enabled(!this.loading)
            .optionFont({size:14}).optionFontColor(this.colors.text).optionBgColor(this.colors.surface)
            .selectedOptionFont({size:14}).selectedOptionFontColor(this.colors.accent).selectedOptionBgColor(this.colors.raised)
            .menuBackgroundColor(this.colors.surface).menuBackgroundBlurStyle(BlurStyle.NONE)
            .onSelect((index:number)=>this.load(index,0))
          if (this.loading) LoadingProgress().width(18).height(18).color(this.colors.accent)
          Blank()
          Button(this.soft?'原色':'柔光').fontSize(13).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
            .onClick(()=>{this.soft=!this.soft;})
        }.width('100%')
        Text(this.page.sheet_names.length+' 张表 · '+this.page.data_rows+' 行资料 · '+this.page.total_columns+' 列')
          .fontSize(12).fontColor(this.colors.secondary).width('100%')
      }.width('100%').padding({left:20,right:20,bottom:14})
      if (this.notice) Row({space:8}) {
        Text(this.notice).fontSize(13).fontColor(this.colors.secondary).layoutWeight(1)
        Button('再翻一次').fontSize(12).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
          .enabled(!this.loading).onClick(()=>this.load(this.targetSheet,this.targetOffset))
      }.width('100%').padding({left:20,right:12,bottom:10})
      if (!this.ready && this.loading) Column() {
        LoadingProgress().width(28).height(28).color(this.colors.accent)
      }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      else if (this.ready) Column({space:0}) {
        Row({space:0}) {
          ForEach(this.page.header.slice(0,1),(cell:SheetCell)=>{
            this.FirstCell(cell,1,this.headerHeight,true)
          })
          if (this.page.columns>1) Scroll(this.headerScroll) {
            Row({space:0}) {
              ForEach(this.page.header.slice(1),(cell:SheetCell)=>{this.OtherCell(cell,this.headerHeight,true,1);})
            }
          }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Off).layoutWeight(1).height(this.headerHeight)
            .onDidScroll((_x:number,_y:number,_state:ScrollState)=>this.sync(this.headerScroll,this.bodyScroll))
        }.width('100%').height(this.headerHeight)
        Scroll(this.vertical) {
          Row({space:0}) {
            Column({space:0}) {
              ForEach(this.page.rows,(row:SheetCell[],index:number)=>{
                this.FirstCell(row[0],this.page.row_offset+index+2,this.rowHeights[index]||42,false)
              })
            }.width(this.firstWidth())
            if (this.page.columns>1) Scroll(this.bodyScroll) {
              Column({space:0}) {
                ForEach(this.page.rows,(row:SheetCell[],index:number)=>{
                  Row({space:0}) {
                    ForEach(row.slice(1),(cell:SheetCell)=>{this.OtherCell(cell,this.rowHeights[index]||42,false,this.page.row_offset+index+2);})
                  }.height(this.rowHeights[index]||42)
                })
              }
            }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Auto).layoutWeight(1)
              .onDidScroll((_x:number,_y:number,_state:ScrollState)=>this.sync(this.bodyScroll,this.headerScroll))
          }.alignItems(VerticalAlign.Top).width('100%')
        }.scrollable(ScrollDirection.Vertical).scrollBar(BarState.Auto).layoutWeight(1).width('100%')
      }.width('calc(100% - 24vp)').layoutWeight(1).clip(true).borderRadius(10).margin({left:12,right:12}).opacity(this.soft?0.76:1)
        .onAreaChange((_old:Area,area:Area)=>{
          const width=Number(area.width);
          if(Number.isFinite(width)&&width>100&&Math.abs(width-this.viewport)>1) {this.viewport=width;this.measureRows();}
        })
      else Blank().layoutWeight(1)
      if (this.ready) {
        Row({space:8}) {
          Button('上一页').fontSize(13).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
            .enabled(!this.loading&&this.page.row_offset>0).onClick(()=>this.load(this.page.sheet,Math.max(0,this.page.row_offset-20)))
          Text(this.page.data_rows?(this.page.row_offset+1)+'–'+(this.page.row_offset+this.page.rows.length)+' / '+this.page.data_rows+' 行':'只有表头')
            .fontSize(12).fontColor(this.colors.secondary).layoutWeight(1).textAlign(TextAlign.Center)
          Button('下一页').fontSize(13).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
            .enabled(!this.loading&&!this.page.complete).onClick(()=>this.load(this.page.sheet,this.page.row_offset+20))
        }.width('100%').padding({left:12,right:12})
        Text(this.page.total_columns>this.page.columns?'当前展开前'+this.page.columns+'列，完整内容在原件中。':'左右滑动可读全部列，表头与首列会留在原处。')
          .fontSize(11).fontColor(this.colors.secondary).width('100%').padding({left:20,right:20,bottom:6})
      }
    }.width('100%').height('100%')
  }
}
