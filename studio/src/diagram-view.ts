import { escape } from "./render";

export function diagramActions(element: HTMLElement, label = "图谱") {
  const svg = element.querySelector("svg");
  if (!svg || element.querySelector(".diagram-actions")) return;
  const controls = document.createElement("div");
  controls.className = "diagram-actions";
  controls.innerHTML =
    "<button data-expand>展开图谱</button><button data-save-svg>保存 SVG</button>";
  element.append(controls);
  function file() {
    const copy = svg!.cloneNode(true) as SVGSVGElement;
    copy.setAttribute("xmlns", "http://www.w3.org/2000/svg");
    copy.style.color = getComputedStyle(element).color;
    copy.style.backgroundColor =
      getComputedStyle(element).getPropertyValue("--surface").trim() ||
      "#0b1021";
    return new File(
      [new XMLSerializer().serializeToString(copy)],
      `${label}.svg`,
      { type: "image/svg+xml" },
    );
  }
  controls.querySelector<HTMLButtonElement>("[data-save-svg]")!.onclick =
    () => {
      const url = URL.createObjectURL(file()),
        link = document.createElement("a");
      link.href = url;
      link.download = `${label}.svg`;
      link.click();
      setTimeout(() => URL.revokeObjectURL(url), 10000);
    };
  controls.querySelector<HTMLButtonElement>("[data-expand]")!.onclick = () => {
    const dialog = document.createElement("dialog");
    dialog.className = "diagram-dialog";
    dialog.innerHTML = `<header><strong>${escape(label)}</strong><button data-close aria-label="关闭图谱">×</button></header><div class="diagram-viewport"><div class="diagram-sheet"></div></div><footer><button data-out aria-label="缩小">−</button><button data-reset>100%</button><button data-in aria-label="放大">＋</button><button data-share>分享图谱</button></footer>`;
    const sheet = dialog.querySelector<HTMLElement>(".diagram-sheet")!,
      viewport = dialog.querySelector<HTMLElement>(".diagram-viewport")!,
      clone = svg.cloneNode(true) as SVGSVGElement;
    sheet.append(clone);
    document.body.append(dialog);
    dialog.showModal();
    const bounds = svg.viewBox.baseVal;
    const ratio =
      bounds.width && bounds.height ? bounds.width / bounds.height : 2;
    sheet.style.width = `${Math.min(viewport.clientWidth * 0.85, viewport.clientHeight * 0.8 * ratio, 1000)}px`;
    clone.style.width = "100%";
    clone.style.maxWidth = "none";
    clone.style.height = "auto";
    let scale = 1,
      x = 0,
      y = 0,
      distance = 0;
    const pointers = new Map<number, { x: number; y: number }>();
    const paint = () => {
      sheet.style.transform = `translate(${x}px,${y}px) scale(${scale})`;
      dialog.querySelector("[data-reset]")!.textContent =
        `${Math.round(scale * 100)}%`;
    };
    const zoom = (factor: number) => {
      scale = Math.min(6, Math.max(0.25, scale * factor));
      paint();
    };
    viewport.onpointerdown = (e) => {
      viewport.setPointerCapture(e.pointerId);
      pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (pointers.size === 2) {
        const p = [...pointers.values()];
        distance = Math.hypot(p[1].x - p[0].x, p[1].y - p[0].y);
      }
    };
    viewport.onpointermove = (e) => {
      if (!pointers.has(e.pointerId)) return;
      const previous = pointers.get(e.pointerId)!;
      pointers.set(e.pointerId, { x: e.clientX, y: e.clientY });
      if (pointers.size === 2) {
        const p = [...pointers.values()],
          next = Math.hypot(p[1].x - p[0].x, p[1].y - p[0].y);
        if (distance > 0)
          scale = Math.min(6, Math.max(0.25, (scale * next) / distance));
        distance = next;
      } else {
        x += e.clientX - previous.x;
        y += e.clientY - previous.y;
      }
      paint();
    };
    const release = (e: PointerEvent) => {
      pointers.delete(e.pointerId);
      distance = 0;
    };
    viewport.onpointerup = release;
    viewport.onpointercancel = release;
    viewport.onwheel = (e) => {
      e.preventDefault();
      zoom(e.deltaY < 0 ? 1.1 : 1 / 1.1);
    };
    dialog.querySelector<HTMLButtonElement>("[data-in]")!.onclick = () =>
      zoom(1.2);
    dialog.querySelector<HTMLButtonElement>("[data-out]")!.onclick = () =>
      zoom(1 / 1.2);
    dialog.querySelector<HTMLButtonElement>("[data-reset]")!.onclick = () => {
      scale = 1;
      x = y = 0;
      paint();
    };
    dialog.querySelector<HTMLButtonElement>("[data-close]")!.onclick = () =>
      dialog.close();
    dialog.addEventListener("close", () => dialog.remove(), { once: true });
    const share = dialog.querySelector<HTMLButtonElement>("[data-share]")!;
    if (!navigator.canShare?.({ files: [file()] }))
      share.textContent = "保存图谱";
    share.onclick = async () => {
      const image = file();
      if (navigator.canShare?.({ files: [image] })) {
        try {
          await navigator.share({ files: [image], title: label });
        } catch {}
      } else
        (
          controls.querySelector("[data-save-svg]") as HTMLButtonElement
        ).click();
    };
  };
}
