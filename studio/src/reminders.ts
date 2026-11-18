import { api } from "./api";
import { escape } from "./render";

/** Her short answer, shown by the main view's toast. */
const say = (text: string) => window.dispatchEvent(new CustomEvent("haji-say", { detail: { text, kept: true } }));

interface Reminder {
  id: string;
  content: string;
  due_at: string;
  timezone: string;
  repeat: "once" | "daily" | "weekly";
  enabled: boolean;
  last_delivered_at?: string | null;
}
interface InboxItem {
  id: string;
  content?: string;
  message?: string;
  created_at?: string;
  read?: boolean;
  read_at?: string;
}
export async function mountReminders(element: HTMLElement) {
  element.className = "reminder-section";
  element.innerHTML =
    '<div class="reminder-heading"><div><span class="eyebrow">A PROMISE · 我们的约定</span><h2>到时，我会记得。</h2></div><button class="primary" data-add-reminder>写下约定</button></div><div data-reminder-list></div><div data-inbox></div>';
  const list = element.querySelector<HTMLElement>("[data-reminder-list]")!,
    inbox = element.querySelector<HTMLElement>("[data-inbox]")!;
  async function refresh() {
    try {
      const result = await api<{ reminders: Reminder[] }>("/reminders");
      if (!element.isConnected) return;
      list.innerHTML = result.reminders.length
        ? result.reminders
            .map(
              (r) =>
                `<article class="reminder-row"><div><p>${escape(r.content)}</p><small>${new Date(r.due_at).toLocaleString("zh-CN")} · ${r.repeat === "daily" ? "每天" : r.repeat === "weekly" ? "每周" : "这一次"}</small></div>${!r.enabled && r.repeat === "once" && r.last_delivered_at ? '<span class="reminder-delivered">已送达</span>' : `<button class="text-button" data-toggle="${escape(r.id)}" data-enabled="${r.enabled}">${r.enabled ? "暂停" : "继续"}</button>`}</article>`,
            )
            .join("")
        : '<p class="reminder-empty">下一件想一起记住的事，写在这里。</p>';
      list.querySelectorAll<HTMLButtonElement>("[data-toggle]").forEach(
        (button) =>
          (button.onclick = async () => {
            try {
              await api(
                `/reminders/${button.dataset.toggle}`,
                { enabled: button.dataset.enabled !== "true" },
                "PATCH",
              );
              say(button.dataset.enabled === "true" ? "先放一放。想起来的时候，再叫醒它。" : "嗯，我继续替你记着。");
              await refresh();
            } catch {
              button.textContent = "尚未保存，重试";
            }
          }),
      );
      const received = await api<{ items: InboxItem[] }>("/inbox");
      if (!element.isConnected) return;
      const unread = received.items.filter(
        (item) => !item.read && !item.read_at,
      );
      inbox.innerHTML = unread.length
        ? `<h3>她留给你的话</h3>${unread.map((item) => `<article class="reminder-row"><p>${escape(item.content || item.message || "一项约定到时间了。")}</p><button class="text-button" data-read="${escape(item.id)}">收到了</button></article>`).join("")}`
        : "";
      inbox.querySelectorAll<HTMLButtonElement>("[data-read]").forEach(
        (button) =>
          (button.onclick = async () => {
            await api(`/inbox/${button.dataset.read}/read`, {});
            say("嗯，记得就好。");
            await refresh();
          }),
      );
    } catch {
      if (element.isConnected)
        list.innerHTML =
          '<p class="reminder-empty">约定暂时没有连上。<button class="text-button" data-retry>再试一次</button></p>';
      list
        .querySelector<HTMLButtonElement>("[data-retry]")
        ?.addEventListener("click", () => void refresh());
    }
  }
  element.querySelector<HTMLButtonElement>("[data-add-reminder]")!.onclick =
    () => {
      const dialog = document.createElement("dialog");
      dialog.className = "reminder-dialog";
      const date = new Date(Date.now() + 3600000),
        local = new Date(date.getTime() - date.getTimezoneOffset() * 60000)
          .toISOString()
          .slice(0, 16);
      dialog.innerHTML = `<button class="modal-close icon-button" data-close aria-label="关闭">×</button><h2>一件不想忘记的事</h2><form><label>约定<textarea name="content" rows="3" required maxlength="2000"></textarea></label><label>什么时候<input type="datetime-local" name="due" value="${local}" required></label><label>重复<select name="repeat"><option value="once">只这一次</option><option value="daily">每天这个时候</option><option value="weekly">每周这个时候</option></select></label><p class="field-note">${escape(Intl.DateTimeFormat().resolvedOptions().timeZone)} · 到时收进琴房信箱</p><button class="primary">记下约定</button><p class="form-error" role="alert"></p></form>`;
      document.body.append(dialog);
      dialog.showModal();
      dialog.querySelector<HTMLButtonElement>("[data-close]")!.onclick = () =>
        dialog.close();
      dialog.addEventListener("close", () => dialog.remove(), { once: true });
      dialog.querySelector("form")!.onsubmit = async (event) => {
        event.preventDefault();
        const data = new FormData(event.target as HTMLFormElement);
        try {
          await api("/reminders", {
            content: String(data.get("content")).trim(),
            due_at: new Date(String(data.get("due"))).toISOString(),
            timezone: Intl.DateTimeFormat().resolvedOptions().timeZone,
            repeat: data.get("repeat"),
          });
          dialog.close();
          const due = new Date(String(data.get("due")));
          say(`约好了。${due.getMonth() + 1}月${due.getDate()}日 ${String(due.getHours()).padStart(2, "0")}:${String(due.getMinutes()).padStart(2, "0")}，我会叫你。`);
          await refresh();
        } catch (error) {
          dialog.querySelector<HTMLElement>(".form-error")!.textContent =
            error instanceof Error ? error.message : "没有记下来，请再试一次。";
        }
      };
    };
  await refresh();
}
