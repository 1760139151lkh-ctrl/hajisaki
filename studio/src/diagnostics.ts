import { api } from "./api";

function panel(title: string) {
  const dialog = document.createElement("dialog");
  dialog.className = "diagnostic-dialog";
  const heading = document.createElement("h2");
  heading.textContent = title;
  const close = document.createElement("button");
  close.className = "modal-close icon-button";
  close.textContent = "×";
  close.setAttribute("aria-label", "关闭记录");
  const content = document.createElement("pre");
  content.className = "diagnostic-output";
  content.textContent = "正在取出这页记录…";
  dialog.append(close, heading, content);
  document.body.append(dialog);
  dialog.showModal();
  close.onclick = () => dialog.close();
  dialog.addEventListener("close", () => dialog.remove(), { once: true });
  return { dialog, content };
}

export async function openDiagnostic(id: string) {
  const { dialog, content } = panel("主机记录");
  try {
    const record = await api<{ raw_text: string }>(
      `/diagnostics/${encodeURIComponent(id)}`,
    );
    if (dialog.isConnected) content.textContent = record.raw_text;
  } catch {
    if (dialog.isConnected)
      content.textContent = "这页主机记录暂时没有取到，请稍后再来。";
  }
}

export async function openRawMessage(id: string) {
  const { dialog, content } = panel("原始手稿");
  try {
    const record = await api<{ message: { content: string } }>(
      `/messages/${encodeURIComponent(id)}/raw`,
    );
    if (dialog.isConnected) content.textContent = record.message.content;
  } catch {
    if (dialog.isConnected)
      content.textContent = "原始手稿暂时没有取到，请稍后再来。";
  }
}
