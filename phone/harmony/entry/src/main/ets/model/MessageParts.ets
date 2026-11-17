import { Message } from './Types';
import { canRenderNatively } from './BasicMarkdown';

@Observed
export class MessagePart {
  id: string;
  message: Message;
  text: string;
  first: boolean;
  last: boolean;
  constructor(id: string, message: Message, text: string, first: boolean, last: boolean) {
    this.id=id; this.message=message; this.text=text; this.first=first; this.last=last;
  }
}

/** Keep Markdown constructs intact while giving the outer List semantic rows. */
export function manuscriptParts(text: string): string[] {
  if (!text) return [''];
  // Footnotes and reference links bind distant blocks. Preserve their document
  // scope until the renderer supplies a shared AST rather than breaking links.
  if (/^ {0,3}\[[^\]]+\]:/m.test(text) || /\[\^[^\]]+\]/.test(text) || /\[[ xX]\]/.test(text)) return [text];
  const lines = text.split('\n');
  const blocks: string[] = [];
  let current = '';
  let fence = '';
  let math = false;
  let details = 0;
  for (const line of lines) {
    const start = line.match(/^ {0,3}(`{3,}|~{3,})/);
    if (start) {
      const mark = start[1];
      if (!fence) fence = mark;
      else if (mark[0] === fence[0] && mark.length >= fence.length && line.trim() === mark) fence = '';
    }
    if (!fence) {
      const delimiters=line.match(/\$\$/g);
      if(delimiters && delimiters.length%2===1) math=!math;
    }
    if (!fence) {
      if (/<details(?:\s|>)/i.test(line)) details++;
      if (/<\/details>/i.test(line)) details = Math.max(0,details-1);
    }
    current += (current.length ? '\n' : '') + line;
    if (!line.trim() && !fence && !math && details === 0 && current.trim()) {
      blocks.push(current); current = '';
    }
  }
  if (current.length > 0) blocks.push(current);
  const chunks: string[] = [];
  let carry = '';
  let carryNative=true;
  for (const block of blocks) {
    const native=canRenderNatively(block);
    if (carry.length > 0 && (carry.length + block.length > 1200 || native!==carryNative)) { chunks.push(carry); carry = ''; }
    carryNative=native;
    if (block.length > 1800 && !/[`#*_\[\]|$<>\\]/.test(block)) {
      if (carry) { chunks.push(carry); carry=''; }
      let start = 0;
      while (start < block.length) {
        let end = Math.min(start+1200,block.length);
        if (end < block.length) {
          const sentence = Math.max(block.lastIndexOf('。',end),block.lastIndexOf('！',end),block.lastIndexOf('\n',end));
          if (sentence > start+500) end=sentence+1;
          const code=block.charCodeAt(end-1);
          if (code>=0xD800 && code<=0xDBFF) end--;
        }
        chunks.push(block.substring(start,end)); start=end;
      }
    } else carry += (carry.length ? '\n' : '') + block;
  }
  if (carry) chunks.push(carry);
  return chunks.length > 0 ? chunks : [text];
}
