import { api, request, cached, save, cacheKey } from "./api";
import { escape } from "./render";
import type { Artifact } from "./types";
import "./speech-ui.css";

interface Span {
  char_start: number;
  char_end: number;
  text: string;
  probability: number;
}
interface SpeechJob {
  id: string;
  status: string;
  original_text: string;
  text: string;
  segments: { start: number; end: number; text: string }[];
  uncertain_spans: Span[];
  dictionary_suggestions?: {
    start: number;
    end: number;
    text: string;
    replacement: string;
    source: string;
  }[];
  progress: { segments: number; through_seconds: number };
  error?: string;
  message?: string;
}
interface Hotword {
  term: string;
  aliases: string[];
}
const time = (seconds: number) =>
  `${Math.floor(seconds / 60)
    .toString()
    .padStart(2, "0")}:${Math.floor(seconds % 60)
    .toString()
    .padStart(2, "0")}`;

export async function openSpeech(
  artifact: Artifact,
  onUse: (text: string) => Promise<void>,
) {
  const dialog = document.createElement("dialog");
  dialog.className = "speech-dialog";
  dialog.innerHTML = `<button class="modal-close icon-button" data-close aria-label="关闭原音手稿">×</button><span class="eyebrow">LISTENING · 原音手稿</span><h2>${escape(artifact.name)}</h2><audio controls></audio><div class="speech-controls"><button class="primary" data-transcribe>听写成文</button><button class="text-button" data-stop hidden>停止听写</button><button class="text-button" data-hotwords>个人热词</button><span data-progress></span></div><p class="form-error" role="alert"></p><label class="speech-label">可修改的手稿<textarea rows="7" aria-label="转写手稿"></textarea></label><details class="uncertainty" hidden><summary>听得不太确定的片段</summary><div></div></details><div class="dictionary-suggestions"></div><details class="speech-segments" hidden><summary>按时间回听</summary><div></div></details><footer><button class="text-button" data-clean>去掉口头停顿词</button><button class="primary" data-use>放回输入框</button></footer>`;
  document.body.append(dialog);
  dialog.showModal();
  const textarea = dialog.querySelector("textarea")!,
    error = dialog.querySelector<HTMLElement>(".form-error")!,
    progress = dialog.querySelector<HTMLElement>("[data-progress]")!,
    transcribe = dialog.querySelector<HTMLButtonElement>("[data-transcribe]")!,
    stop = dialog.querySelector<HTMLButtonElement>("[data-stop]")!;
  let job: SpeechJob | undefined,
    closed = false,
    userEdited = false,
    audioUrl = "",
    timer: number | undefined;
  const draftKey = cacheKey(`transcript-draft:${artifact.id}`),
    jobKey = cacheKey(`transcript-job:${artifact.id}`);
  textarea.value = await cached(draftKey, "");
  userEdited = !!textarea.value;
  textarea.oninput = () => {
    userEdited = true;
    void save(draftKey, textarea.value);
  };
  const persist = () => save(draftKey, textarea.value);
  function show(job: SpeechJob) {
    const ongoing = ["queued", "running"].includes(job.status);
    transcribe.disabled = ongoing;
    stop.hidden = !ongoing;
    progress.textContent =
      job.status === "queued"
        ? "等她落笔…"
        : job.status === "running"
          ? `已听到 ${time(job.progress?.through_seconds || 0)}`
          : job.status === "completed"
            ? ""
            : job.status === "cancelled"
              ? "已停在这里"
              : job.status === "failed"
                ? "这一段没能听完"
                : "上次听写中断了";
    if (job.status === "completed") {
      if (!userEdited) {
        textarea.value = job.text;
        void persist();
      }
      const detail = dialog.querySelector<HTMLDetailsElement>(".uncertainty")!;
      detail.hidden = !job.uncertain_spans?.length;
      if (job.uncertain_spans?.length) {
        const codepoints = Array.from(job.original_text);
        let cursor = 0,
          html = "";
        for (const span of job.uncertain_spans
          .filter(
            (span) =>
              Number.isInteger(span.char_start) &&
              Number.isInteger(span.char_end),
          )
          .sort((a, b) => a.char_start - b.char_start)) {
          const start = Math.max(cursor, span.char_start),
            end = Math.max(start, span.char_end);
          html +=
            escape(codepoints.slice(cursor, start).join("")) +
            `<mark>${escape(codepoints.slice(start, end).join(""))}</mark>`;
          cursor = end;
        }
        html += escape(codepoints.slice(cursor).join(""));
        detail.querySelector("div")!.innerHTML = html;
      }
      const suggestions = dialog.querySelector<HTMLElement>(
        ".dictionary-suggestions",
      )!;
      suggestions.innerHTML = (job.dictionary_suggestions || [])
        .filter((s) => s.source === "user_dictionary")
        .map(
          (s, i) =>
            `<button class="text-button" data-suggestion="${i}">${escape(s.text)} → ${escape(s.replacement)}<small>个人热词</small></button>`,
        )
        .join("");
      suggestions
        .querySelectorAll<HTMLButtonElement>("[data-suggestion]")
        .forEach(
          (button) =>
            (button.onclick = () => {
              const suggestion =
                job.dictionary_suggestions![Number(button.dataset.suggestion)];
              if (textarea.value.includes(suggestion.text)) {
                textarea.value = textarea.value.replace(
                  suggestion.text,
                  suggestion.replacement,
                );
                userEdited = true;
                void persist();
                button.disabled = true;
              }
            }),
        );
      const segments =
        dialog.querySelector<HTMLDetailsElement>(".speech-segments")!;
      segments.hidden = !job.segments?.length;
      segments.querySelector("div")!.innerHTML = (job.segments || [])
        .map(
          (segment) =>
            `<button data-seek="${segment.start}"><time>${time(segment.start)}</time><span>${escape(segment.text)}</span></button>`,
        )
        .join("");
      segments.querySelectorAll<HTMLButtonElement>("[data-seek]").forEach(
        (button) =>
          (button.onclick = () => {
            const audio = dialog.querySelector("audio")!;
            audio.currentTime = Number(button.dataset.seek);
            void audio.play().catch(() => {});
          }),
      );
    }
    if (job.status === "failed")
      error.textContent =
        job.message || "这一段没能听完。原音仍然留着，可以重新来。";
  }
  async function readJob(id: string) {
    if (closed) return;
    try {
      job = await api<SpeechJob>(`/speech/transcriptions/${id}`);
      if (closed) return;
      show(job);
      if (["queued", "running"].includes(job.status))
        timer = window.setTimeout(() => void readJob(id), 1200);
    } catch {
      if (!closed) {
        progress.textContent = "连接松了一下，手稿还在。";
        timer = window.setTimeout(() => void readJob(id), 2500);
      }
    }
  }
  transcribe.onclick = async () => {
    try {
      error.textContent = "";
      const status = await api<{ available: boolean; detail?: string }>(
        "/speech/status",
      );
      if (!status.available) {
        error.textContent =
          status.detail || "主机的听写模型还没有备好。原音可以先收着。";
        return;
      }
      job = await api<SpeechJob>("/speech/transcriptions", {
        artifact_id: artifact.id,
        cleanup: false,
      });
      await save(jobKey, job.id);
      show(job);
      void readJob(job.id);
    } catch (e) {
      error.textContent =
        e instanceof Error ? e.message : "这一段没有接稳，请再试一次。";
    }
  };
  stop.onclick = async () => {
    if (job) {
      job = await api<SpeechJob>(`/speech/transcriptions/${job.id}/stop`, {});
      show(job);
    }
  };
  dialog.querySelector<HTMLButtonElement>("[data-hotwords]")!.onclick = () =>
    void editHotwords();
  dialog.querySelector<HTMLButtonElement>("[data-clean]")!.onclick =
    async () => {
      const before = textarea.value;
      if (!before.trim()) return;
      try {
        const result = await api<{ text: string }>("/speech/clean", {
          text: before,
        });
        if (textarea.value === before) {
          textarea.value = result.text;
          userEdited = true;
          await persist();
        }
      } catch (e) {
        error.textContent =
          e instanceof Error ? e.message : "手稿还没有整理好。";
      }
    };
  dialog.querySelector<HTMLButtonElement>("[data-use]")!.onclick = async () => {
    if (!textarea.value.trim()) return;
    await onUse(textarea.value);
    dialog.close();
  };
  dialog.querySelector<HTMLButtonElement>("[data-close]")!.onclick = () =>
    dialog.close();
  dialog.addEventListener(
    "close",
    () => {
      closed = true;
      clearTimeout(timer);
      if (audioUrl) URL.revokeObjectURL(audioUrl);
      dialog.remove();
    },
    { once: true },
  );
  try {
    const response = await request(`/artifacts/${artifact.id}/content`);
    const blob = await response.blob();
    if (!closed) {
      audioUrl = URL.createObjectURL(blob);
      dialog.querySelector("audio")!.src = audioUrl;
    }
    const id = await cached<string | null>(jobKey, null);
    if (id) void readJob(id);
  } catch {
    error.textContent = "原音暂时没连上。稍后重新打开这一页。";
  }
}

