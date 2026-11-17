import * as pdfjs from "pdfjs-dist";
import workerUrl from "pdfjs-dist/build/pdf.worker.min.mjs?url";
pdfjs.GlobalWorkerOptions.workerSrc = workerUrl;

export async function renderPdf(source: Blob | string, container: HTMLElement) {
  container.className = "pdf-reader";
  container.innerHTML =
    '<div class="pdf-controls"><button data-prev aria-label="上一页" disabled>上一页</button><label><input data-page type="number" min="1" value="1" aria-label="页码" disabled> / <span data-total>…</span></label><button data-next aria-label="下一页" disabled>下一页</button><button data-soft>柔光</button><div class="pdf-zoom"><button data-zoom-out aria-label="缩小文档" disabled>−</button><span data-zoom-level>100%</span><button data-zoom-in aria-label="放大文档" disabled>＋</button></div></div><div class="pdf-paper"><canvas></canvas></div><p class="pdf-status" role="status">正在展开纸页…</p>';
  const status = container.querySelector<HTMLElement>(".pdf-status")!,
    canvas = container.querySelector("canvas")!,
    previous = container.querySelector<HTMLButtonElement>("[data-prev]")!,
    next = container.querySelector<HTMLButtonElement>("[data-next]")!,
    input = container.querySelector<HTMLInputElement>("[data-page]")!,
    zoomOut = container.querySelector<HTMLButtonElement>("[data-zoom-out]")!,
    zoomIn = container.querySelector<HTMLButtonElement>("[data-zoom-in]")!,
    zoomLevel = container.querySelector<HTMLElement>("[data-zoom-level]")!,
    paper = container.querySelector<HTMLElement>(".pdf-paper")!;
  let close = () => {};
  let pageNumber = 1,
    rendering = false, zoom = 1;
  try {
    const task = pdfjs.getDocument({
      ...(typeof source === "string"
        // Embedded documents can have about:/blob: locations; use their real base.
        ? {url: new URL(source, container.ownerDocument.baseURI).href, withCredentials: true, disableAutoFetch: true, disableStream: true, rangeChunkSize: 262144}
        : {data: new Uint8Array(await source.arrayBuffer())}),
      useSystemFonts: true,
    });
    // Closing during initial loading must also release the library-owned worker.
    close = () => { void task.destroy().catch(() => {}); };
    container.closest("dialog")?.addEventListener("close", close, { once: true });
    const document = await task.promise;
    container.querySelector("[data-total]")!.textContent = String(
      document.numPages,
    );
    input.max = String(document.numPages);
    async function draw(reset = true, previousZoom = zoom) {
      if (rendering || !container.isConnected) return;
      rendering = true;
      previous.disabled = true;
      next.disabled = true;
      input.disabled = true;
      zoomOut.disabled = true;
      zoomIn.disabled = true;
      const left = paper.scrollLeft, top = paper.scrollTop;
      status.textContent = "正在展开纸页…";
      try {
        const page = await document.getPage(pageNumber),
          base = page.getViewport({ scale: 1 });
        const available = Math.max(280, container.clientWidth);
        const viewport = page.getViewport({
          scale: Math.min(
            2.5,
            (available / base.width) * zoom * Math.min(devicePixelRatio, 2),
          ),
        });
        canvas.width = Math.ceil(viewport.width);
        canvas.height = Math.ceil(viewport.height);
        canvas.style.width = `${zoom * 100}%`;
        paper.scrollLeft = reset ? 0 : Math.max(0, (left + paper.clientWidth / 2) * zoom / previousZoom - paper.clientWidth / 2);
        paper.scrollTop = reset ? 0 : Math.max(0, (top + paper.clientHeight / 2) * zoom / previousZoom - paper.clientHeight / 2);
        await page.render({ canvas, viewport }).promise;
        status.textContent = "";
        input.value = String(pageNumber);
        zoomLevel.textContent = `${zoom * 100}%`;
      } catch {
        status.textContent = "这一页没能展开，可以下载原稿继续看。";
      } finally {
        rendering = false;
        input.disabled = false;
        zoomOut.disabled = zoom <= 1;
        zoomIn.disabled = zoom >= 3;
        previous.disabled = pageNumber <= 1;
        next.disabled = pageNumber >= document.numPages;
      }
    }
    previous.onclick = () => {
      if (pageNumber > 1) {
        pageNumber--;
        void draw();
      }
    };
    next.onclick = () => {
      if (pageNumber < document.numPages) {
        pageNumber++;
        void draw();
      }
    };
    input.onchange = () => {
      const n = Math.floor(Number(input.value));
      if (Number.isFinite(n)) {
        pageNumber = Math.max(1, Math.min(document.numPages, n));
        void draw();
      }
    };
    zoomOut.onclick = () => {
      if (zoom > 1 && !rendering) { const previous = zoom; zoom -= 0.5; void draw(false, previous); }
    };
    zoomIn.onclick = () => {
      if (zoom < 3 && !rendering) { const previous = zoom; zoom += 0.5; void draw(false, previous); }
    };
    container.querySelector<HTMLButtonElement>("[data-soft]")!.onclick = () =>
      container.classList.toggle("soft-light");
    await draw();
  } catch {
    close();
    status.textContent = "这份 PDF 暂时没能展开。原稿仍可下载。";
  }
}
