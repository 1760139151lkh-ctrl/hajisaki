import { api } from "./api";
import { escape as esc } from "./render";
import "./reference-roots.css";

interface Root { id: string; name: string; path?: string; enabled: boolean; available: boolean }
interface RootPage { roots: Root[]; can_manage: boolean }

export async function showReferenceRoots() {
  const dialog = document.createElement("dialog");
  dialog.className = "reference-roots-dialog";
  dialog.innerHTML = `<button class="modal-close icon-button" aria-label="关闭代码目录">×</button>
    <h2>可引用的代码目录</h2><p class="reference-root-note">手机可以从这些目录选择文件，收成附件后再交给祥子。原文件保留。</p>
    <div class="reference-root-list"></div><form class="reference-root-form" hidden>
      <label>目录名称<input name="name" placeholder="例如：手机工程" maxlength="80" required></label>
      <label>电脑上的目录<input name="path" placeholder="例如：C:\\Projects\\HajiSaki" maxlength="2048" required spellcheck="false"></label>
      <button class="primary-button" type="submit">添加目录</button></form>
    <p class="reference-root-status" role="status" aria-live="polite"></p>`;
  document.body.append(dialog);
  let closed = false, version = 0;
  const list = dialog.querySelector<HTMLElement>(".reference-root-list")!;
  const form = dialog.querySelector<HTMLFormElement>("form")!;
  const status = dialog.querySelector<HTMLElement>(".reference-root-status")!;
  dialog.querySelector<HTMLButtonElement>(".modal-close")!.onclick = () => dialog.close();
  dialog.addEventListener("close", () => { closed = true; version++; dialog.remove(); }, { once: true });
  dialog.showModal();

  const load = async () => {
    const current = ++version;
    try {
      const page = await api<RootPage>("/references/roots");
      if (closed || current !== version) return;
      form.hidden = !page.can_manage;
      list.innerHTML = page.roots.length ? page.roots.map(root => `<article class="reference-root-entry">
        <div><strong>${esc(root.name)}</strong>${root.path ? `<code>${esc(root.path)}</code>` : ""}
        <small>${root.enabled ? root.available ? "已开放引用" : "目录暂未连接" : "已停用"}</small></div>
        ${page.can_manage ? `<button type="button" class="text-button" data-root="${esc(root.id)}">${root.enabled ? "停用" : "开放"}</button>` : ""}</article>`).join("")
        : `<p class="reference-root-note">还没有开放的代码目录。</p>`;
      if (!page.can_manage) status.textContent = "新增目录需要在电脑上使用主人钥匙。";
      list.querySelectorAll<HTMLButtonElement>("[data-root]").forEach(button => {
        const root = page.roots.find(item => item.id === button.dataset.root)!;
        button.onclick = async () => {
          button.disabled = true; status.textContent = "";
          try {
            await api(`/references/roots/${root.id}/update`, { enabled: !root.enabled });
            if (!closed) await load();
          } catch (error) {
            if (!closed) { status.textContent = error instanceof Error ? error.message : "这份目录暂时没能更新。"; button.disabled = false; }
          }
        };
      });
    } catch (error) {
      if (!closed && current === version) status.textContent = error instanceof Error ? error.message : "代码目录暂时没有取到。";
    }
  };
  form.onsubmit = async event => {
    event.preventDefault();
    const submit = form.querySelector<HTMLButtonElement>("button")!;
    const name = form.querySelector<HTMLInputElement>('[name="name"]')!;
    const path = form.querySelector<HTMLInputElement>('[name="path"]')!;
    submit.disabled = true; status.textContent = "";
    try {
      await api("/references/roots", { name: name.value.trim(), path: path.value.trim() });
      if (closed) return;
      name.value = ""; path.value = ""; await load();
    } catch (error) {
      if (!closed) status.textContent = error instanceof Error ? error.message : "这份目录暂时没能开放。";
    } finally { if (!closed) submit.disabled = false; }
  };
  await load();
}
