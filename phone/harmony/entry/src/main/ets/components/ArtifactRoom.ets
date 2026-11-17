import { webview } from '@kit.ArkWeb';
import { common } from '@kit.AbilityKit';
import { Artifact } from '../model/Types';
import { Palette } from '../design/Theme';
import { Gateway, GatewayError } from '../services/Gateway';
import { LocalStore } from '../services/LocalStore';
import { NativeFiles, NativeFileError } from '../platform/NativeFiles';
import { Manuscript } from './Manuscript';
import { PdfReader } from './PdfReader';
import { WorkbookReader } from './WorkbookReader';
import { ArchiveReader } from './ArchiveReader';

const MAX_DOCUMENT_BYTES: number = 1024 * 1024;
const CARD_POLICY: string = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; worker-src 'none'";

interface DocumentExcerpt { supported: boolean; text?: string; reason?: string; next_offset: number; complete: boolean }
interface CachedDocument { text: string }

export function readableArtifact(file: Artifact): boolean {
  if (/\.(pdf|xlsx)$/i.test(file.name) && file.size<=64*1024*1024) return true;
  if (/\.zip$/i.test(file.name)) return true;
  return file.size <= MAX_DOCUMENT_BYTES && (file.mime.startsWith('text/') ||
    /\.(md|markdown|txt|csv|tsv|json|jsonl|html?|css|js|mjs|ts|tsx|jsx|py|ets|java|kt|go|rs|c|cpp|h|hpp|sql|ya?ml|toml|xml)$/i.test(file.name));
}

@Component
export struct ArtifactRoom {
  @Prop artifact: Artifact = { id:'', name:'', size:0, mime:'', sha256:'', url:'' };
  @Prop colors: Palette = new Palette();
  gateway: Gateway = new Gateway();
  local: LocalStore = new LocalStore();
  onClose: () => void = () => {};
  @State text: string = '';
  @State loading: boolean = false;
  @State ready: boolean = false;
  @State notice: string = '';
  @State saving: boolean = false;
  @State saveNotice: boolean = false;
  @State raw: boolean = false;
  private closed: boolean = false;
  private attached: boolean = false;
  private controller: webview.WebviewController = new webview.WebviewController();
  private files?: NativeFiles;

  aboutToAppear(): void {
    this.files = new NativeFiles(this.getUIContext().getHostContext() as common.UIAbilityContext, this.gateway);
    if (!this.binary()) this.load();
  }
  aboutToDisappear(): void { this.closed = true; }
  private html(): boolean { return /\.html?$/i.test(this.artifact.name); }
  private markdown(): boolean { return /\.(md|markdown)$/i.test(this.artifact.name); }
  private binary(): boolean { return /\.(pdf|xlsx|zip)$/i.test(this.artifact.name); }
  private renderHtml(): void {
    if (!this.attached || !this.ready || this.closed) return;
    try {
      const prefix = '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
        '<meta http-equiv="Content-Security-Policy" content="' + CARD_POLICY + '">';
      this.controller.loadData(prefix + this.text, 'text/html', 'UTF-8', 'about:blank');
    } catch (_) { this.saveNotice = false; this.notice = '这一页暂时没能展开，原件仍可保存。'; }
  }
  private async load(): Promise<void> {
    if (this.loading || this.closed) return;
    this.loading = true; this.notice = ''; this.saveNotice = false;
    try {
      if (!readableArtifact(this.artifact)) throw new Error('这份原件较长，请保存后完整阅读。');
      const cached = await this.local.get('artifact_document', this.artifact.sha256, '');
      if (cached) {
        try {
          const document = JSON.parse(cached) as CachedDocument;
          if(typeof document.text==='string' && document.text.length<=MAX_DOCUMENT_BYTES) {
            if (!this.closed) { this.text = document.text; this.ready = true; this.renderHtml(); }
            return;
          }
        } catch (_) { /* A broken cache must not prevent reading the immutable original. */ }
      }
      let offset = 0;
      let content = '';
      while (!this.closed) {
        const part = await this.gateway.request<DocumentExcerpt>('/api/artifacts/' + encodeURIComponent(this.artifact.id) + '/text?offset=' + offset + '&limit=32000');
        if (this.closed) return;
        if (!part.supported || part.text === undefined) throw new Error(part.reason || '这一份原件还不能按文字展开。');
        content += part.text;
        if (content.length > MAX_DOCUMENT_BYTES || part.next_offset > MAX_DOCUMENT_BYTES) throw new Error('这份原件较长，请保存后完整阅读。');
        if (part.complete) break;
        if (!Number.isSafeInteger(part.next_offset) || part.next_offset <= offset) throw new Error('这一页还没有完整收齐，请稍后再试。');
        offset = part.next_offset;
      }
      if (this.closed) return;
      this.text = content; this.ready = true; this.renderHtml();
      await this.local.put('artifact_document', this.artifact.sha256, JSON.stringify({text:content} as CachedDocument));
    } catch (error) {
      if (!this.closed) this.notice = error instanceof GatewayError ? error.message : '这一页暂时没能完整展开，原件仍可保存。';
    } finally { if (!this.closed) this.loading = false; }
  }
  private async save(): Promise<void> {
    if (this.saving || !this.files) return;
    this.saving = true; this.notice = ''; this.saveNotice = true;
    try { await this.files.saveArtifact(this.artifact); }
    catch (error) { if (!this.closed) this.notice = error instanceof NativeFileError ? error.message : '这份原件暂时没能保存，请稍后再试。'; }
    finally { if (!this.closed) this.saving = false; }
  }

