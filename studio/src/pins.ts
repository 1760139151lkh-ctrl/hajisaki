import { api, cached, save, cacheKey } from "./api";
import { escape } from "./render";
interface Pin {
  id: string;
  kind: string;
  target_id: string;
  content?: string;
  source?: { name?: string; content?: string };
}
export async function showPins(
  element: HTMLElement,
  conversationId: string,
  onMessage: (id: string) => void,
  onArtifact: (id: string) => void,
) {
  let pins: Pin[] = await cached(cacheKey(`pins:${conversationId}`), []);
  try {
    pins = (await api<{ pins: Pin[] }>(`/conversations/${conversationId}/pins`))
      .pins;
    await save(cacheKey(`pins:${conversationId}`), pins);
  } catch {}
  if (!element.isConnected) return;
  element.innerHTML = pins
    .map(
      (pin) =>
        `<span class="context-pin"><button data-open="${escape(pin.id)}">${escape(
          (
            pin.source?.name ||
            pin.source?.content ||
            pin.content ||
            "上下文锚点"
          )
            .replace(/[>*_`#]/g, "")
            .replace(/\s+/g, " ")
            .slice(0, 36),
        )}</button><button data-remove="${escape(pin.id)}" aria-label="移除锚点">×</button></span>`,
    )
    .join("");
  element.hidden = !pins.length;
  element.querySelectorAll<HTMLButtonElement>("[data-open]").forEach(
    (button) =>
      (button.onclick = () => {
        const pin = pins.find((p) => p.id === button.dataset.open)!;
        if (pin.kind === "message") onMessage(pin.target_id);
        if (pin.kind === "artifact") onArtifact(pin.target_id);
      }),
  );
  element.querySelectorAll<HTMLButtonElement>("[data-remove]").forEach(
    (button) =>
      (button.onclick = async () => {
        button.disabled = true;
        try {
          await api(`/pins/${button.dataset.remove}`, undefined, "DELETE");
          await showPins(element, conversationId, onMessage, onArtifact);
        } catch {
          button.disabled = false;
        }
      }),
  );
}
export async function addPin(
  conversationId: string,
  kind: "message" | "artifact",
  targetId: string,
) {
  await api(`/conversations/${conversationId}/pins`, {
    kind,
    target_id: targetId,
  });
}
