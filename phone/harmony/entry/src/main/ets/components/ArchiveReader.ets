import { Artifact } from '../model/Types';
import { Palette } from '../design/Theme';
import { Gateway } from '../services/Gateway';
import { LocalStore } from '../services/LocalStore';
import { ArchiveEntry, ArchivePage, ArtifactPages, documentSize } from '../services/ArtifactPages';

@Component
export struct ArchiveReader {
  @Prop artifact: Artifact = {id:'',name:'',size:0,mime:'',sha256:'',url:''};
  @Prop colors: Palette = new Palette();
  gateway: Gateway = new Gateway();
  local: LocalStore = new LocalStore();
  @State entries: ArchiveEntry[] = [];
  @State entryOffset: number = 0;
  @State total: number = 0;
  @State expanded: number = 0;
  @State ready: boolean = false;
  @State loading: boolean = false;
  @State complete: boolean = true;
  @State notice: string = '';
  private pages?: ArtifactPages;
  private target: number = 0;
  private closed: boolean = false;
  private scroll: Scroller = new Scroller();

  aboutToAppear(): void {
    this.pages = new ArtifactPages(this.gateway,this.local);
    this.start();
  }
  aboutToDisappear(): void { this.closed = true; }
  private async start(): Promise<void> {
    const place = await this.pages!.place(this.artifact,'archive');
    if (!this.closed) await this.load(place.offset);
  }
  private async load(offset: number): Promise<void> {
    if (this.loading || this.closed || !this.pages) return;
    this.loading=true; this.notice=''; this.target=offset;
    try {
      const result = await this.pages.read<ArchivePage>('artifact_archive_v1',this.artifact,String(offset),
        '/api/artifacts/'+encodeURIComponent(this.artifact.id)+'/text?page='+offset+'&limit=20',
        (value: ArchivePage): boolean => Array.isArray(value.entries) && value.entries.length<=20 &&
          Number.isSafeInteger(value.total_entries) && value.total_entries>=offset && Number.isFinite(value.expanded_size));
      if (this.closed) return;
      this.entries=result.data.entries; this.entryOffset=offset; this.total=result.data.total_entries;
      this.expanded=result.data.expanded_size; this.complete=result.data.complete; this.ready=true;
      if (!result.stored) this.notice='目录已展开，暂时还不能留到离线。';
      try { this.scroll.scrollTo({xOffset:0,yOffset:0}); } catch (_) {}
      await this.pages.remember(this.artifact,'archive',{page:0,sheet:0,offset:offset,zoom:1});
    } catch (error) {
      if (!this.closed) this.notice=error instanceof Error ? error.message : '这一页暂时没有取到，原件仍可保存。';
    } finally { if (!this.closed) this.loading=false; }
  }

  build() {
    Column({space:0}) {
      if (this.ready) Text(this.total+' 项原件 · 展开后 '+documentSize(this.expanded))
        .fontSize(13).fontColor(this.colors.secondary).width('100%').padding({left:20,right:20,bottom:14})
      if (this.notice) Row({space:8}) {
        Text(this.notice).fontSize(13).fontColor(this.colors.secondary).layoutWeight(1)
        Button('再翻一次').fontSize(12).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
          .height(44).enabled(!this.loading).onClick(()=>this.load(this.target))
      }.width('100%').padding({left:20,right:12,bottom:10})
      if (!this.ready && this.loading) Column() {
        LoadingProgress().width(28).height(28).color(this.colors.accent)
      }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      else List({scroller:this.scroll}) {
        ForEach(this.entries,(entry:ArchiveEntry)=>{
          ListItem() {
            Row({space:14}) {
              Text(entry.name).fontSize(15).lineHeight(24).fontColor(this.colors.text).layoutWeight(1)
                .wordBreak(WordBreak.BREAK_ALL).copyOption(CopyOptions.InApp)
              Text(entry.directory?'目录':documentSize(entry.size)).fontSize(12).fontColor(this.colors.secondary)
            }.width('100%').alignItems(VerticalAlign.Top).padding({top:18,bottom:18,left:20,right:20})
              .border({width:{bottom:0.5},color:this.colors.border})
          }
        },(entry:ArchiveEntry)=>entry.name)
      }.width('100%').layoutWeight(1)
      if (this.ready && this.total>20) Row({space:10}) {
        Button('上一页').fontSize(13).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
          .enabled(!this.loading&&this.entryOffset>0).onClick(()=>this.load(Math.max(0,this.entryOffset-20)))
        Text((this.entryOffset+1)+'–'+(this.entryOffset+this.entries.length)+' / '+this.total).fontSize(12)
          .fontColor(this.colors.secondary).layoutWeight(1).textAlign(TextAlign.Center)
        Button('下一页').fontSize(13).height(44).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
          .enabled(!this.loading&&!this.complete).onClick(()=>this.load(this.entryOffset+this.entries.length))
      }.width('100%').padding({left:12,right:12})
    }.width('100%').height('100%')
  }
}
