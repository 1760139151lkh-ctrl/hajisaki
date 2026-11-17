import { common } from '@kit.AbilityKit';
import { Palette } from '../design/Theme';
import { RelayVault, RelayImportError } from '../platform/RelayVault';
import { RelayError } from '../services/RelayTransport';
import { GatewayError } from '../services/Gateway';

@Component
export struct RelayRoom {
  @Prop colors: Palette = new Palette();
  @Prop origin: string = '';
  @Prop configured: boolean = false;
  @Prop active: boolean = false;
  @Prop restoredNotice: string = '';
  onImport: (source: string) => Promise<void> = async (_source: string) => {};
  onClose: () => void = () => {};
  @State source: string = '';
  @State showText: boolean = false;
  @State busy: boolean = false;
  @State notice: string = '';
  private vault?: RelayVault;

  aboutToAppear(): void { this.vault = new RelayVault(this.getUIContext().getHostContext() as common.UIAbilityContext); }
  aboutToDisappear(): void { this.source = ''; }
  private fail(error: Error): void {
    this.notice = error instanceof RelayImportError || error instanceof RelayError || error instanceof GatewayError ?
      error.message : '备用通道暂时没能收好，请保留主机上的通道文件。';
  }
  private async choose(): Promise<void> {
    if(this.busy || !this.vault) return;
    this.busy=true; this.notice='';
    try {
      const source=await this.vault.pick();
      if(source===undefined) return;
      await this.onImport(source); this.source=''; this.onClose();
    } catch(error) { this.fail(error as Error); }
    finally { this.busy=false; }
  }
  private async submit(): Promise<void> {
    if(this.busy || !this.source.trim()) return;
    this.busy=true; this.notice='';
    try { await this.onImport(this.source); this.source=''; this.onClose(); }
    catch(error) { this.fail(error as Error); }
    finally { this.busy=false; }
  }

  build() {
    Column({space:0}) {
      Row({space:12}) {
        Text('备用琴房').fontSize(25).fontWeight(FontWeight.Medium).fontColor(this.colors.text).layoutWeight(1)
        Button('返回主机台').fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
          .height(44).enabled(!this.busy).onClick(()=>this.onClose())
      }.width('100%').padding(20)
      Scroll() {
        Column({space:24}) {
          Row({space:18}) {
            Image($r('app.media.reconnecting_anxious')).width(84).height(108).objectFit(ImageFit.Cover).borderRadius(22)
            Text('换一条路，\n也会接住你的话。').fontSize(23).lineHeight(35).fontColor(this.colors.text).layoutWeight(1)
          }.width('100%')
          if(this.configured) Column({space:10}) {
            Text(this.active?'正在使用备用通道':'备用通道已导入').fontSize(17).fontColor(this.colors.accent).width('100%')
            Text(this.origin).fontSize(14).lineHeight(23).fontColor(this.colors.secondary).width('100%').wordBreak(WordBreak.BREAK_ALL)
          }.width('100%')
          Button(this.busy?'正在接回琴房…':'导入通道文件').fontSize(16).fontColor(this.colors.background)
            .backgroundColor(this.colors.accent).height(48).width('100%').enabled(!this.busy).onClick(()=>this.choose())
          if(!this.showText) Button('填入通道资料').fontSize(14).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
            .enabled(!this.busy).onClick(()=>{this.showText=true;})
          else Column({space:14}) {
            Text('通道资料').fontSize(14).fontColor(this.colors.secondary).width('100%')
            TextInput({text:this.source,placeholder:'主机导出的通道资料'}).type(InputType.Password).showPasswordIcon(false)
              .maxLength(32768).fontSize(15).fontColor(this.colors.text).placeholderColor(this.colors.secondary)
              .backgroundColor(this.colors.surface).enabled(!this.busy).onChange((value:string)=>{this.source=value;})
            Button(this.busy?'正在收好…':'收好并连接').fontSize(15).fontColor(this.colors.accent).backgroundColor(this.colors.surface)
              .height(46).width('100%').enabled(!this.busy && this.source.trim().length>0).onClick(()=>this.submit())
          }.width('100%')
          if(this.notice || this.restoredNotice) Text(this.notice || this.restoredNotice).fontSize(14).lineHeight(24)
            .fontColor(this.colors.secondary).width('100%')
        }.padding(24).width('100%').constraintSize({maxWidth:680})
      }.width('100%').layoutWeight(1).align(Alignment.Top)
    }.width('100%').height('100%').backgroundColor(this.colors.background)
  }
}
