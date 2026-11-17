import '../../studio/src/rich.css';
import '../../studio/src/frame.css';
import { markdown, enhance } from '../../studio/src/render';
import DOMPurify from '../../studio/node_modules/dompurify';

// This local identifier is routed by the native client, never fetched by WebKit.
// Keep the shared renderer's normal URI policy for every other address.
DOMPurify.addHook('uponSanitizeAttribute', (_node, attribute) => {
  if (attribute.attrName === 'href' && /^hajisaki:\/\/artifact\/[0-9a-f]{32}(?:\?(?:page=[1-9]\d*|line=[1-9]\d*(?:&end=[1-9]\d*)?))?$/.test(attribute.attrValue)) {
    attribute.forceKeepAttr = true;
  }
});

declare global {
  interface Window {
    loadDocument: (payload: DocumentPayload) => void;
    clearDocument: () => void;
    webkit?: {messageHandlers: {haji: {postMessage: (value: unknown) => void}}};
  }
}
interface DocumentPayload {text: string; theme: string; fontSize?: number; incomplete?: boolean; renderID?: string; preserveViewport?: boolean}
let revision = 0, currentRenderID = '';
let pending: DocumentPayload | undefined, rendering = false;
const scrollSelector = '.table-scroll, .math-scroll, .math-punctuation, pre';
let readingDocument = false, stableViewportWidth = 0, scrollRestore = 0;
let restoringScroll = false;
const horizontalPositions = new Map<number, number[]>();
function rememberHorizontal(event: Event) {
  if (!readingDocument || restoringScroll || document.documentElement.clientWidth !== stableViewportWidth ||
      !(event.target instanceof HTMLElement) || !event.target.matches(scrollSelector)) return;
  const elements = [...document.querySelectorAll<HTMLElement>('#document ' + scrollSelector.split(', ').join(', #document '))];
  const values = horizontalPositions.get(stableViewportWidth) ?? elements.map(element => element.scrollLeft);
  const index = elements.indexOf(event.target);
  if (index >= 0) values[index] = event.target.scrollLeft;
  horizontalPositions.set(stableViewportWidth, values);
}
function restoreHorizontal() {
  if (!readingDocument) return;
  const current = ++scrollRestore, width = document.documentElement.clientWidth;
  restoringScroll = true;
  requestAnimationFrame(() => {
    if (current !== scrollRestore) return;
    const elements = [...document.getElementById('document')!.querySelectorAll<HTMLElement>(scrollSelector)];
    const values = horizontalPositions.get(width);
    if (values) elements.forEach((element, index) => { element.scrollLeft = values[index] ?? 0; });
    requestAnimationFrame(() => {
      if (current !== scrollRestore) return;
      if (!values) horizontalPositions.set(width, elements.map(element => element.scrollLeft));
      stableViewportWidth = width; restoringScroll = false;
    });
  });
}
document.addEventListener('scroll', rememberHorizontal, {capture: true, passive: true});
window.addEventListener('resize', restoreHorizontal);
function post(value: unknown) { window.webkit?.messageHandlers.haji.postMessage(value); }
function height() {
  const article = document.getElementById('document')!;
  post({kind: 'height', renderID: currentRenderID, width: document.documentElement.clientWidth,
    value: Math.max(24, Math.ceil(article.getBoundingClientRect().height))});
}
function nextInlineText(node: Node, block: Element): Text | undefined {
  let cursor: Node | null = node;
  while (cursor && cursor !== block && !cursor.nextSibling) cursor = cursor.parentNode;
  if (!cursor || cursor === block) return;
  cursor = cursor.nextSibling;
  while (cursor instanceof HTMLElement) {
    if (!['SPAN', 'STRONG', 'EM', 'A', 'SUP', 'SUB', 'DEL', 'SMALL', 'MARK'].includes(cursor.tagName)) return;
    cursor = cursor.firstChild;
  }
  return cursor instanceof Text ? cursor : undefined;
}
function keepMathPunctuation(article: HTMLElement) {
  for (const math of article.querySelectorAll<HTMLElement>('.katex')) {
    if (math.closest('.math-scroll, .katex-display, .mermaid-block, .echarts-block, .abc-block')) continue;
    const block = math.closest<HTMLElement>('p, li, td, th, h1, h2, h3, h4, h5, h6, blockquote');
    if (!block) continue;
    const following = nextInlineText(math, block);
    const punctuation = following?.data.match(/^[ \t]*[，。！？、；：,.!?;:%‰…）\]｝}〉》」』】〕〗〙〛”’]+/u)?.[0];
    if (!following || !punctuation) continue;
    const style = getComputedStyle(block);
    const available = block.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    const reserve = Array.from(punctuation).length * parseFloat(style.fontSize);
    if (available <= reserve) continue;
    let start: Element = math;
    if (math.getClientRects().length !== 1 || math.getBoundingClientRect().width + reserve > available) {
      const bases = math.querySelectorAll('.katex-html > .base');
      start = bases[bases.length - 1] ?? math;
    }
    const group = document.createElement('span');
    group.className = 'math-punctuation';
    if (start.getBoundingClientRect().width + reserve > available) group.classList.add('math-punctuation-scroll');
    const range = document.createRange();
    range.setStartBefore(start);
    range.setEnd(following, punctuation.length);
    // Range preserves the real punctuation text and any intervening emphasis.
    // A long formula keeps its earlier KaTeX bases available for line wrapping.
    group.append(range.extractContents());
    range.insertNode(group);
  }
}
function fitMathPunctuation(article: HTMLElement) {
  for (const group of article.querySelectorAll<HTMLElement>('.math-punctuation')) {
    const block = group.closest<HTMLElement>('p, li, td, th, h1, h2, h3, h4, h5, h6, blockquote');
    if (!block) continue;
    const style = getComputedStyle(block);
    const available = block.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
    const width = group.classList.contains('math-punctuation-scroll') ? group.scrollWidth : group.getBoundingClientRect().width;
    group.classList.toggle('math-punctuation-scroll', width > available + 1);
  }
}
async function drain() {
  if (rendering) return;
  rendering = true;
  try {
    while (pending) {
      const payload = pending;
      pending = undefined;
      const current = ++revision;
      currentRenderID = payload.renderID ?? '';
      readingDocument = payload.preserveViewport === true;
      document.documentElement.dataset.theme = payload.theme;
      const article = document.getElementById('document')!;
      const viewport = payload.preserveViewport ? {
        top: window.scrollY,
        horizontal: [...article.querySelectorAll<HTMLElement>(scrollSelector)].map(element => element.scrollLeft),
        details: [...article.querySelectorAll('details')].map(element => element.open)
      } : undefined;
      article.style.fontSize = `${Math.max(12, Math.min(44, payload.fontSize ?? 17))}px`;
      article.style.lineHeight = '1.75';
      const opening = payload.text.trimStart();
      if (payload.incomplete && opening.startsWith('$$')) {
        // Unfinished TeX stays a compact waiting line; KaTeX errors must not
        // expose transient source as if it were a completed formula.
        article.innerHTML = '<div class="math-scroll" aria-label="公式还在书写">…</div>';
      } else if (payload.incomplete && !opening.startsWith('```') && !opening.startsWith('~~~') && !opening.startsWith('<details')) {
        article.innerHTML = markdown(payload.text) + '<span aria-label="公式还在书写">…</span>';
      } else {
        article.innerHTML = markdown(payload.text);
        await enhance(article);
      }
      if (revision === current && !pending) {
        await document.fonts.ready;
        if (revision === current && !pending) {
          keepMathPunctuation(article);
          fitMathPunctuation(article);
          if (viewport) {
            article.querySelectorAll('details').forEach((element, index) => { element.open = viewport.details[index] ?? element.open; });
            article.querySelectorAll<HTMLElement>(scrollSelector).forEach((element, index) => { element.scrollLeft = viewport.horizontal[index] ?? 0; });
            window.scrollTo(0, viewport.top);
          }
          if (readingDocument) {
            const width = document.documentElement.clientWidth;
            horizontalPositions.set(width, [...article.querySelectorAll<HTMLElement>(scrollSelector)].map(element => element.scrollLeft));
            stableViewportWidth = width;
          }
          height();
        }
      }
    }
  } finally { rendering = false; }
}
window.loadDocument = payload => {
  pending = payload;
  void drain();
};
window.clearDocument = () => {
  ++revision;
  currentRenderID = '';
  pending = undefined;
  readingDocument = false; horizontalPositions.clear(); stableViewportWidth = 0; ++scrollRestore; restoringScroll = false;
  document.getElementById('document')!.replaceChildren();
  window.getSelection()?.removeAllRanges();
};
new ResizeObserver(() => {
  fitMathPunctuation(document.getElementById('document')!);
  height();
}).observe(document.getElementById('document')!);
document.addEventListener('selectionchange', () => {
  if (window.getSelection()?.toString()) post({kind: 'selection', renderID: currentRenderID});
});
document.addEventListener('click', event => {
  if (!event.isTrusted) return;
  const element = event.target as Element;
  const copy = element.closest('[data-copy-code]');
  if (copy) {
    event.preventDefault(); event.stopImmediatePropagation();
    post({kind: 'copy', renderID: currentRenderID, value: copy.closest('.code-block')?.querySelector('code')?.textContent ?? ''});
  }
  const anchor = element.closest('a');
  if (anchor) {
    event.preventDefault();
    const href = anchor.getAttribute('href') ?? '';
    if (href.startsWith('#')) {
      let identifier = href.slice(1);
      try { identifier = decodeURIComponent(identifier); } catch { }
      const destination = document.getElementById(identifier);
      if (destination) {
        const rect = destination.getBoundingClientRect();
        post({kind: 'anchor', renderID: currentRenderID, top: rect.top + window.scrollY, height: rect.height});
        if (!window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
          destination.animate([{backgroundColor: 'rgba(136,182,250,.22)'}, {backgroundColor: 'transparent'}], {duration: 1200});
        }
        return;
      }
    }
    post({kind: 'link', renderID: currentRenderID, value: href});
  }
}, true);
post({kind: 'ready'});
