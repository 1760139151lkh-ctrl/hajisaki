export interface BasicSpan { text: string; strong: boolean; emphasis: boolean; code: boolean }
export interface BasicBlock {
  id: string;
  kind: string;
  level: number;
  marker: string;
  language: string;
  source: string;
  code: string;
  spans: BasicSpan[];
  taskIndex: number;
  taskText: string;
  initialChecked: boolean;
}
export interface BasicDocument { supported: boolean; blocks: BasicBlock[] }
interface InlineResult { supported: boolean; spans: BasicSpan[] }
interface SourceLine { text: string; start: number; end: number }

/** A deliberately bounded subset. Unsupported syntax remains the Web renderer's responsibility. */
export function canRenderNatively(text: string): boolean {
  return parseBasicMarkdown(text).supported;
}

export function parseBasicMarkdown(text: string): BasicDocument {
  const lines: SourceLine[] = [];
  let position = 0;
  for (const raw of text.split('\n')) {
    const end = Math.min(text.length, position + raw.length + 1);
    lines.push({ text: raw.replace(/\r$/, ''), start: position, end: end });
    position = end;
  }
  const blocks: BasicBlock[] = [];
  let index = 0;
  let orderedNext = -1;
  let orderedDelimiter = '';
  let nextTaskIndex = 0;
  while (index < lines.length) {
    const line = lines[index];
    const value = line.text;
    if (!value.trim()) { index++; continue; }
    // Nested/indented blocks, tables, rules and Setext headings stay with the
    // full parser; treating them as plain text would silently change meaning.
    if (/^[ \t]+\S/.test(value) || /^(?:[-*_]\s*){3,}$/.test(value) || /^(?:=+|-+)\s*$/.test(value)) {
      return { supported: false, blocks: [] };
    }
    const fence = value.match(/^(`{3,}|~{3,})([^\r\n]*)$/);
    if (fence) {
      orderedNext = -1;
      const marker = fence[1];
      const language = fence[2].trim();
      if (!/^[A-Za-z0-9_+#.-]*$/.test(language) ||
        /^(mermaid|echarts|abc|math|latex|tex|html|svg|xml)$/i.test(language)) {
        return { supported: false, blocks: [] };
      }
      const bodyStart = line.end;
      let closing = index + 1;
      while (closing < lines.length && !closesFence(lines[closing].text, marker)) closing++;
      const bodyEnd = closing < lines.length ? lines[closing].start : text.length;
      const sourceEnd = closing < lines.length ? lines[closing].end : text.length;
      blocks.push({ id: String(line.start), kind: 'code', level: 0, marker: '', language: language,
        source: text.substring(line.start, sourceEnd), code: text.substring(bodyStart, bodyEnd), spans: [],
        taskIndex: -1, taskText: '', initialChecked: false });
      index = closing < lines.length ? closing + 1 : lines.length;
      continue;
    }
    const heading = value.match(/^(#{1,6})[ \t]+(.*)$/);
    const bullet = value.match(/^([-+*])[ \t]+(.+)$/);
    const numbered = value.match(/^(\d{1,9})([.)])[ \t]+(.+)$/);
    const quote = value.match(/^>[ \t]?(.*)$/);
    let kind = 'paragraph';
    let level = 0;
    let marker = '';
    let content = value;
    let last = index;
    let taskIndex = -1;
    let taskText = '';
    let initialChecked = false;
    if (heading) {
      kind = 'heading'; level = heading[1].length;
      content = heading[2].replace(/[ \t]+#+[ \t]*$/, '');
      orderedNext = -1;
    } else if (bullet) {
      kind = 'list'; marker = '•'; content = bullet[2]; orderedNext = -1;
    } else if (numbered) {
      kind = 'list'; content = numbered[3];
      if (orderedNext < 0 || orderedDelimiter !== numbered[2]) orderedNext = Number(numbered[1]);
      orderedDelimiter = numbered[2]; marker = String(orderedNext++) + '.';
    } else if (quote) {
      kind = 'quote'; orderedNext = -1;
      const quoted: string[] = [quote[1]];
      while (last + 1 < lines.length && /^>/.test(lines[last + 1].text)) {
        last++; quoted.push(lines[last].text.replace(/^>[ \t]?/, ''));
      }
      if (quoted.some((part: string) => !part.trim() || startsBlock(part))) return { supported: false, blocks: [] };
      content = joinParagraph(quoted);
    } else {
      orderedNext = -1;
      const paragraph: string[] = [value];
      while (last + 1 < lines.length && lines[last + 1].text.trim() && !startsBlock(lines[last + 1].text)) {
        last++;
        if (/^[ \t]+\S/.test(lines[last].text)) return { supported: false, blocks: [] };
        paragraph.push(lines[last].text);
      }
      content = joinParagraph(paragraph);
    }
    if (kind === 'list') {
      const task = content.match(/^\[([ xX])\][ \t]+(.+)$/);
      if (task) {
        kind = 'task';
        taskIndex = nextTaskIndex++;
        taskText = task[2];
        initialChecked = task[1].toLowerCase() === 'x';
        content = taskText;
        if (bullet) marker = '';
      }
    }
    if ((kind === 'list' || kind === 'task' || kind === 'quote') && last + 1 < lines.length &&
      lines[last + 1].text.trim() && !startsBlock(lines[last + 1].text)) {
      // Lazy continuation and nested blocks require the full container parser.
      return { supported: false, blocks: [] };
    }
    const inline = parseInline(content, false, false, 0);
    if (!inline.supported) return { supported: false, blocks: [] };
    blocks.push({ id: String(line.start), kind: kind, level: level, marker: marker, language: '',
      source: text.substring(line.start, lines[last].end), code: '', spans: inline.spans,
      taskIndex: taskIndex, taskText: taskText, initialChecked: initialChecked });
    index = last + 1;
  }
  return { supported: true, blocks: blocks };
}

function closesFence(line: string, opening: string): boolean {
  const trimmed = line.replace(/^ {0,3}/, '').trimEnd();
  if (trimmed.length < opening.length || trimmed[0] !== opening[0]) return false;
  for (const character of trimmed) if (character !== opening[0]) return false;
  return true;
}

function startsBlock(line: string): boolean {
  return /^(?:#{1,6}[ \t]|>|[-+*][ \t]|\d{1,9}[.)][ \t]|`{3,}|~{3,}|(?:[-*_]\s*){3,}$|(?:=+|-+)\s*$)/.test(line);
}

function joinParagraph(lines: string[]): string {
  let result = '';
  for (let index = 0; index < lines.length; index++) {
    const value = lines[index];
    result += value.replace(/[ \t]+$/, '');
    if (index + 1 < lines.length) result += / {2,}$/.test(value) ? '\n' : ' ';
  }
  return result;
}

function parseInline(text: string, strong: boolean, emphasis: boolean, depth: number): InlineResult {
  if (depth > 8) return { supported: false, spans: [] };
  const spans: BasicSpan[] = [];
  let plain = '';
  let index = 0;
  while (index < text.length) {
    const character = text[index];
    if (character === '\\') {
      const next = text[index + 1] || '';
      if (next === '(' || next === '[' || !/[!"#$%&'*+,\-./:;<=>?@[\\\]^_`{|}~]/.test(next)) {
        return { supported: false, spans: [] };
      }
      plain += next; index += 2; continue;
    }
    if (character === '`') {
      if (plain) { spans.push({ text: plain, strong: strong, emphasis: emphasis, code: false }); plain = ''; }
      const length = runLength(text, index, '`');
      const marker = '`'.repeat(length);
      const end = findCodeEnd(text, index + length, marker);
      if (end < 0) return { supported: false, spans: [] };
      let code = text.substring(index + length, end).replace(/\n/g, ' ');
      if (code.startsWith(' ') && code.endsWith(' ') && code.trim().length > 0) code = code.slice(1, -1);
      spans.push({ text: code, strong: strong, emphasis: emphasis, code: true });
      index = end + length; continue;
    }
    if ('[]<>$|'.includes(character) || text.substring(index, index + 2) === '~~' ||
      ('hHwWmM'.includes(character) && /^(?:https?:\/\/|www\.|mailto:)/i.test(text.substring(index, index + 8))) ||
      (character === '&' && /^&(?:#\d+|#x[\da-f]+|[a-z][a-z\d]+);/i.test(text.substring(index)))) {
      return { supported: false, spans: [] };
    }
    if (character === '*' || character === '_') {
      const length = runLength(text, index, character);
      if (length > 2) return { supported: false, spans: [] };
      const before = index > 0 ? text[index - 1] : '';
      const after = text[index + length] || '';
      if ((character === '_' && isWord(before) && isWord(after)) || !after || /\s/.test(after)) {
        plain += character.repeat(length); index += length; continue;
      }
      const marker = character.repeat(length);
      const end = findEmphasisEnd(text, index + length, marker);
      if (end < 0) return { supported: false, spans: [] };
      if (plain) { spans.push({ text: plain, strong: strong, emphasis: emphasis, code: false }); plain = ''; }
      const inner = parseInline(text.substring(index + length, end), strong || length === 2, emphasis || length === 1, depth + 1);
      if (!inner.supported) return inner;
      spans.push(...inner.spans);
      index = end + length; continue;
    }
    plain += character; index++;
  }
  if (plain) spans.push({ text: plain, strong: strong, emphasis: emphasis, code: false });
  return { supported: true, spans: spans };
}

function runLength(text: string, start: number, character: string): number {
  let end = start;
  while (end < text.length && text[end] === character) end++;
  return end - start;
}

function findCodeEnd(text: string, start: number, marker: string): number {
  let position = text.indexOf(marker, start);
  while (position >= 0) {
    if (text[position - 1] !== '`' && text[position + marker.length] !== '`') return position;
    position = text.indexOf(marker, position + marker.length);
  }
  return -1;
}

function findEmphasisEnd(text: string, start: number, marker: string): number {
  let position = start;
  while (position < text.length) {
    if (text[position] === '\\') { position += 2; continue; }
    if (text[position] === '`') {
      const length = runLength(text, position, '`');
      const end = findCodeEnd(text, position + length, '`'.repeat(length));
      if (end < 0) return -1;
      position = end + length; continue;
    }
    if (text.substring(position, position + marker.length) === marker &&
      text[position - 1] !== marker[0] && text[position + marker.length] !== marker[0] &&
      !/\s/.test(text[position - 1]) &&
      (marker[0] !== '_' || !isWord(text[position + marker.length] || ''))) return position;
    position++;
  }
  return -1;
}

function isWord(character: string): boolean { return /[A-Za-z0-9\u3400-\u9fff]/.test(character); }