  build() {
    Column({space:0}) {
      Row({space:10}) {
        Text(this.artifact.name).fontSize(20).fontColor(this.colors.text).maxLines(2).layoutWeight(1)
        if(this.ready && (this.html() || this.markdown())) Button(this.raw?'排版':'原文')
          .fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44)
          .onClick(()=>{this.attached=false;this.raw=!this.raw;})
        Button('返回').fontSize(14).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44).onClick(()=>this.onClose())
      }.width('100%').padding(20)
      if (this.notice) Row({space:8}) {
        Text(this.notice).fontSize(13).fontColor(this.colors.secondary).layoutWeight(1)
        Button('重试').fontSize(13).fontColor(this.colors.accent).backgroundColor(Color.Transparent).height(44)
          .enabled(!this.loading && !this.saving).onClick(()=>{ if(this.saveNotice) this.save(); else this.load(); })
      }.width('100%').padding({left:20,right:12,bottom:12})
      if (/\.pdf$/i.test(this.artifact.name)) Column() {
        PdfReader({artifact:this.artifact,colors:this.colors,gateway:this.gateway,local:this.local})
      }.width('100%').layoutWeight(1)
      else if (/\.xlsx$/i.test(this.artifact.name)) Column() {
        WorkbookReader({artifact:this.artifact,colors:this.colors,gateway:this.gateway,local:this.local})
      }.width('100%').layoutWeight(1)
      else if (/\.zip$/i.test(this.artifact.name)) Column() {
        ArchiveReader({artifact:this.artifact,colors:this.colors,gateway:this.gateway,local:this.local})
      }.width('100%').layoutWeight(1)
      else if (this.loading && !this.ready) Column() {
        LoadingProgress().color(this.colors.accent).width(28).height(28)
      }.width('100%').layoutWeight(1).justifyContent(FlexAlign.Center)
      else if (this.ready && this.html() && !this.raw) {
        Web({src:'about:blank',controller:this.controller})
          .javaScriptAccess(true).domStorageAccess(false).fileAccess(false).onlineImageAccess(false)
          .geolocationAccess(false).blockNetwork(true).mixedMode(MixedMode.None)
          .backgroundColor(this.colors.surface).width('100%').layoutWeight(1)
          .onControllerAttached(()=>{this.attached=true;this.renderHtml();})
          .onLoadIntercept((event)=>{
            if(!event) return true;
            const address=event.data.getRequestUrl();
            return address!=='about:blank' && !address.startsWith('data:') && !address.startsWith('blob:');
          })
          .onPermissionRequest((event)=>{if(event) event.request.deny();})
      } else if (this.ready) {
        Scroll() {
          Column() {
            if(this.markdown() && !this.raw) Manuscript({text:this.text,colors:this.colors})
            else Text(this.text).fontSize(15).lineHeight(25).fontColor(this.colors.text)
              .fontFamily('monospace').copyOption(CopyOptions.InApp).width('100%')
          }.padding(20).width('100%').alignItems(HorizontalAlign.Start)
        }.width('100%').layoutWeight(1).align(Alignment.Top)
      } else Blank().layoutWeight(1)
      Button(this.saving?'正在收好…':'保存原件').fontSize(15).fontColor(this.colors.background).backgroundColor(this.colors.accent)
        .height(48).width('90%').margin({top:12,bottom:16}).enabled(!this.saving).onClick(()=>this.save())
    }.width('100%').height('100%').backgroundColor(this.colors.background)
  }
}
