import { request } from "./api";
import "./export-preview.css";

type Cell = {
  value: string | number | boolean | null;
  kind: string;
  truncated: boolean;
  bold: boolean;
  color: string | null;
  background: string | null;
  align: string | null;
  number_format: string;
};
type SheetPage = {
  supported: boolean;
  reason?: string;
  sheet_names: string[];
  sheet: number;
  name: string;
  columns: number;
  total_columns: number;
  header: Cell[];
  rows: Cell[][];
  row_offset: number;
  data_rows: number;
  complete: boolean;
};
type Archive = { kind: string; entries: { name: string; size: number; directory: boolean }[]; expanded_size: number };

function sizeLabel(size: number) {
  return size < 1024 ? `${size} B` : size < 1024 ** 2 ? `${(size / 1024).toFixed(1)} KB` : `${(size / 1024 ** 2).toFixed(1)} MB`;
}
function columnName(index: number): string {
  let name = "";
  for (let number = index + 1; number; number = Math.floor((number - 1) / 26))
    name = String.fromCharCode(65 + (number - 1) % 26) + name;
  return name;
}
function renderCell(cell: Cell, heading = false) {
  const element = document.createElement(heading ? "th" : "td");
  let value = cell.value === null ? "" : String(cell.value);
  if (typeof cell.value === "number" && cell.number_format === "#,##0") value = cell.value.toLocaleString("zh-CN", { maximumFractionDigits: 0 });
  element.textContent = value;
  element.style.fontWeight = cell.bold ? "600" : "400";
  if (cell.color && /^#[\da-f]{6}$/i.test(cell.color)) element.style.color = cell.color;
  if (cell.background && /^#[\da-f]{6}$/i.test(cell.background)) element.style.backgroundColor = cell.background;
  if (["left", "center", "right"].includes(cell.align || "")) element.style.textAlign = cell.align!;
  if (cell.truncated) {
    const note = document.createElement("small");
    note.className = "cell-truncated";
    note.textContent = "本格仅展开前 2,000 字；完整内容在原件中。";
    element.append(note);
  }
  return element;
}

export async function renderWorkbook(id: string, container: HTMLElement, signal: AbortSignal) {
  container.classList.add("workbook-preview");
  container.innerHTML = '<div class="sheet-toolbar"><label>工作表<select aria-label="工作表"></select></label><span class="sheet-count"></span></div><div class="sheet-scroll" tabindex="0" aria-label="工作表内容，可横向滚动"></div><div class="sheet-pagination"><button class="text-button" data-page="previous">上一页</button><span></span><button class="text-button" data-page="next">下一页</button></div><div class="export-status" role="status" aria-live="polite"></div>';
  const select = container.querySelector<HTMLSelectElement>("select")!;
  const count = container.querySelector<HTMLElement>(".sheet-count")!;
  const scroll = container.querySelector<HTMLElement>(".sheet-scroll")!;
  const previous = container.querySelector<HTMLButtonElement>('[data-page="previous"]')!;
  const next = container.querySelector<HTMLButtonElement>('[data-page="next"]')!;
  const range = container.querySelector<HTMLElement>(".sheet-pagination span")!;
  const status = container.querySelector<HTMLElement>(".export-status")!;
  let page: SheetPage | undefined, busy = false;

  function availability() {
    select.disabled = busy;
    previous.disabled = busy || !page || page.row_offset === 0;
    next.disabled = busy || !page || page.complete;
    container.setAttribute("aria-busy", String(busy));
  }
  async function load(sheet: number, offset: number) {
    if (busy || signal.aborted) return;
    busy = true; availability();
    status.textContent = "正在翻开工作表…";
    try {
      const response = await request(`/artifacts/${id}/sheet?sheet=${sheet}&offset=${offset}&limit=20`, { signal });
      const result: SheetPage = await response.json();
      if (signal.aborted || !container.isConnected) return;
      if (!result.supported) throw new Error(result.reason || "这份工作簿暂时没能展开，原件仍可保存。");
      if (!page) {
        select.replaceChildren(...result.sheet_names.map((name, index) => new Option(name, String(index))));
      }
      page = result;
      select.value = String(page.sheet);
      count.textContent = `${page.sheet_names.length} 张表 · ${page.data_rows.toLocaleString("zh-CN")} 行资料 · ${page.total_columns} 列`;
      const table = document.createElement("table");
      table.className = "sheet-table";
      table.setAttribute("aria-label", page.name);
      const head = table.createTHead().insertRow();
      const corner = document.createElement("th");
      corner.className = "sheet-row-number"; corner.textContent = "1"; corner.scope = "row";
      head.append(corner);
      page.header.forEach((cell, index) => {
        const element = renderCell(cell, true) as HTMLTableCellElement;
        element.scope = "col";
        const letter = document.createElement("small");
        letter.className = "sheet-column-name"; letter.textContent = columnName(index);
        element.prepend(letter); head.append(element);
      });
      const body = table.createTBody();
      page.rows.forEach((row, index) => {
        const tr = body.insertRow();
        const number = document.createElement("th");
        number.className = "sheet-row-number"; number.scope = "row";
        number.textContent = String(page!.row_offset + index + 2); tr.append(number);
        row.forEach((cell) => tr.append(renderCell(cell)));
      });
      scroll.replaceChildren(table); scroll.scrollTo(0, 0);
      range.textContent = page.data_rows ? `第 ${page.row_offset + 1}–${page.row_offset + page.rows.length} 行 / 共 ${page.data_rows} 行资料` : "这张表只有表头";
      status.textContent = page.total_columns > page.columns ? `当前展开前 ${page.columns} 列，全部列可在原件中阅读。`
        : table.scrollWidth > scroll.clientWidth ? "左右滑动可读全部列，表头与首列会留在原处。" : "";
    } catch (error) {
      if (!signal.aborted && container.isConnected) {
        select.value = String(page?.sheet || 0);
        status.textContent = error instanceof Error ? error.message : "这一页还没有展开。";
        const retry = document.createElement("button"); retry.className = "text-button"; retry.textContent = "再翻一次";
        retry.onclick = () => void load(sheet, offset); status.append(retry);
      }
    } finally { busy = false; availability(); }
  }
  select.onchange = () => void load(Number(select.value), 0);
  previous.onclick = () => page && void load(page.sheet, Math.max(0, page.row_offset - 20));
  next.onclick = () => page && void load(page.sheet, page.row_offset + 20);
  await load(0, 0);
}

export async function renderArchive(id: string, container: HTMLElement, signal: AbortSignal) {
  container.classList.add("archive-preview");
  container.textContent = "正在展开原件目录…";
  const result: Archive = await (await request(`/artifacts/${id}/inspect`, { signal })).json();
  if (signal.aborted || !container.isConnected) return;
  if (result.kind !== "zip" || !Array.isArray(result.entries)) throw new Error("这份归档包暂时不能展开，原件仍可保存。");
  const summary = document.createElement("p"); summary.className = "archive-summary";
  summary.textContent = `${result.entries.length} 项原件 · 展开后 ${sizeLabel(result.expanded_size)}`;
  const list = document.createElement("ul"); list.className = "archive-entries";
  for (const entry of result.entries) {
    const row = document.createElement("li");
    const name = document.createElement("span"); name.textContent = entry.name;
    const size = document.createElement("small"); size.textContent = entry.directory ? "目录" : sizeLabel(entry.size);
    row.append(name, size); list.append(row);
  }
  container.replaceChildren(summary, list);
}
