import { markdown, enhance } from "./render";
import "./artifact-document.css";

const MAX_BYTES = 1024 * 1024;
const CARD_POLICY = "default-src 'none'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; img-src data: blob:; media-src data: blob:; font-src data:; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'; worker-src 'none'";

export function documentPreview(name: string, mime: string, size: number) {
  return size <= MAX_BYTES && (mime.startsWith("text/") ||
    /\.(md|markdown|txt|csv|tsv|json|jsonl|html?|css|js|mjs|ts|tsx|jsx|py|ets|java|kt|go|rs|c|cpp|h|hpp|sql|ya?ml|toml|xml)$/i.test(name));
}

async function readDocument(url: string, signal: AbortSignal) {
  const response = await fetch(url, { signal, credentials: "same-origin", cache: "no-store" });
  if (!response.ok || !response.body) throw new Error("这一页还没取完整，请稍后再翻开。");
  const reader = response.body.getReader();
  const decoder = new TextDecoder();
  let text = "", bytes = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      bytes += value.byteLength;
      if (bytes > MAX_BYTES) {
        await reader.cancel();
        throw new Error("这份原件较长，请保存后完整阅读。");
      }
      text += decoder.decode(value, { stream: true });
    }
    return text + decoder.decode();
  } finally { reader.releaseLock(); }
}

export async function renderArtifactDocument(url: string, name: string, container: HTMLElement, signal: AbortSignal) {
  if (signal.aborted) return;
  container.textContent = "正在翻开这一页…";
  const text = await readDocument(url, signal);
  if (signal.aborted || !container.isConnected) return;
  container.replaceChildren();
  if (/\.html?$/i.test(name)) {
    const frame = document.createElement("iframe");
    frame.name = "hajisaki-card";
    frame.title = name;
    frame.className = "interactive-artifact";
    frame.sandbox.add("allow-scripts");
    frame.referrerPolicy = "no-referrer";
    frame.allow = "geolocation 'none'; camera 'none'; microphone 'none'; clipboard-read 'none'; clipboard-write 'none'; payment 'none'";
    const html = '<!doctype html><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">' +
      '<meta http-equiv="Content-Security-Policy" content="' + CARD_POLICY + '">' + text;
    const source = URL.createObjectURL(new Blob([html], { type: "text/html" }));
    signal.addEventListener("abort", () => { frame.remove(); URL.revokeObjectURL(source); }, { once: true });
    frame.src = source;
    container.append(frame);
  } else if (/\.(md|markdown)$/i.test(name)) {
    container.classList.add("reading-content");
    container.innerHTML = markdown(text);
    await enhance(container);
  } else {
    const manuscript = document.createElement("pre");
    manuscript.className = "artifact-text";
    manuscript.textContent = text;
    container.append(manuscript);
  }
}
