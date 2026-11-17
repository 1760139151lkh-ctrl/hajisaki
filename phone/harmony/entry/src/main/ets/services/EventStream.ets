import { http } from '@kit.NetworkKit';
import { util } from '@kit.ArkTS';
import { StreamEvent } from '../model/Types';
import { Gateway } from './Gateway';
import { previewMode } from '../model/BuildMode';
import { PreviewUtf8Decoder } from './PreviewUtf8Decoder';

/** One authenticated stream per selected conversation; the caller owns durable cursors. */
export class EventStream {
  private request?: http.HttpRequest;
  private generation: number = 0;
  private watchdog: number = -1;
  onEvent: (event: StreamEvent) => void = () => {};
  onDisconnect: (error: Error) => void = () => {};

  open(gateway: Gateway, conversation: string, after: number): void {
    this.close();
    const ticket = this.generation;
    const request = http.createHttp();
    this.request = request;
    const preview=previewMode();
    const previewDecoder=preview ? new PreviewUtf8Decoder() : undefined;
    const decoder=preview ? undefined : util.TextDecoder.create('utf-8',{fatal:true});
    let buffer = '';
    let skipLeadingLF=false;
    const arm = (): void => {
      if (this.watchdog >= 0) clearTimeout(this.watchdog);
      this.watchdog = setTimeout(() => {
        if (ticket !== this.generation) return;
        this.close(); this.onDisconnect(new Error('琴房的信号暂歇，正在接回这一页。'));
      }, 45000);
    };
    const fail = (error: Error): void => {
      if (ticket !== this.generation) return;
      this.close(); this.onDisconnect(error);
    };
    request.on('dataReceive',(bytes: ArrayBuffer) => {
      if (ticket !== this.generation) return;
      arm();
      let decoded='';
      try {
        if(previewDecoder) {
          decoded=previewDecoder.decode(new Uint8Array(bytes),true);
          if(previewDecoder.hadError) { fail(new Error('这一页的文字还没传完整，正在重新接回。')); return; }
        }
        else if(decoder) decoded=decoder.decodeWithStream(new Uint8Array(bytes),{stream:true});
        else { fail(new Error('这一页的文字还没有解开。')); return; }
      } catch(_) { fail(new Error('这一页还没读完整，正在重新接回。')); return; }
      if(preview) console.info('HajiSaki preview SSE bytes='+bytes.byteLength+', decoded='+decoded.length);
      // SSE accepts CR, LF and CRLF. A CR ends its line immediately; remember
      // it only to suppress a following LF, including across decoded chunks.
      let normalized=decoded;
      if(decoded.length>0) {
        if(skipLeadingLF && normalized.startsWith('\n')) normalized=normalized.substring(1);
        skipLeadingLF=normalized.endsWith('\r');
      }
      buffer += normalized.replace(/\r\n/g,'\n').replace(/\r/g,'\n');
      // Bound malformed frames; normal capsules contain at most one provider event.
      let boundary = buffer.indexOf('\n\n');
      while (boundary >= 0) {
        if(boundary>4194304) { fail(new Error('这一页的传送格式没有对齐。')); return; }
        const frame = buffer.substring(0,boundary).replace(/\r/g,'');
        buffer = buffer.substring(boundary + 2);
        const lines = frame.split('\n');
        let data = '';
        for (const line of lines) {
          if (line.startsWith('data:')) {
            const value=line.substring(5);
            data += (data.length ? '\n' : '') + (value.startsWith(' ') ? value.substring(1) : value);
          }
        }
        if (data.length > 0) {
          try {
            const event = JSON.parse(data) as StreamEvent;
            if (!Number.isSafeInteger(event.seq) || event.conversation_id !== conversation || !event.payload) {
              fail(new Error('这一页的传送格式没有对齐。')); return;
            }
            this.onEvent(event);
            if(preview) console.info('HajiSaki preview SSE seq='+event.seq+', kind='+event.kind);
          } catch (error) { fail(new Error('这一页还没读完整，正在重新接回。')); return; }
        }
        boundary = buffer.indexOf('\n\n');
      }
      if (buffer.length > 4194304) { fail(new Error('这一页的传送格式没有对齐。')); return; }
    });
    request.on('dataEnd',() => fail(new Error('琴房的信号暂歇，正在接回这一页。')));
    const headers = gateway.headers();
    headers['Accept'] = 'text/event-stream'; headers['Last-Event-ID'] = String(after);
    arm();
    request.requestInStream(gateway.endpoint('/api/conversations/' + encodeURIComponent(conversation) + '/stream?after=' + after),{
      method:http.RequestMethod.GET,header:headers,usingCache:false,usingProxy:false,connectTimeout:4500,readTimeout:0
    }).then((code: number) => {
      if (code !== 200) fail(new Error('琴房的信号暂歇，正在重新接回。'));
    }).catch(() => fail(new Error('琴房的信号暂歇，正在重新接回。')));
  }

  close(): void {
    this.generation++;
    if (this.watchdog >= 0) clearTimeout(this.watchdog);
    this.watchdog = -1;
    if (this.request) {
      try { this.request.off('dataReceive'); this.request.off('dataEnd'); this.request.destroy(); } catch (_) {}
      this.request = undefined;
    }
  }
}
