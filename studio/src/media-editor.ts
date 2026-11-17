import { escape } from "./render";
import "./media-editor.css";
type Point = { x: number; y: number };
type Command =
  | { kind: "draw"; points: Point[]; color: string }
  | { kind: "number"; point: Point; number: number }
  | { kind: "mosaic"; a: Point; b: Point }
  | { kind: "rotate" }
  | { kind: "paper" }
  | { kind: "straighten"; points: Point[] };
type Tool = "draw" | "number" | "mosaic" | "straighten";

export async function openMediaEditor(
  blob: Blob,
  name: string,
  onSave: (file: File) => Promise<void>,
) {
  const bitmap = await createImageBitmap(blob);
  const dialog = document.createElement("dialog");
  dialog.className = "media-editor";
  dialog.innerHTML = `<header><div><span class="eyebrow">MEDIA STUDIO · 画廊工作室</span><h2>${escape(name)}</h2></div><button class="icon-button" data-close aria-label="关闭画板">×</button></header><div class="media-toolbar"><button data-tool="draw" class="selected">画笔</button><button data-tool="number">编号</button><button data-tool="mosaic">马赛克</button><button data-tool="straighten">四角拉直</button><span></span><button data-command="paper">纸白</button><button data-command="rotate">旋转</button><button data-undo>撤销</button></div><div class="media-canvas-wrap"><canvas aria-label="图像画板"></canvas></div><footer><p data-hint>在画面上圈出想问的地方。</p><button class="primary" data-save>收好这张图</button></footer>`;
  document.body.append(dialog);
  dialog.showModal();
  const canvas = dialog.querySelector("canvas")!,
    context = canvas.getContext("2d", { willReadFrequently: true })!;
  const hint = dialog.querySelector<HTMLElement>("[data-hint]")!,
    saveButton = dialog.querySelector<HTMLButtonElement>("[data-save]")!;
  let commands: Command[] = [],
    tool: Tool = "draw",
    points: Point[] = [],
    drag: Point[] | null = null,
    busy = false,
    closed = false;
  const color = "#c24864";
  function setBusy(value: boolean) {
    busy = value;
    saveButton.disabled = value;
    dialog
      .querySelectorAll<HTMLButtonElement>(".media-toolbar button")
      .forEach((b) => (b.disabled = value));
    canvas.style.cursor = value
      ? "progress"
      : tool === "draw"
        ? "crosshair"
        : "pointer";
  }
  function point(event: PointerEvent): Point {
    const r = canvas.getBoundingClientRect();
    return {
      x: Math.max(0, Math.min(1, (event.clientX - r.left) / r.width)),
      y: Math.max(0, Math.min(1, (event.clientY - r.top) / r.height)),
    };
  }
  function stroke(path: Point[], ink: string) {
    context.strokeStyle = ink;
    context.lineWidth = Math.max(
      2,
      Math.min(canvas.width, canvas.height) / 180,
    );
    context.lineCap = "round";
    context.lineJoin = "round";
    context.beginPath();
    path.forEach((p, i) =>
      i
        ? context.lineTo(p.x * canvas.width, p.y * canvas.height)
        : context.moveTo(p.x * canvas.width, p.y * canvas.height),
    );
    context.stroke();
  }
  function number(p: Point, n: number, ink = color) {
    const radius = Math.max(12, Math.min(canvas.width, canvas.height) / 32),
      x = p.x * canvas.width,
      y = p.y * canvas.height;
    context.fillStyle = ink;
    context.beginPath();
    context.arc(x, y, radius, 0, Math.PI * 2);
    context.fill();
    context.fillStyle = "#fff";
    context.font = `600 ${radius * 1.1}px sans-serif`;
    context.textAlign = "center";
    context.textBaseline = "middle";
    context.fillText(String(n), x, y + radius * 0.04);
  }
  function mosaic(a: Point, b: Point) {
    const x = Math.floor(Math.min(a.x, b.x) * canvas.width),
      y = Math.floor(Math.min(a.y, b.y) * canvas.height),
      w = Math.ceil(Math.abs(a.x - b.x) * canvas.width),
      h = Math.ceil(Math.abs(a.y - b.y) * canvas.height);
    if (!w || !h) return;
    const small = document.createElement("canvas");
    const block = Math.max(
      8,
      Math.round(Math.min(canvas.width, canvas.height) / 60),
    );
    small.width = Math.max(1, Math.ceil(w / block));
    small.height = Math.max(1, Math.ceil(h / block));
    small
      .getContext("2d")!
      .drawImage(canvas, x, y, w, h, 0, 0, small.width, small.height);
    context.imageSmoothingEnabled = false;
    context.drawImage(small, 0, 0, small.width, small.height, x, y, w, h);
    context.imageSmoothingEnabled = true;
  }
  async function straighten(corners: Point[]) {
    const pixels = context.getImageData(0, 0, canvas.width, canvas.height),
      worker = new Worker(new URL("./perspective-worker.ts", import.meta.url), {
        type: "module",
      });
    const result = await new Promise<{
      width: number;
      height: number;
      pixels: ArrayBuffer;
    }>((resolve, reject) => {
      worker.onmessage = (e) => {
        worker.terminate();
        e.data.error ? reject(new Error(e.data.error)) : resolve(e.data);
      };
      worker.onerror = (e) => {
        worker.terminate();
        reject(new Error(e.message));
      };
      worker.postMessage(
        {
          width: canvas.width,
          height: canvas.height,
          pixels: pixels.data.buffer,
          points: corners,
        },
        [pixels.data.buffer],
      );
    });
    canvas.width = result.width;
    canvas.height = result.height;
    context.putImageData(
      new ImageData(
        new Uint8ClampedArray(result.pixels),
        result.width,
        result.height,
      ),
      0,
      0,
    );
  }
  async function redraw() {
    if (closed) return;
    setBusy(true);
    canvas.width = bitmap.width;
    canvas.height = bitmap.height;
    context.drawImage(bitmap, 0, 0);
    try {
      for (const command of commands) {
        if (command.kind === "draw") stroke(command.points, command.color);
        if (command.kind === "number") number(command.point, command.number);
        if (command.kind === "mosaic") mosaic(command.a, command.b);
        if (command.kind === "rotate") {
          const copy = document.createElement("canvas");
          copy.width = canvas.width;
          copy.height = canvas.height;
          copy.getContext("2d")!.drawImage(canvas, 0, 0);
          canvas.width = copy.height;
          canvas.height = copy.width;
          context.translate(canvas.width, 0);
          context.rotate(Math.PI / 2);
          context.drawImage(copy, 0, 0);
          context.resetTransform();
        }
        if (command.kind === "paper") {
          const data = context.getImageData(0, 0, canvas.width, canvas.height);
          for (let i = 0; i < data.data.length; i += 4) {
            const luminance =
              0.2126 * data.data[i] +
              0.7152 * data.data[i + 1] +
              0.0722 * data.data[i + 2];
            const value = Math.max(
              0,
              Math.min(255, ((luminance - 25) * 255) / 200),
            );
            data.data[i] = data.data[i + 1] = data.data[i + 2] = value;
          }
          context.putImageData(data, 0, 0);
        }
        if (command.kind === "straighten") await straighten(command.points);
      }
      points.forEach((p, i) => number(p, i + 1, "#406aa9"));
    } catch {
      hint.textContent = "这一笔没有展开，撤销后可以重新来。";
    } finally {
      setBusy(false);
    }
  }
  function select(next: Tool) {
    tool = next;
    points = [];
    dialog
      .querySelectorAll<HTMLButtonElement>("[data-tool]")
      .forEach((b) => b.classList.toggle("selected", b.dataset.tool === tool));
    hint.textContent =
      tool === "draw"
        ? "在画面上圈出想问的地方。"
        : tool === "number"
          ? "点一下，留下一个编号。"
          : tool === "mosaic"
            ? "拖出需要遮住的区域。"
            : "依次点左上、右上、右下、左下四个角。";
    void redraw();
  }
  dialog
    .querySelectorAll<HTMLButtonElement>("[data-tool]")
    .forEach((b) => (b.onclick = () => select(b.dataset.tool as Tool)));
  dialog.querySelectorAll<HTMLButtonElement>("[data-command]").forEach(
    (b) =>
      (b.onclick = () => {
        points = [];
        commands.push({ kind: b.dataset.command as "paper" | "rotate" });
        void redraw();
      }),
  );
  dialog.querySelector<HTMLButtonElement>("[data-undo]")!.onclick = () => {
    if (points.length) points.pop();
    else commands.pop();
    void redraw();
  };
  canvas.onpointerdown = (event) => {
    if (busy) return;
    event.preventDefault();
    canvas.setPointerCapture(event.pointerId);
    const p = point(event);
    if (tool === "number") {
      commands.push({
        kind: "number",
        point: p,
        number: commands.filter((c) => c.kind === "number").length + 1,
      });
      void redraw();
      return;
    }
    if (tool === "straighten") {
      points.push(p);
      number(p, points.length, "#406aa9");
      if (points.length === 4) {
        const cross = points.map((a, i) => {
          const b = points[(i + 1) % 4],
            c = points[(i + 2) % 4];
          return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x);
        });
        if (
          cross.some((n) => Math.abs(n) < 0.001) ||
          !(cross.every((n) => n > 0) || cross.every((n) => n < 0))
        ) {
          points = [];
          hint.textContent = "四个角需要围成纸页，按左上起顺时针再点一次。";
          void redraw();
          return;
        }
        commands.push({ kind: "straighten", points: [...points] });
        points = [];
        hint.textContent = "纸页已经拉直，可以继续标注。";
        void redraw();
      }
      return;
    }
    drag = [p];
  };
  canvas.onpointermove = (event) => {
    if (!drag || busy) return;
    const p = point(event);
    if (tool === "draw") {
      const previous = drag.at(-1)!;
      drag.push(p);
      stroke([previous, p], color);
    } else if (drag.length === 1) drag.push(p);
    else drag[1] = p;
  };
  canvas.onpointerup = (event) => {
    if (!drag) return;
    const p = point(event);
    if (tool === "draw") {
      drag.push(p);
      commands.push({ kind: "draw", points: drag, color });
    } else commands.push({ kind: "mosaic", a: drag[0], b: p });
    drag = null;
    void redraw();
  };
  canvas.onpointercancel = () => {
    drag = null;
    void redraw();
  };
  dialog.querySelector<HTMLButtonElement>("[data-close]")!.onclick = () =>
    dialog.close();
  dialog.addEventListener(
    "close",
    () => {
      closed = true;
      bitmap.close();
      dialog.remove();
    },
    { once: true },
  );
  saveButton.onclick = async () => {
    setBusy(true);
    try {
      if (points.length) {
        points = [];
        await redraw();
      }
      const result = await new Promise<Blob>((resolve, reject) =>
        canvas.toBlob(
          (value) =>
            value ? resolve(value) : reject(new Error("Image export failed")),
          "image/png",
        ),
      );
      const file = new File(
        [result],
        `${name.replace(/\.[^.]+$/, "")}-标注.png`,
        { type: "image/png" },
      );
      await onSave(file);
      dialog.close();
    } catch {
      hint.textContent = "这张图还没收好，请再试一次。";
      setBusy(false);
    }
  };
  await redraw();
}

export async function openBlankCanvas(onSave: (file: File) => Promise<void>) {
  const canvas = document.createElement("canvas");
  canvas.width = 1276;
  canvas.height = 1600;
  const context = canvas.getContext("2d")!;
  context.fillStyle = "#F6F7FB";
  context.fillRect(0, 0, canvas.width, canvas.height);
  const blob = await new Promise<Blob>((resolve) =>
    canvas.toBlob((b) => resolve(b!), "image/png"),
  );
  await openMediaEditor(blob, "空白手稿.png", onSave);
}
