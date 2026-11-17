import { pasteboard } from '@kit.BasicServicesKit';
import { Palette } from '../design/Theme';
import { BasicBlock, BasicSpan, parseBasicMarkdown } from '../model/BasicMarkdown';
import { TaskPage } from '../model/Types';

@Observed
class NativeBlockState {
  block: BasicBlock;
  constructor(block: BasicBlock) { this.block = block; }
}

@Component
struct NativeCode {
  @Prop @Watch('blockChanged') block: BasicBlock = { id: '', kind: 'code', level: 0, marker: '', language: '',
    source: '', code: '', spans: [], taskIndex: -1, taskText: '', initialChecked: false };
  @Prop colors: Palette = new Palette();
  @State expanded: boolean = false;
  @State copied: boolean = false;
  @State copyFailed: boolean = false;

  private blockChanged(): void { this.copied = false; this.copyFailed = false; }

  private lines(): string[] {
    // Display omits the terminal fence-separating newline; copying uses the
    // untouched original body, including CRLF and its final newline.
    return this.block.code.replace(/\r?\n$/, '').split(/\r?\n/);
  }
  private visibleLines(): string[] {
    const lines = this.lines();
    return this.expanded ? lines : lines.slice(0, 30);
  }
  private lineNumbers(): string {
    return this.visibleLines().map((_line: string, index: number) => String(index + 1)).join('\n');
  }
  private async copy(): Promise<void> {
    try {
      await pasteboard.getSystemPasteboard().setData(
        pasteboard.createData(pasteboard.MIMETYPE_TEXT_PLAIN, this.block.code));
      this.copied = true; this.copyFailed = false;
    } catch (_) { this.copyFailed = true; this.copied = false; }
  }

  build() {
    Column({ space: 0 }) {
      Row({ space: 12 }) {
        Text(this.block.language || '代码').fontSize(12).fontColor(this.colors.secondary)
        Blank()
        Button(this.copyFailed ? '再复制一次' : this.copied ? '已复制' : '复制代码')
          .fontSize(12).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
          .height(34).onClick(() => this.copy())
      }.width('100%').padding({ left: 12, right: 8 }).backgroundColor(this.colors.raised)
      Scroll() {
        Row({ space: 14 }) {
          Text(this.lineNumbers()).fontFamily('monospace').fontSize(12).lineHeight(21)
            .fontColor(this.colors.secondary).textAlign(TextAlign.End)
          Text(this.visibleLines().join('\n')).fontFamily('monospace').fontSize(13).lineHeight(21)
            .fontColor(this.colors.text).copyOption(CopyOptions.InApp)
        }.alignItems(VerticalAlign.Top).padding(12)
      }.scrollable(ScrollDirection.Horizontal).scrollBar(BarState.Auto)
        .width('100%').height(this.visibleLines().length * 21 + 24)
      if (this.lines().length > 30) {
        Button(this.expanded ? '收起代码' : '展开全部 ' + this.lines().length + ' 行')
          .fontSize(12).fontColor(this.colors.accent).backgroundColor(Color.Transparent)
          .height(38).width('100%').onClick(() => { this.expanded = !this.expanded; })
      }
    }.width('100%').backgroundColor(this.colors.surface).borderRadius(10)
      .border({ width: 0.5, color: this.colors.border }).clip(true)
  }
}

@Component
struct NativeBlockView {
  @ObjectLink @Watch('taskChanged') state: NativeBlockState;
  @Prop colors: Palette = new Palette();
  @Prop @Watch('taskChanged') taskState: TaskPage = { tasks: {}, items: [], editable: false };
  onTask: (index: number, checked: boolean) => Promise<boolean> = async (_index: number, _checked: boolean) => false;
  @State taskBusy: boolean = false;
  @State taskChecked: boolean = false;
  private taskIdentity: string = '';
  private taskGeneration: number = 0;

  aboutToAppear(): void { this.taskChanged(); }
  aboutToDisappear(): void { this.taskGeneration++; }

  private taskMatches(): boolean {
    const block = this.state.block;
    if (block.kind !== 'task' || block.taskIndex < 0 || block.taskIndex >= this.taskState.items.length) return false;
    const item = this.taskState.items[block.taskIndex];
    return item.index === block.taskIndex && item.text === block.taskText;
  }

  private authoritativeChecked(): boolean {
    const block = this.state.block;
    if (!this.taskMatches()) return block.initialChecked;
    const checked = this.taskState.tasks[String(block.taskIndex)];
    return typeof checked === 'boolean' ? checked : this.taskState.items[block.taskIndex].initial_checked;
  }

  private taskChanged(): void {
    const identity = String(this.state.block.taskIndex) + '\n' + this.state.block.taskText;
    if (identity !== this.taskIdentity) {
      this.taskIdentity = identity;
      this.taskGeneration++;
      this.taskBusy = false;
    }
    if (!this.taskBusy) this.taskChecked = this.authoritativeChecked();
  }