export async function editHotwords() {
  const dialog = document.createElement("dialog");
  dialog.className = "hotwords-dialog";
  dialog.innerHTML =
    '<button class="modal-close icon-button" data-close aria-label="关闭热词">×</button><h2>把熟悉的名字告诉她</h2><form><label>每行一个词；别名用逗号隔开<textarea rows="8" aria-label="个人热词" placeholder="哈基祥, 哈基香\nAntigravity"></textarea></label><button class="primary">保存热词</button><p class="form-error" role="alert"></p></form>';
  document.body.append(dialog);
  dialog.showModal();
  const textarea = dialog.querySelector("textarea")!,
    error = dialog.querySelector<HTMLElement>(".form-error")!;
  dialog.querySelector<HTMLButtonElement>("[data-close]")!.onclick = () =>
    dialog.close();
  dialog.addEventListener("close", () => dialog.remove(), { once: true });
  try {
    const data = await api<{ hotwords: Hotword[] }>("/speech/hotwords");
    textarea.value = data.hotwords
      .map((word) => [word.term, ...word.aliases].join(", "))
      .join("\n");
  } catch {
    error.textContent = "热词暂时没有连上，请稍后再来。";
  }
  dialog.querySelector("form")!.onsubmit = async (event) => {
    event.preventDefault();
    try {
      const hotwords = textarea.value
        .split("\n")
        .map((line) =>
          line
            .split(/[,，]/)
            .map((part) => part.trim())
            .filter(Boolean),
        )
        .filter((parts) => parts.length)
        .map(([term, ...aliases]) => ({ term, aliases }));
      await api("/speech/hotwords", { hotwords }, "PUT");
      dialog.close();
    } catch (e) {
      error.textContent = e instanceof Error ? e.message : "热词还没有保存。";
    }
  };
}
