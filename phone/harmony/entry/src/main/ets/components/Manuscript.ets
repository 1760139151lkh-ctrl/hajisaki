import { webview } from '@kit.ArkWeb';
import { Palette } from '../design/Theme';
import { NativeManuscript } from './NativeManuscript';
import { canRenderNatively } from '../model/BasicMarkdown';
import { TaskPage } from '../model/Types';
import { previewMode } from '../model/BuildMode';

class NativeHeightBridge {
  update: (height: number) => void;
  toggle: (index:number,checked:boolean) => void;
  constructor(update: (height: number) => void,toggle:(index:number,checked:boolean)=>void) { this.update = update; this.toggle=toggle; }
  height(value: string): void {
    const height = Number(value);
    if (Number.isFinite(height)) this.update(Math.max(48, Math.min(height, 24000)));
  }
  task(index:string,checked:string):void {
    const number=Number(index);
    if(Number.isSafeInteger(number)&&number>=0&&(checked==='true'||checked==='false')) this.toggle(number,checked==='true');
  }
}

@Component
export struct Manuscript {
  @Prop @Watch('contentChanged') text: string = '';
  @Prop @Watch('contentChanged') colors: Palette = new Palette();
  @Prop @Watch('contentChanged') taskState:TaskPage={tasks:{},items:[],editable:false};
  onTask:(index:number,checked:boolean)=>Promise<boolean>=async()=>false;
  @State contentHeight: number = 120;
  private controller: webview.WebviewController = new webview.WebviewController();
  private loaded: boolean = false;
  private bridge: NativeHeightBridge = new NativeHeightBridge((height: number) => { this.contentHeight = height; },
    (index:number,checked:boolean) => { this.onTask(index,checked).finally(() => this.render()); });

  private render(): void {
    if (!this.loaded) return;
    const payload = JSON.stringify({ text: this.text, theme: this.colors.light ? 'day' : 'night',taskStates:this.taskState.tasks,editable:this.taskState.editable });
    this.controller.runJavaScript('window.loadDocument(' + payload + ')').catch(() => {});
  }

  private contentChanged(): void { this.render(); }

  build() {
    if (canRenderNatively(this.text)) {
      NativeManuscript({text:this.text,colors:this.colors,taskState:this.taskState,onTask:this.onTask})
    } else if(previewMode()) {
      Column({space:8}) {
        Text('原文').fontSize(11).fontColor(this.colors.secondary)
        Text(this.text).fontSize(15).lineHeight(24).fontColor(this.colors.text).width('100%').copyOption(CopyOptions.InApp)
      }.width('100%').alignItems(HorizontalAlign.Start)
    } else {
      Web({ src: $rawfile('renderer/render-frame.html'), controller: this.controller })
        .javaScriptAccess(true)
        .domStorageAccess(false)
        .fileAccess(true)
        .onlineImageAccess(false)
        .mixedMode(MixedMode.None)
        .javaScriptProxy({ object: this.bridge, name: 'HajiNative', methodList: ['height','task'], controller: this.controller })
        .backgroundColor(this.colors.surface)
        .width('100%').height(this.contentHeight)
        .onPageEnd(() => { this.loaded = true; this.render(); })
        .onLoadIntercept((event) => {
          if (!event) return false;
          const address = event.data.getRequestUrl();
          return !address.startsWith('resource://') && !address.startsWith('file://') && address !== 'about:blank';
        })
        .onAppear(() => this.render())
    }
  }
}