  private async updateTask(checked: boolean): Promise<void> {
    if (this.taskBusy || !this.taskState.editable || !this.taskMatches()) {
      this.taskChecked = this.authoritativeChecked();
      return;
    }
    const index = this.state.block.taskIndex;
    const text = this.state.block.taskText;
    const ticket = ++this.taskGeneration;
    this.taskBusy = true;
    // Keep the native control bound while the pending spinner hides the
    // tentative value. A rejection then causes an actual state transition back.
    this.taskChecked = checked;
    let accepted = false;
    try { accepted = await this.onTask(index, checked); }
    catch (_) { accepted = false; }
    finally {
      if (ticket === this.taskGeneration) {
        const sameTask = this.state.block.taskIndex === index && this.state.block.taskText === text && this.taskMatches();
        // A check mark is committed only after the callback acknowledges the
        // backend update. Failure or a changed task restores authoritative state.
        this.taskChecked = accepted && sameTask ? checked : this.authoritativeChecked();
        this.taskBusy = false;
      }
    }
  }

  private headingSize(level: number): number { return level === 1 ? 25 : level === 2 ? 22 : level === 3 ? 19 : 17; }

  @Builder
  private inline(block: BasicBlock, size: number) {
    Text() {
      ForEach(block.spans, (span: BasicSpan) => {
        Span(span.text)
          .fontWeight(span.strong || block.kind === 'heading' ? FontWeight.Bold : FontWeight.Normal)
          .fontStyle(span.emphasis ? FontStyle.Italic : FontStyle.Normal)
          .fontFamily(span.code ? 'monospace' : 'sans-serif')
          .fontSize(span.code ? Math.max(13, size - 2) : size)
          .fontColor(span.code ? this.colors.accent : this.colors.text)
      })
    }.fontSize(size).lineHeight(size + 11).fontColor(this.colors.text)
      .copyOption(CopyOptions.InApp).wordBreak(WordBreak.BREAK_WORD).width('100%')
  }

  build() {
    Column() {
        if (this.state.block.kind === 'code') {
          NativeCode({ block: this.state.block, colors: this.colors })
        } else if (this.state.block.kind === 'heading') {
          this.inline(this.state.block, this.headingSize(this.state.block.level))
        } else if (this.state.block.kind === 'task') {
          Row({ space: 4 }) {
            if (this.state.block.marker.length > 0) {
              Text(this.state.block.marker).fontSize(16).lineHeight(27).fontColor(this.colors.secondary)
                .constraintSize({ minWidth: 28, maxWidth: 96 }).textAlign(TextAlign.End)
            }
            Stack() {
              Checkbox({ name: 'task-' + this.state.block.taskIndex })
                .select(this.taskChecked).selectedColor(this.colors.accent).unselectedColor(this.colors.secondary)
                .shape(CheckBoxShape.ROUNDED_SQUARE).width(22).height(22).margin(0)
                .enabled(!this.taskBusy && this.taskState.editable && this.taskMatches())
                .opacity(this.taskBusy ? 0 : 1)
                .accessibilityText(this.state.block.taskText)
                .onChange((checked: boolean) => this.updateTask(checked))
              if (this.taskBusy) LoadingProgress().width(20).height(20).color(this.colors.accent)
            }.width(40).height(32)
            Column() { this.inline(this.state.block, 16) }.layoutWeight(1).padding({ top: 2 })
          }.alignItems(VerticalAlign.Top).width('100%')
        } else if (this.state.block.kind === 'list') {
          Row({ space: 9 }) {
            Text(this.state.block.marker).fontSize(16).lineHeight(27).fontColor(this.colors.secondary)
              .constraintSize({ minWidth: 28, maxWidth: 96 }).textAlign(TextAlign.End)
            Column() { this.inline(this.state.block, 16) }.layoutWeight(1)
          }.alignItems(VerticalAlign.Top).width('100%')
        } else if (this.state.block.kind === 'quote') {
          Column() { this.inline(this.state.block, 16) }.width('100%')
            .padding({ left: 13, top: 3, bottom: 3 })
            .border({ width: { left: 2 }, color: this.colors.gold })
        } else {
          this.inline(this.state.block, 16)
        }
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}

@Component
export struct NativeManuscript {
  @Prop @Watch('contentChanged') text: string = '';
  @Prop colors: Palette = new Palette();
  @Prop taskState: TaskPage = { tasks: {}, items: [], editable: false };
  onTask: (index: number, checked: boolean) => Promise<boolean> = async (_index: number, _checked: boolean) => false;
  @State blocks: NativeBlockState[] = [];

  aboutToAppear(): void { this.contentChanged(); }
  private contentChanged(): void {
    const parsed = parseBasicMarkdown(this.text);
    const next: NativeBlockState[] = [];
    for (const block of parsed.blocks) {
      const existing = this.blocks.find((item: NativeBlockState) => item.block.id === block.id);
      if (existing) {
        existing.block = block;
        next.push(existing);
      } else next.push(new NativeBlockState(block));
    }
    this.blocks = next;
  }

  build() {
    Column({ space: 12 }) {
      ForEach(this.blocks, (item: NativeBlockState) => {
        NativeBlockView({ state: item, colors: this.colors, taskState: this.taskState, onTask: this.onTask })
      // Inline builders hold an immutable block snapshot. Rebuild changed prose
      // during streaming; unchanged blocks and expandable code keep identity.
      }, (item: NativeBlockState) => item.block.id + ':' + (item.block.kind === 'code' ? 'code' : item.block.source))
    }.width('100%').alignItems(HorizontalAlign.Start)
  }
}
