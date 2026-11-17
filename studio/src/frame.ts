import "./rich.css";
import "./frame.css";
import { markdown, enhance } from "./render";
type DocumentPayload = {
  text: string;
  theme?: string;
  taskStates?: Record<string, boolean>;
  editable?: boolean;
};
declare global {
  interface Window {
    loadDocument: (payload: DocumentPayload) => Promise<void>;
    HajiNative?: {
      height: (height: string) => void;
      task?: (index: string, checked: string) => void;
    };
  }
}
let version = 0;
window.loadDocument = async (payload) => {
  const current = ++version;
  document.documentElement.dataset.theme =
    payload.theme === "day" ? "day" : "night";
  const article = document.getElementById("document")!;
  article.innerHTML = markdown(payload.text, {
    taskStates: payload.editable ? payload.taskStates : undefined,
  });
  article
    .querySelectorAll<HTMLInputElement>("[data-task-index]:not(:disabled)")
    .forEach((input) => {
      input.onchange = () => {
        input.disabled = true;
        window.HajiNative?.task?.(
          String(input.dataset.taskIndex),
          String(input.checked),
        );
      };
    });
  await enhance(article);
  if (current === version) reportHeight();
};
function reportHeight() {
  const height = Math.ceil(document.documentElement.scrollHeight);
  window.HajiNative?.height(String(height));
  if (window.parent !== window)
    window.parent.postMessage(
      { type: "hajisaki-height", height },
      location.origin === "null" ? "*" : location.origin,
    );
}
new ResizeObserver(reportHeight).observe(document.body);
window.addEventListener("message", (event) => {
  if (
    event.source !== window.parent ||
    (event.origin !== location.origin && event.origin !== "null")
  )
    return;
  if (
    event.data?.type === "hajisaki-document" &&
    typeof event.data.text === "string"
  )
    void window.loadDocument(event.data);
});
document.addEventListener("click", (event) => {
  const link = (event.target as Element).closest("a");
  if (
    link &&
    !link.getAttribute("href")?.startsWith("#") &&
    !(link.hasAttribute("download") && link.href.startsWith("blob:"))
  )
    event.preventDefault();
});
reportHeight();
