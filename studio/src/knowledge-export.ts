import { toBlob, getFontEmbedCSS } from "html-to-image";
import { markdown, enhance, escape } from "./render";
import "./knowledge-export.css";

interface KnowledgeOptions {
  title: string;
  text: string;
  taskStates?: Record<string, boolean>;
}
interface ImagePage {
  file: File;
  url: string;
  width: number;
  height: number;
}

function blobDataUrl(blob: Blob) {
  return new Promise<string>((resolve, reject) => {
    const reader = new FileReader();
    reader.onload = () => resolve(String(reader.result));
    reader.onerror = () => reject(reader.error);
    reader.readAsDataURL(blob);
  });
}

/** A bounded raster page is a slice of the complete laid-out manuscript. */
function pageCuts(source: HTMLElement, maximum: number) {
  const top = source.getBoundingClientRect().top;
  const height = Math.ceil(source.scrollHeight);
  const boundaries = [
    ...source.querySelectorAll<HTMLElement>(
      ".journal-body > *, .journal-signature",
    ),
  ]
    .map((node) => Math.ceil(node.getBoundingClientRect().bottom - top))
    .filter((value) => value > 0 && value < height);
  const cuts = [0];
  while (height - cuts.at(-1)! > maximum) {
    const start = cuts.at(-1)!;
    const end = start + maximum;
    const candidates = boundaries.filter(
      (value) => value > start + maximum * 0.45 && value <= end,
    );
    // A block taller than a page is continued at the exact next pixel; nothing is omitted.
    cuts.push(candidates.at(-1) || end);
  }
  cuts.push(height);
  return cuts;
}

export async function openKnowledgeExport(
  options: KnowledgeOptions,
  onStore?: (file: File) => Promise<void>,
) {
  const dialog = document.createElement("dialog");
  dialog.className = "knowledge-dialog";
  dialog.innerHTML = `<button class="modal-close icon-button" data-close aria-label="关闭手账">×</button><span class="eyebrow">A PAGE TO KEEP · 知识手账</span><h2>${escape(options.title)}</h2><p class="knowledge-progress" role="status">正在把这一页排成手稿…</p><div class="knowledge-pages"></div>`;
  document.body.append(dialog);
  dialog.showModal();
  let closed = false;
  const pages: ImagePage[] = [];
  const progress = dialog.querySelector<HTMLElement>(".knowledge-progress")!;
  const list = dialog.querySelector<HTMLElement>(".knowledge-pages")!;
  // Keep capture roots at a local origin; offscreen coordinates belong only to
  // an uncaptured ancestor, so logical inset styles cannot shift the PNG away.
  const host = document.createElement("div");
  host.style.cssText = "position:fixed;left:-12000px;top:0;width:860px;pointer-events:none;";
  host.setAttribute("aria-hidden", "true");
  dialog.append(host);
  const source = document.createElement("section");
  source.className = "journal-export";
  source.dataset.export = "true";
  source.dataset.theme = "day";
  source.setAttribute("aria-hidden", "true");
  source.innerHTML = `<header class="journal-heading"><span>A page to keep</span><h1>${escape(options.title)}</h1><div class="journal-staff" aria-hidden="true">♮</div></header><article class="reading-content journal-body">${markdown(options.text, { taskStates: options.taskStates, readonlyTasks: true })}</article><footer class="journal-signature"><span>把这一页，留给以后的你。</span><strong>Sakiko</strong><b>祥</b></footer>`;
  source.style.position = "relative";
  source.style.left = "0";
  source.style.top = "0";
  host.append(source);
  dialog.querySelector<HTMLButtonElement>("[data-close]")!.onclick = () =>
    dialog.close();
  dialog.addEventListener(
    "close",
    () => {
      closed = true;
      pages.forEach((page) => URL.revokeObjectURL(page.url));
      host.remove();
      dialog.remove();
    },
    { once: true },
  );

  try {
    source.querySelectorAll<HTMLDetailsElement>("details").forEach((detail) => {
      detail.open = true;
    });
    await enhance(source);
    source
      .querySelectorAll(".diagram-actions, .code-label button")
      .forEach((node) => node.remove());
    source
      .querySelectorAll<HTMLElement>("[data-source]")
      .forEach((node) => node.removeAttribute("data-source"));
    for (const image of source.querySelectorAll<HTMLImageElement>("img")) {
      const response = await fetch(image.src);
      if (!response.ok)
        throw new Error("手稿中的一张图片暂时无法读取。原文仍然留着。");
      image.src = await blobDataUrl(await response.blob());
      await image.decode();
    }
    await document.fonts.ready;
    if (closed) return;
    const fontEmbedCSS = await getFontEmbedCSS(source, {
      preferredFontFormat: "woff2",
    });
    const width = Math.ceil(source.getBoundingClientRect().width);
    const cuts = pageCuts(source, 7600);
    const total = cuts.length - 1;
    for (let index = 0; index < total; index++) {
      if (closed) return;
      progress.textContent =
        total > 1
          ? `正在整理第 ${index + 1} / ${total} 张手稿…`
          : "正在收好字句与图谱…";
      const offset = cuts[index],
        height = cuts[index + 1] - offset;
      const sheet = document.createElement("div");
      sheet.style.cssText = `position:relative;left:0;top:0;width:${width}px;height:${height}px;overflow:hidden;background:#F6F7FB;`;
      const copy = source.cloneNode(true) as HTMLElement;
      copy.style.position = "absolute";
      copy.style.left = "0";
      copy.style.top = `${-offset}px`;
      copy.removeAttribute("aria-hidden");
      sheet.append(copy);
      host.append(sheet);
      let blob: Blob | null;
      try {
        blob = await toBlob(sheet, {
          width,
          height,
          pixelRatio: 2,
          backgroundColor: "#F6F7FB",
          fontEmbedCSS,
          preferredFontFormat: "woff2",
          cacheBust: false,
          style: { position: "relative", left: "0", top: "0" },
        });
      } finally {
        sheet.remove();
      }
      if (!blob) throw new Error("这张手稿还没能收好，请重新试一次。");
      if (closed) return;
      const base =
        options.title.replace(/[\\/:*?"<>|]/g, "-").slice(0, 90) ||
        "祥子的手稿";
      const file = new File(
        [blob],
        `${base}${total > 1 ? `-${index + 1}` : ""}.png`,
        { type: "image/png" },
      );
      const page = {
        file,
        url: URL.createObjectURL(blob),
        width: width * 2,
        height: height * 2,
      };
      pages.push(page);
      const figure = document.createElement("figure");
      figure.innerHTML = `<img src="${page.url}" alt="${escape(options.title)}${total > 1 ? `，第 ${index + 1} 张` : ""}"><figcaption>${total > 1 ? `<span>第 ${index + 1} / ${total} 张</span>` : ""}<a class="primary" href="${page.url}" download="${escape(file.name)}">保存长图</a>${onStore ? '<button class="text-button" data-store>留在琴房</button>' : ""}<button class="text-button" data-share>分享</button></figcaption>`;
      list.append(figure);
      const share = figure.querySelector<HTMLButtonElement>("[data-share]")!;
      share.hidden = !navigator.canShare?.({ files: [file] });
      share.onclick = async () => {
        try {
          await navigator.share({ files: [file], title: options.title });
        } catch {}
      };
      figure
        .querySelector<HTMLButtonElement>("[data-store]")
        ?.addEventListener("click", async (event) => {
          const button = event.currentTarget as HTMLButtonElement;
          button.disabled = true;
          try {
            await onStore!(file);
            button.textContent = "已留在琴房";
          } catch {
            button.disabled = false;
            button.textContent = "重新收好";
          }
        });
    }
    progress.textContent =
      total > 1 ? `这页较长，分成了 ${total} 张连续手稿。` : "";
    progress.hidden = total === 1;
  } catch (error) {
    if (!closed)
      progress.textContent =
        error instanceof Error && /[\u3400-\u9fff]/.test(error.message)
          ? error.message
          : "手稿暂时没能排好。原文还在，可以稍后再试。";
  } finally {
    host.remove();
  }
}
