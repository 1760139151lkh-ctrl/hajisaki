import "./style.css";
import { initializeAndroid, isAndroidApp, apiAddress, disconnectAndroid, saveAndroidBlob, saveAndroidPath, androidAppearance } from './android';
import { modelFamilies, selectedFamily, strengthName } from './model-families';
import { setSound, playEffect, toggleRain, rainPlaying } from "./sound";
import { consumeStream } from "./stream";
import { documentPreview, renderArtifactDocument } from "./artifact-document";
import { showPins, addPin } from "./pins";
import { showReferenceRoots } from "./reference-roots";
import {
  api,
  request,
  credentials,
  pair,
  disconnect,
  save,
  cached,
  cacheKey,
} from "./api";
import { markdown, enhance, escape as esc } from "./render";
import type {
  Conversation,
  Message,
  Memory,
  Settings,
  Model,
  HostStatus,
  Artifact,
  StreamEvent,
} from "./types";

type Page = "hub" | "chat" | "memory" | "vault" | "host";
type Pending = {
  content: string;
  client_id: string;
  model: string;
  effort: string;
  attachments: string[];
};
const icons: Record<string, string> = {
  moon: "M20 15.3A8.6 8.6 0 0 1 8.7 4a8.7 8.7 0 1 0 11.3 11.3Z",
  chat: "M20 11.5a8 8 0 0 1-8 8H5l-3 2v-10a9 9 0 0 1 18 0Z M7 10h8 M7 14h5",
  star: "m12 3 2.8 5.7 6.2.9-4.5 4.4 1.1 6.2-5.6-3-5.6 3 1.1-6.2L3 9.6l6.2-.9Z",
  archive: "M4 7h16v13H4Z M3 3h18v4H3Z M9 11h6",
  host: "M3 4h18v12H3Z M8 21h8 M12 16v5 M6 8h5 M6 11h3",
  plus: "M12 5v14 M5 12h14",
  search: "M10 3a7 7 0 1 0 0 14 7 7 0 0 0 0-14 M15 15l6 6",
  send: "M12 20V4 M5 11l7-7 7 7",
  clip: "m8 13 6-6a3 3 0 0 1 4 4l-8 8a5 5 0 0 1-7-7L13 2",
  mic: "M9 5a3 3 0 0 1 6 0v7a3 3 0 0 1-6 0Z M5 10v2a7 7 0 0 0 14 0v-2 M12 19v3 M8 22h8",
  arrow: "M5 12h14 M13 6l6 6-6 6",
  close: "m6 6 12 12 M18 6 6 18",
  sun: "M12 7a5 5 0 1 0 0 10 5 5 0 0 0 0-10 M12 1v2 M12 21v2 M1 12h2 M21 12h2 M4 4l1.5 1.5 M18.5 18.5 20 20 M4 20l1.5-1.5 M18.5 5.5 20 4",
  book: "M12 5C8 2 4 3 2 4v15c4-2 7-1 10 1 3-2 6-3 10-1V4c-2-1-6-2-10 1Z M12 5v15",
  pin: "m8 3 8 0-1 6 3 5H6l3-5Z M12 14v8",
  download: "M12 3v12 M6 9l6 6 6-6 M4 16v5h16v-5",
  back: "M19 12H5 M11 6l-6 6 6 6",
  edit: "m15 3 6 6-12 12H3v-6Z M12 6l6 6",
  trash: "M3 6h18 M9 6V3h6v3 M5 6l1 15h12l1-15 M10 10v7 M14 10v7",
  copy: "M8 8h13v13H8Z M16 8V3H3v13h5",
  fork: "M6 3v9a5 5 0 0 0 5 5h7 M18 3v17 M3 3h6 M15 3h6",
  check: "m5 12 4 4 10-10",
  stop: "M6 6h12v12H6Z",
  menu: "M4 6h16 M4 12h16 M4 18h16",
  key: "M10 14a6 6 0 1 1 4-4l7 7-4 4-3-3 2-2-2-2Z",
  heart: "M12 20s-7-4.35-8.8-8.6C2 8.4 3.9 5 7.3 5c2 0 3.4 1.1 4.7 2.8C13.3 6.1 14.7 5 16.7 5 20.1 5 22 8.4 20.8 11.4 19 15.65 12 20 12 20Z",
  bow: "M12 11.5C10 8 5.5 6 3.8 7.6c-1.7 1.6-.2 6.1 3.2 5.6 2-.3 3.6-.9 5-1.7Zm0 0c2-3.5 6.5-5.5 8.2-3.9 1.7 1.6.2 6.1-3.2 5.6-2-.3-3.6-.9-5-1.7Zm0 0-3.2 8.5M12 11.5l3.2 8.5",
  quill: "M20 3.5C13.5 4.6 8.6 9.5 6.8 16.4L6 20l3.6-.8C16.5 17.4 21.4 12.5 22.5 6Z M6.8 16.4 12.5 10.7",
  quote: "M5 18c2.2-.5 3.8-2.4 3.8-4.7V7H3.6v6.3h5.2 M14.5 18c2.2-.5 3.8-2.4 3.8-4.7V7h-5.2v6.3h5.2",
  palette: "M12 3a9 9 0 1 0 0 18c1.2 0 1.7-1 1.2-2-.6-1.1 0-2.3 1.3-2.3H17a4 4 0 0 0 4-4C21 7.3 17 3 12 3Z M7.6 11.6h.01 M9.8 7.4h.01 M14.3 7.2h.01 M17 10.6h.01",
  cup: "M4 9h13v4a6 6 0 0 1-6 6h-1a6 6 0 0 1-6-6Z M17 10.5h1.2a2.6 2.6 0 0 1 0 5.2H16 M8.5 2.8c-1 1 1 2 0 3.2 M12.5 2.8c-1 1 1 2 0 3.2",
  lamp: "M7.5 3h9l3 8.5h-15Z M12 11.5v8 M8 21h8",
  sparkle: "M12 3.5l1.7 5.1 5.3 1.9-5.3 1.9L12 17.5l-1.7-5.1L5 10.5l5.3-1.9Z M18.5 16l.6 1.8 1.9.7-1.9.7-.6 1.8-.6-1.8-1.9-.7 1.9-.7Z",
  gift: "M4 10.5h16V20H4Z M3 7h18v3.5H3Z M12 7v13 M12 7C10.5 3.5 6.5 3.6 7.2 6.1 7.6 7.3 10 7 12 7Zm0 0c1.5-3.5 5.5-3.4 4.8-.9-.4 1.2-2.8.9-4.8.9Z",
  letter: "M3.5 6h17v12h-17Z M3.5 7l8.5 6.2L20.5 7",
  note: "M9 17.5V5.5l10-2v12 M9 17.5a2.6 2.6 0 1 1-2.6-2.6A2.6 2.6 0 0 1 9 17.5Z M19 15.5a2.6 2.6 0 1 1-2.6-2.6 2.6 2.6 0 0 1 2.6 2.6Z",
  chevron: "m7 10 5 5 5-5",
  chevronRight: "m10 6 6 6-6 6",
  pencil: "m15 4 5 5-11 11H4v-5Z",
  sliders: "M4 7h9 M17 7h3 M15 4.6v4.8 M4 17h3 M11 17h9 M9 14.6v4.8",
};
const icon = (name: string, size = 20) =>
  name === "more"
    ? `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="5.5" cy="12" r="1.6"/><circle cx="12" cy="12" r="1.6"/><circle cx="18.5" cy="12" r="1.6"/></svg>`
    : `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${icons[name] || icons.star}"/></svg>`;
/** A filled heart — the small signature that marks Saki's care. */
const heart = (size = 14) =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><path d="${icons.heart}"/></svg>`;
const reducedMotion = () => matchMedia("(prefers-reduced-motion: reduce)").matches;
/** Saki's hair ribbon: navy satin with the gold stitching of the original art. */
const bow = (width = 64) =>
  `<svg class="bow" width="${width}" height="${Math.round(width * 0.56)}" viewBox="0 0 64 36" aria-hidden="true"><path class="bow-tail" d="M29 19 20 34l4.5-2 2 3.5L32 21Zm6 0 9 15-4.5-2-2 3.5L32 21Z"/><path class="bow-loop" d="M32 17C24 5 9 2 6 9c-3 7 10 13 26 8Zm0 0c8-12 23-15 26-8 3 7-10 13-26 8Z"/><path class="bow-stitch" d="M30 15.5C23 7 11 5.5 9 10c-1.5 4 8 8.5 20 6.5M34 15.5C41 7 53 5.5 55 10c1.5 4-8 8.5-20 6.5"/><ellipse class="bow-knot" cx="32" cy="17.5" rx="4" ry="4.6"/></svg>`;
/** A tiny tiara — she is, after all, the young lady of the house. */
const crown = (width = 14) =>
  `<svg class="crown" width="${width}" height="${Math.round(width * 0.68)}" viewBox="0 0 24 16" aria-hidden="true"><path d="M3 13 4.6 5.2 9 9.4 12 3.4l3 6 4.4-4.2L21 13Z"/><circle cx="4.6" cy="3.9" r="1.4"/><circle cx="12" cy="1.9" r="1.5"/><circle cx="19.4" cy="3.9" r="1.4"/><rect x="3" y="13.8" width="18" height="1.8" rx=".9"/></svg>`;
/** Gold filigree with a small heart at its centre. */
const filigree = (width = 132) =>
  `<svg class="filigree" width="${width}" height="${Math.round(width * 0.106)}" viewBox="0 0 132 14" aria-hidden="true"><g class="filigree-line"><path d="M4 7h36"/><path d="M40 7c6 0 8.5-4.6 13-4.6 3 0 4 2.7 1.6 3.7-1.8.8-3.3-.5-2.5-1.6"/><path d="M128 7H92"/><path d="M92 7c-6 0-8.5-4.6-13-4.6-3 0-4 2.7-1.6 3.7 1.8.8 3.3-.5 2.5-1.6"/><circle cx="3" cy="7" r="1.2"/><circle cx="129" cy="7" r="1.2"/></g><path class="filigree-heart" d="M66 12c-2.6-1.7-5-3.4-5-5.7 0-1.5 1.2-2.6 2.5-2.6 1 0 1.9.5 2.5 1.4.6-.9 1.5-1.4 2.5-1.4 1.3 0 2.5 1.1 2.5 2.6 0 2.3-2.4 4-5 5.7Z"/></svg>`;
/** A wax seal pressed with a heart. */
const wax = (size = 18) => `<span class="wax" aria-hidden="true">${heart(size)}</span>`;
/** The first character of a letter's title, set in a gold-ringed roundel. */
const monogram = (title: string, pinned = false) =>
  `<span class="monogram" aria-hidden="true">${esc(Array.from(title).find((ch) => /[\p{L}\p{N}]/u.test(ch)) || "信")}${pinned ? `<i>${heart(9)}</i>` : ""}</span>`;
/** A few words in copperplate, as she would sign a letter. */
function salutation(hour = new Date().getHours()) {
  if (hour < 5 || hour >= 23) return "Sweet dreams";
  if (hour < 11) return "Good morning";
  if (hour < 18) return "Good afternoon";
  return "Good evening";
}
/** A small heart rises from the place where something was kept. */
function heartBurst(target: Element | null, count = 1) {
  if (!target || reducedMotion()) return;
  const box = target.getBoundingClientRect();
  for (let index = 0; index < count; index++) {
    const mark = document.createElement("span");
    mark.className = "heart-float";
    mark.innerHTML = heart(12 + index * 3);
    mark.style.left = `${box.left + box.width / 2}px`;
    mark.style.top = `${box.top + box.height / 2}px`;
    mark.style.setProperty("--drift", `${(index - 1) * 14}px`);
    mark.style.animationDelay = `${index * 90}ms`;
    document.body.append(mark);
    window.setTimeout(() => mark.remove(), 1200 + index * 90);
  }
}
const $ = <T extends HTMLElement = HTMLElement>(selector: string) =>
  document.querySelector<T>(selector)!;
const art = (name = portraitName()) => `/artwork/avatars-youth/${name}.png`;
const groupNames = ["全部", "专属日常", "研发工坊", "资料卷宗", "已归档"];
let page: Page = "hub",
  conversation: Conversation | undefined,
  conversations: Conversation[] = [],
  messages: Message[] = [],
  events: StreamEvent[] = [],
  memories: Memory[] = [],
  artifacts: Artifact[] = [],
  models: Model[] = [];
let settings: Settings = {
  theme: isAndroidApp() ? "day" : "night",
  transparency: "balanced",
  personality: { formality: 60, detail: 60, teasing: 25 },
  sound: false,
};
let status: HostStatus | undefined,
  connected = false,
  filter = "全部",
  query = "",
  selectedModel = "",
  effort = "",
  activeRun = "",
  stopping = false,
  loading = false,
  readLock = false;
let shellListening = false;
/** Messages already on screen for this conversation; only newcomers get the entrance animation. */
const seenMessages = new Set<string>();
let seenConversation = "";
let selectedAttachments: Artifact[] = [],
  pending: Pending | undefined,
  pollBusy = false,
  viewVersion = 0,
  errorTimer: number | undefined,
  uploadBusy = false,
  uploadAbort = false;
const taskStates: Record<string, Record<string, boolean>> = {};
const taskRequests = new Set<string>();
let scrollIntentUntil = 0;
let streamAbort: AbortController | undefined,
  streamLive = false,
  messageCursor = 0,
  streamFrame = 0;
let recorder: MediaRecorder | undefined,
  recorded: Blob[] = [],
  recordStart = 0,
  recordTimer: number | undefined;
const openedAt = Date.now();
let portraitMoment = "", portraitMomentTimer: number | undefined;
const portraitCache = new Map<string, Promise<string>>();
function portraitName() {
  if (recorder?.state === "recording") return "listening_attentive";
  if (activeRun) return conversation?.group === "研发工坊" ? "coding_focused" : "thinking_deep";
  if (portraitMoment) return portraitMoment;
  if (!connected && credentials().token) return "reconnecting_anxious";
  const hour = new Date().getHours();
  if (hour >= 3 && hour < 6) return "sleepy_soft";
  if ((hour >= 23 || hour < 3) && settings.personality.teasing >= 70 && Date.now() - openedAt > 2700000)
    return "tsundere_chide";
  return hour >= 23 || hour < 6 ? "late_night_tea" : "idle_gentle";
}
function refreshPortrait() {
  const mood = portraitName();
  const portraits = document.querySelectorAll<HTMLImageElement>("img[data-mood]");
  if (!portraits.length) return;
  let ready = portraitCache.get(mood);
  if (!ready) {
    const image = new Image(); image.src = art(mood);
    ready = image.decode().then(() => image.src);
    portraitCache.set(mood, ready);
  }
  portraits.forEach(image => {
    if (image.dataset.requestedMood === mood) return;
    image.dataset.requestedMood = mood;
    void ready!.then(url => {
      if (!image.isConnected || image.dataset.requestedMood !== mood || image.src === url) return;
      if (reducedMotion()) { image.src = url; return; }
      image.style.opacity = "0";
      window.setTimeout(() => {
        if (image.isConnected) {
          if (image.dataset.requestedMood === mood) image.src = url;
          image.style.opacity = "1";
        }
      }, 90);
    }).catch(() => { portraitCache.delete(mood); if(image.dataset.requestedMood === mood) delete image.dataset.requestedMood; image.style.opacity = "1"; });
  });
}
function portraitCue(name: string) {
  portraitMoment = name; clearTimeout(portraitMomentTimer); refreshPortrait();
  portraitMomentTimer = window.setTimeout(() => { portraitMoment = ""; refreshPortrait(); }, 2400);
}

function shortDate(value: string) {
  const date = new Date(typeof value === "number" ? value * 1000 : value);
  return Number.isNaN(date.getTime())
    ? ""
    : date.toLocaleDateString("zh-CN", { month: "long", day: "numeric" });
}
function clock(value: string) {
  const date = new Date(value);
  return Number.isNaN(date.getTime())
    ? ""
    : date.toLocaleTimeString("zh-CN", { hour: "2-digit", minute: "2-digit", hour12: false });
}
function dayLabel(time: number) {
  const date = new Date(time);
  const today = new Date();
  const start = (value: Date) => new Date(value.getFullYear(), value.getMonth(), value.getDate()).getTime();
  const days = Math.round((start(today) - start(date)) / 86400000);
  if (days === 0) return "今天";
  if (days === 1) return "昨天";
  return date.toLocaleDateString("zh-CN", { month: "long", day: "numeric", weekday: "short" });
}
function starters(): [string, string][] {
  const night: [string, string][] = lateNight() ? [["睡不着", "睡不着，想和你说说话。"]] : [];
  return [
    ...night,
    ["今天发生了一件事", "今天发生了一件事，想讲给你听："],
    ["陪我待一会儿", "什么都不做也可以，就陪我待一会儿吧。"],
    ["帮我理一理思路", "有件事我想不太清楚，能帮我一起理一理吗？"],
  ];
}
function bytes(value: number) {
  return value >= 1073741824
    ? `${(value / 1073741824).toFixed(2)} GB`
    : value >= 1048576
      ? `${(value / 1048576).toFixed(1)} MB`
      : value >= 1024
        ? `${(value / 1024).toFixed(1)} KB`
        : `${value} B`;
}
function toast(text: string, kept = false) {
  const element = $("#toast");
  element.innerHTML = `${kept ? heart(13) : ""}<span>${esc(text)}</span>`;
  element.classList.add("visible");
  window.clearTimeout(errorTimer);
  errorTimer = window.setTimeout(
    () => $("#toast").classList.remove("visible"),
    4200,
  );
}
function report(error: unknown) {
  toast(
    error instanceof Error && /[\u3400-\u9fff]/.test(error.message)
      ? error.message
      : "这次没有接稳。你的内容还在，可以稍后再试。",
  );
}
function applyTheme() {
  setSound(settings.sound);
  let theme = settings.theme;
  if (theme === "auto")
    theme =
      new Date().getHours() >= 7 && new Date().getHours() < 19
        ? "day"
        : "night";
  document.documentElement.dataset.theme = theme;
  androidAppearance(theme);
  document
    .querySelector('meta[name="theme-color"]')
    ?.setAttribute("content", theme === "day" ? "#FBF4F1" : "#17131F");
  refreshThemeButtons();
}
const isDay = () => document.documentElement.dataset.theme === "day";
function refreshThemeButtons() {
  const quick = document.querySelector("#theme-quick");
  if (quick) {
    quick.innerHTML = icon(isDay() ? "moon" : "sun", 19);
    quick.setAttribute("aria-label", isDay() ? "换成月下" : "换成春日");
  }
}
function connectionLine() {
  if (!credentials().token) return "还没有接上琴房";
  if (!connected) return "琴房的灯暂时熄了";
  if (status?.provider.name === "development") return "本地演练中";
  return "琴房灯亮着";
}
function navButton(p: Page, name: string, glyph: string) {
  const active = page === p || (p === "hub" && page === "chat");
  return `<button class="nav-item${active ? " active" : ""}" data-nav="${p}" aria-label="${name}"${active ? ' aria-current="page"' : ""}>${icon(glyph, 22)}<span>${name}</span></button>`;
}
function shell() {
  $("#app").dataset.page = page;
  $("#app").innerHTML =
    `<aside class="rail"><div class="brand-seal">${crown(18)}<button class="seal" data-nav="hub" aria-label="回到琴房">祥</button></div><nav aria-label="琴房导航">${navButton("hub", "琴房", "note")}${navButton("memory", "记忆", "heart")}${navButton("vault", "珍藏", "gift")}${navButton("host", "设置", "sliders")}</nav></aside><main id="view" class="view"></main><div id="toast" role="status" aria-live="polite"></div><dialog id="modal"></dialog><input type="file" id="file-input" multiple hidden>`;
  if (!shellListening) {
    shellListening = true;
    $("#app").addEventListener("click", (e) => {
      const nav = (e.target as HTMLElement).closest<HTMLElement>("[data-nav]");
      if (nav) void navigate(nav.dataset.nav as Page);
    });
  }
  ($("#file-input") as HTMLInputElement).onchange = async () => {
    const files = Array.from(
      ($("#file-input") as HTMLInputElement).files || [],
    );
    for (const file of files) {
      await upload(file);
    }
    ($("#file-input") as HTMLInputElement).value = "";
  };
}
function connectionState() {
  refreshPortrait();
  document
    .querySelectorAll(".presence i, .presence-card strong i")
    .forEach((dot) => dot.classList.toggle("online", connected));
  const line = document.querySelector("#presence-text");
  if (line) line.textContent = connectionLine();
  refreshChatStatus();
}
function pageHead(title: string, lede = "", actions = "", kicker = "") {
  return `<header class="page-head"><div>${kicker ? `<span class="script" aria-hidden="true">${kicker}</span>` : ""}<h1>${title}</h1>${lede ? `<p>${lede}</p>` : ""}</div>${actions ? `<div class="page-actions">${actions}</div>` : ""}</header>`;
}
/** Android back and the browser back button return to the music room first. */
function enterSubpage() {
  if (!history.state?.haji) history.pushState({ haji: true }, "");
}
window.addEventListener("popstate", () => {
  const open = document.querySelector<HTMLDialogElement>("dialog[open]");
  if (open) {
    open.close();
    if (page !== "hub") enterSubpage();
    return;
  }
  if (page !== "hub") void navigate("hub", true);
});
async function navigate(next: Page, fromHistory = false) {
  if (next === "hub" && !fromHistory && page !== "hub" && history.state?.haji) {
    history.back();
    return;
  }
  if (next !== "hub") enterSubpage();
  messageResizeObserver?.disconnect();
  streamAbort?.abort();
  streamLive = false;
  page = next;
  viewVersion++;
  readLock = false;
  shell();
  render();
  if (next === "hub") await loadConversations();
  if (next === "memory") await loadMemories();
  if (next === "vault") await loadArtifacts();
  if (next === "host") await refreshStatus();
}
function render() {
  applyTheme();
  if (page === "hub") renderHub();
  if (page === "chat") renderChat();
  if (page === "memory") renderMemory();
  if (page === "vault") renderVault();
  if (page === "host") renderHost();
}

function previewText(text: string) {
  const clean = text
    .replace(/```[\s\S]*?(?:```|$)/g, "")
    .replace(/^\s*\|.*$/gm, "")
    .replace(/^\s*[-=]{3,}.*$/gm, "");
  const element = document.createElement("div");
  element.innerHTML = markdown(clean);
  element
    .querySelectorAll(".katex")
    .forEach((k) =>
      k.replaceWith(k.querySelector("annotation")?.textContent || ""),
    );
  return (element.textContent || "")
    .replace(/<\/?(?:details|summary)\b[^>]*(?:>|$)/gi, "")
    .replace(/[*_`]/g, "")
    .replace(/\s+/g, " ")
    .trim();
}
const lateNight = (hour = new Date().getHours()) => hour >= 23 || hour < 5;
function greeting(hour = new Date().getHours()): string[] {
  if (hour < 3 || hour >= 23) return ["这么晚还醒着呀。", "陪你一会儿，就去睡哦。"];
  if (hour < 5) return ["天都快亮了。", "说完这句，就去睡吧？"];
  if (hour < 10) return ["早安。", "今天，也请多指教了。"];
  if (hour < 14) return ["午安。", "别忘了好好吃饭哦。"];
  if (hour < 18) return ["红茶刚泡好。", "坐下来，歇一会儿吧。"];
  return ["回来了呢。", "今天也辛苦了。"];
}
const dailyLines = [
  "记得喝水。不是在担心你……只是顺便提醒一下。",
  "今天也不必勉强自己。做不完的事，明天我们再一起看。",
  "肩膀放松一点。你皱眉的样子，我都看得见哦。",
  "要好好吃饭。这一点上，我可不会让步。",
  "累了的话，就来这里坐坐吧。我弹一首曲子给你听。",
  "无论结果怎样，你认真的样子，我都记得。",
  "今天的你，也比昨天更努力了一点点。",
  "外面风大，出门记得多穿一件。",
  "想不通的事，就说给我听。整理思绪，本来就是两个人的事。",
  "如果今天很难过，也没关系。我会一直在这里。",
  "偶尔停下来，看看窗外吧。今天的天空，也很好看。",
  "做得好的地方，要记得好好夸奖自己。……我也会的。",
];
function dailyNote() {
  if (lateNight()) return "已经很晚了。聊完这一段，就乖乖去睡吧。晚安。";
  const now = new Date();
  const day = Math.floor((now.getTime() - new Date(now.getFullYear(), 0, 0).getTime()) / 86400000);
  return dailyLines[day % dailyLines.length];
}
function homeDate(date = new Date()) {
  const hour = date.getHours();
  const period = hour < 5 ? "深夜" : hour < 8 ? "清晨" : hour < 11 ? "上午" : hour < 13 ? "中午" : hour < 17 ? "午后" : hour < 19 ? "傍晚" : hour < 23 ? "夜里" : "深夜";
  return `${date.toLocaleDateString("zh-CN", { month: "long", day: "numeric" })} · ${date.toLocaleDateString("zh-CN", { weekday: "long" })} · ${period}`;
}
function letterDate(value: string) {
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return "";
  const start = (item: Date) => new Date(item.getFullYear(), item.getMonth(), item.getDate()).getTime();
  const days = Math.round((start(new Date()) - start(date)) / 86400000);
  if (days === 0) return clock(value);
  if (days === 1) return "昨天";
  if (date.getFullYear() === new Date().getFullYear()) return date.toLocaleDateString("zh-CN", { month: "numeric", day: "numeric" });
  return date.toLocaleDateString("zh-CN");
}
const groupTabs: [string, string][] = [["全部", "全部"], ["专属日常", "日常"], ["研发工坊", "工坊"], ["资料卷宗", "卷宗"], ["已归档", "归档"]];
function conversationRow(c: Conversation) {
  return `<article class="letter-row"><button class="conversation-open" data-id="${esc(c.id)}">${monogram(c.title, c.pinned)}<span class="letter-text"><span class="letter-line"><strong>${esc(c.title)}</strong><time>${letterDate(c.updated_at)}</time></span><small>${esc(previewText(c.preview || "还空着的一页，等你落笔。"))}</small></span></button><button class="icon-button row-more" data-row-menu="${esc(c.id)}" aria-label="「${esc(c.title)}」的更多操作">${icon("more", 18)}</button></article>`;
}
function letterMenu(c: Conversation, origin: Element | null) {
  const dialog = openModal(
    `<h2>${esc(c.title)}</h2>${filigree()}<div class="sheet-list"><button data-act="pin">${c.pinned ? `${icon("heart", 19)}不再置顶` : `${heart(17)}放在心上（置顶）`}</button><button data-act="rename">${icon("pencil", 19)}重新命名</button><button data-act="archive">${icon("archive", 19)}${c.archived ? "从归档取回" : "收进归档"}</button></div>`,
  );
  dialog.querySelector<HTMLButtonElement>('[data-act="pin"]')!.onclick = () => {
    dialog.close();
    if (!c.pinned) heartBurst(origin);
    void modifyConversation(c.id, { pinned: !c.pinned });
  };
  dialog.querySelector<HTMLButtonElement>('[data-act="rename"]')!.onclick = () => conversationSettings(c);
  dialog.querySelector<HTMLButtonElement>('[data-act="archive"]')!.onclick = () => {
    dialog.close();
    void modifyConversation(c.id, { archived: !c.archived });
  };
}
function renderConversationList(entering = false) {
  const container = document.querySelector<HTMLElement>(".conversation-list");
  if (!container) return;
  container.classList.toggle("entering", entering);
  const list = conversations.filter(
    (c) =>
      (filter === "已归档" ? c.archived : !c.archived) &&
      (filter === "全部" || filter === "已归档" || c.group === filter) &&
      (!query ||
        `${c.title} ${c.preview || ""}`
          .toLowerCase()
          .includes(query.toLowerCase())),
  );
  const narrowed = !!query || filter !== "全部";
  container.innerHTML = list.length
    ? list.map(conversationRow).join("")
    : `<div class="empty">${narrowed ? `<p>还没找到这一段回忆。</p><button class="text-button" id="clear-filter">看看全部信笺</button>` : `<h2>第一封信，从今天开始。</h2><p>想到什么，就写给她吧。</p>`}</div>`;
  const count = document.querySelector("#letter-count");
  if (count) count.textContent = String(conversations.filter((c) => !c.archived).length);
  document.querySelectorAll<HTMLButtonElement>("[data-group]").forEach((b) => {
    b.classList.toggle("selected", b.dataset.group === filter);
    b.setAttribute("aria-selected", String(b.dataset.group === filter));
  });
  $("#clear-filter")?.addEventListener("click", () => {
    filter = "全部";
    query = "";
    const search = document.querySelector<HTMLInputElement>("#search");
    if (search) search.value = "";
    renderConversationList();
  });
  container
    .querySelectorAll<HTMLButtonElement>(".conversation-open")
    .forEach((b) => (b.onclick = () => void openConversation(b.dataset.id!)));
  container.querySelectorAll<HTMLButtonElement>("[data-row-menu]").forEach(
    (b) =>
      (b.onclick = () => {
        const c = conversations.find((item) => item.id === b.dataset.rowMenu);
        if (c) letterMenu(c, b);
      }),
  );
}
function renderHub() {
  const paired = !!credentials().token;
  $("#view").innerHTML =
    `<section class="home"><div class="home-tools"><button id="theme-quick" class="glass-button"></button></div><figure class="arch"><span class="arch-bow">${bow(84)}</span><div class="arch-frame"><div class="arch-image" role="img" aria-label="${isDay() ? "午后，祥子坐在窗边" : "夜里，祥子坐在亮着灯的窗边"}"></div></div></figure><div class="home-body"><header class="home-greeting"><span class="script" aria-hidden="true">${salutation()}</span><h1>${greeting()
      .map((line) => `<span>${line}</span>`)
      .join("")}</h1><p class="home-date"><span>${homeDate()}</span><span class="presence"><i class="${connected ? "online" : ""}"></i><span id="presence-text">${connectionLine()}</span></span></p></header><aside class="note-card" aria-label="她留给你的小纸条">${filigree(116)}<p>「${dailyNote()}」</p><span class="script" aria-label="祥子">— Sakiko</span></aside><button class="letter-prompt" id="begin-chat"><span>写信给祥子…</span>${wax(17)}</button>${paired ? "" : `<div class="notice-line"><span>还没有接上琴房。</span><button class="text-button" id="pair-now">去连接</button></div>`}<section class="letters" aria-label="信笺"><div class="letters-head">${filigree()}<h2>信笺<span id="letter-count"></span></h2><button class="icon-button" id="search-toggle" aria-label="寻找一段回忆" aria-expanded="${!!query}">${icon("search", 19)}</button></div><label class="search"${query ? "" : " hidden"}>${icon("search", 16)}<input id="search" type="search" aria-label="搜索信笺" placeholder="寻找一段回忆" value="${esc(query)}"></label><div class="tabs" role="tablist">${groupTabs
      .map(([value, label]) => `<button class="tab" role="tab" data-group="${value}">${label}</button>`)
      .join("")}</div><div class="conversation-list"></div></section></div></section>`;
  refreshThemeButtons();
  $("#theme-quick").onclick = () => void updateSettings({ theme: isDay() ? "night" : "day" });
  $("#begin-chat").onclick = () => void newChat();
  $("#pair-now")?.addEventListener("click", () => pairing());
  $("#search-toggle").onclick = () => {
    const field = $(".search");
    const opening = field.hidden;
    field.hidden = !opening;
    $("#search-toggle").setAttribute("aria-expanded", String(opening));
    if (opening) ($("#search") as HTMLInputElement).focus();
    else if (query) {
      query = "";
      ($("#search") as HTMLInputElement).value = "";
      renderConversationList();
    }
  };
  $("#search").addEventListener("input", (e) => {
    query = (e.target as HTMLInputElement).value;
    renderConversationList();
  });
  document.querySelectorAll<HTMLButtonElement>("[data-group]").forEach(
    (b) =>
      (b.onclick = () => {
        filter = b.dataset.group!;
        renderConversationList();
      }),
  );
  renderConversationList(true);
}
async function loadConversations() {
  try {
    const [data, archived] = await Promise.all([
      api<{ conversations: Conversation[] }>("/conversations"),
      api<{ conversations: Conversation[] }>("/conversations?archived=true"),
    ]);
    conversations = [...data.conversations, ...archived.conversations];
    await save(cacheKey("conversations"), conversations);
    connected = true;
  } catch (error) {
    connected = false;
    conversations = await cached(cacheKey("conversations"), conversations);
    if (credentials().token) report(error);
  }
  connectionState();
  if (page === "hub") {
    if (document.querySelector(".home")) refreshHubLatest();
    else renderHub();
  }
}
/** Refresh the letters without replaying the whole room. */
function refreshHubLatest() {
  renderConversationList(true);
  const line = document.querySelector("#presence-text");
  if (line) line.textContent = connectionLine();
}
async function newChat() {
  if (!credentials().token) {
    pairing();
    return;
  }
  try {
    const c = await api<Conversation>("/conversations", {
      title: "未写完的乐章",
      group: "专属日常",
    });
    conversations.unshift(c);
    await save(cacheKey("conversations"), conversations);
    await openConversation(c.id);
  } catch (error) {
    report(error);
  }
}
async function modifyConversation(id: string, changes: Partial<Conversation>) {
  try {
    await api(`/conversations/${id}`, changes, "PATCH");
    await loadConversations();
  } catch (error) {
    report(error);
  }
}
async function openConversation(id: string) {
  streamAbort?.abort();
  streamLive = false;
  conversation = conversations.find((c) => c.id === id);
  if (!conversation) return;
  page = "chat";
  enterSubpage();
  viewVersion++;
  const version = viewVersion;
  const localSnapshot = await cached<{
    messages: Message[];
    cursor: number;
  } | null>(cacheKey(`snapshot:${id}`), null);
  messages =
    localSnapshot?.messages || (await cached(cacheKey(`messages:${id}`), []));
  messageCursor = localSnapshot?.cursor || 0;
  events = await cached(cacheKey(`events:${id}`), []);
  pending = await cached<Pending | undefined>(
    cacheKey(`pending:${id}`),
    undefined,
  );
  activeRun = "";
  for (const e of events) {
    if (e.kind === "run_started") activeRun = e.run_id;
    if (
      ["run_finished", "run_failed", "run_stopped"].includes(e.kind) &&
      e.run_id === activeRun
    )
      activeRun = "";
  }
  stopping = false;
  selectedAttachments = [];
  shell();
  renderChat();
  await restoreDraft();
  try {
    const data = await api<{ messages: Message[]; cursor: number }>(
      `/conversations/${id}/messages`,
    );
    if (version !== viewVersion) return;
    mergeMessageSnapshot(data);
    await save(cacheKey(`snapshot:${id}`), { messages, cursor: messageCursor });
    renderMessageList();
    await poll();
    if (pending && !activeRun) void retryPending();
    void startStream(id, version);
  } catch (error) {
    report(error);
    void startStream(id, version);
  }
}
function chatStatusLine() {
  if (recorder?.state === "recording") return `${icon("mic", 12)}在听你说…`;
  if (activeRun && !stopping) return `${heart(10)}正在写回信…`;
  if (!credentials().token) return "还没有接上琴房";
  if (!connected) return "琴房的灯暂时熄了 · 草稿会替你留着";
  if (status?.provider.name === "development") return "本地演练 · 回复不来自模型";
  return "祥子 · 在你身边";
}
function refreshChatStatus() {
  const element = document.querySelector<HTMLElement>("#chat-status");
  if (!element) return;
  element.innerHTML = chatStatusLine();
  element.classList.toggle("busy", (!!activeRun && !stopping) || recorder?.state === "recording");
}
/** The send button is a quiet circle until there is something to send. */
function refreshSendButton() {
  const button = document.querySelector<HTMLButtonElement>("#send");
  if (!button) return;
  const draft = document.querySelector<HTMLTextAreaElement>("#draft");
  const empty = !draft?.value.trim() && !selectedAttachments.length;
  button.innerHTML = icon(activeRun ? "stop" : "send", 19);
  button.classList.toggle("stop", !!activeRun);
  button.classList.toggle("idle", !activeRun && empty);
  button.setAttribute("aria-label", activeRun ? "请她先停一停" : "寄出");
}
function renderChat() {
  if (!conversation) {
    page = "hub";
    renderHub();
    return;
  }
  $("#view").innerHTML =
    `<section class="chat"><header class="chat-head"><button class="icon-button" id="chat-back" aria-label="回到琴房">${icon("back")}</button><img class="chat-avatar" data-mood src="${art()}" alt="祥子"><div class="chat-title"><button id="rename-chat" aria-label="这段乐章的名字与设置">${esc(conversation.title)}</button><small id="chat-status"></small></div><button class="icon-button" id="chat-menu" aria-label="这段乐章的设置">${icon("more", 20)}</button></header><div class="chat-pins" id="chat-pins" hidden></div><div class="messages" id="messages"></div><button id="jump-bottom" class="jump-bottom" hidden>${icon("chevron", 15)}回到最新</button><footer class="composer-wrap"><div id="upload-status"></div><div class="composer"><div id="attachments" class="attachments"></div><textarea id="draft" aria-label="写给祥子的话" placeholder="写给祥子…" rows="1"></textarea><div class="composer-bar"><button id="attach" class="icon-button" aria-label="添加文件" title="添加文件">${icon("plus", 21)}</button><button id="record" class="icon-button" aria-label="录一段语音" title="录一段语音">${icon("mic", 19)}</button><button id="quote" class="icon-button" aria-label="引用选中的文字" title="引用选中的文字">${icon("quote", 18)}</button><button id="draw" class="icon-button" aria-label="画板" title="画板">${icon("palette", 18)}</button><span id="record-status"></span><span class="composer-gap"></span><button id="model" class="model-trigger" aria-label="选择模型" aria-haspopup="dialog"><span>${esc(selectedFamily(models, selectedModel)?.name || "等待连接模型")}</span>${icon("chevron", 13)}</button><button id="effort" class="model-trigger effort-trigger" aria-label="思考强度" aria-haspopup="dialog"></button><button id="send" class="send-button idle" aria-label="寄出">${icon("send", 19)}</button></div></div><p class="composer-foot" id="draft-state" aria-live="polite"></p></footer></section>`;
  refreshChatStatus();
  $("#chat-back").onclick = () => void navigate("hub");
  $("#rename-chat").onclick = () => conversationSettings(conversation!, true);
  $("#chat-menu").onclick = () => conversationSettings(conversation!, true);
  $("#model").onclick = showModelPicker;
  refreshEffort();
  $("#effort").onclick = showStrengthPicker;
  $("#attach").onclick = () => ($("#file-input") as HTMLInputElement).click();
  $("#record").onclick = () => void record();
  $("#draw").onclick = () =>
    void import("./media-editor")
      .then((m) => m.openBlankCanvas(storeGeneratedFile))
      .catch(report);
  $("#quote").onpointerdown = (e) => {
    e.preventDefault();
    const text = window.getSelection()?.toString().trim();
    if (text) {
      const input = $("#draft") as HTMLTextAreaElement;
      input.value +=
        (input.value ? "\n\n" : "") +
        text
          .split("\n")
          .map((t) => `> ${t}`)
          .join("\n") +
        "\n\n";
      input.dispatchEvent(new Event("input"));
      input.focus();
    }
  };
  const draft = $("#draft") as HTMLTextAreaElement;
  draft.oninput = () => {
    draft.style.height = "auto";
    draft.style.height = `${Math.min(180, draft.scrollHeight)}px`;
    const value = draft.value;
    refreshSendButton();
    void save(cacheKey(`draft:${conversation!.id}`), value)
      .then(() => {
        if (draft.isConnected && draft.value === value)
          $("#draft-state").textContent = value ? "草稿替你留着" : "";
      })
      .catch(() => {
        if (draft.isConnected) $("#draft-state").textContent = "草稿还没有存好";
      });
  };
  draft.onkeydown = (e) => {
    if (e.key === "Enter" && !e.shiftKey && !e.isComposing) {
      e.preventDefault();
      void send();
    }
  };
  $("#send").onclick = () => void (activeRun ? stop() : send());
  $("#messages").onwheel = (event) => {
    scrollIntentUntil = performance.now() + 600;
    if (event.deltaY < 0) readLock = true;
  };
  $("#messages").ontouchmove = () => {
    scrollIntentUntil = performance.now() + 600;
    readLock = true;
  };
  $("#messages").onkeydown = () => {
    scrollIntentUntil = performance.now() + 600;
  };
  $("#messages").onscroll = () => {
    const list = $("#messages");
    const away = list.scrollHeight - list.scrollTop - list.clientHeight > 100;
    if (!away) readLock = false;
    else if (performance.now() < scrollIntentUntil) readLock = true;
    $("#jump-bottom").hidden = !readLock;
  };
  $("#jump-bottom").onclick = () => {
    readLock = false;
    $("#messages").scrollTo({
      top: $("#messages").scrollHeight,
      behavior: "smooth",
    });
    $("#jump-bottom").hidden = true;
  };
  $("#view").ondragover = (e) => {
    e.preventDefault();
  };
  $("#view").ondrop = (e) => {
    e.preventDefault();
    if (e.dataTransfer?.files.length)
      void (async () => {
        for (const file of e.dataTransfer!.files) await upload(file);
      })();
  };
  renderMessageList();
  renderAttachments();
  void refreshPins();
}
function showModelPicker() {
  const families=modelFamilies(models),current=selectedFamily(models,selectedModel);
  const dialog=openModal(`<div class="model-sheet-heading"><span class="eyebrow">琴房的演奏者</span><h2>今天，请谁来弹？</h2><p>思考强度在输入框旁单独调整</p></div><div class="model-sheet-list">${families.map(family=>`<button class="model-choice ${family.id===current?.id?'selected':''}" data-family="${esc(family.id)}"><span><strong>${esc(family.name)}</strong><small>${family.levels.map(level=>strengthName(level.effort)).join(' · ')}</small></span><span class="model-choice-mark">${family.id===current?.id?icon('check',18):''}</span></button>`).join('')}</div>`);
  dialog.classList.add('model-sheet');
  for(const button of dialog.querySelectorAll<HTMLButtonElement>('[data-family]'))button.onclick=()=>{
    const family=families.find(item=>item.id===button.dataset.family)!;
    const level=family.levels.find(item=>item.effort===effort) || family.levels.find(item=>item.effort==='medium') || family.levels[0];
    if(level){selectedModel=level.wireId;effort=level.effort;}
    $('#model').innerHTML=`<span>${esc(family.name)}</span>${icon('chevron',14)}`;
    refreshEffort();dialog.close();
  };
}
function showStrengthPicker() {
  const family=selectedFamily(models,selectedModel);
  if(!family)return;
  const dialog=openModal(`<div class="model-sheet-heading"><span class="eyebrow">${esc(family.name)}</span><h2>要想得多深一点？</h2><p>越深越慢，也越细致</p></div><div class="strength-options">${family.levels.map(level=>`<button data-strength="${esc(level.effort)}" class="${level.effort===effort?'selected':''}">${esc(strengthName(level.effort))}</button>`).join('')}</div>`);
  dialog.classList.add('model-sheet','strength-sheet');
  for(const button of dialog.querySelectorAll<HTMLButtonElement>('[data-strength]'))button.onclick=()=>{
    const level=family.levels.find(item=>item.effort===button.dataset.strength)!;
    selectedModel=level.wireId;effort=level.effort;refreshEffort();
    if(['max','xhigh'].includes(effort))playEffect('effort');dialog.close();
  };
}
function refreshEffort() {
  const levels=selectedFamily(models,selectedModel)?.levels || [];
  if(!levels.some(level=>level.effort===effort))effort=levels[0]?.effort || '';
  const button=$('#effort') as HTMLButtonElement;
  if(button){button.innerHTML=`<span>${esc(strengthName(effort) || '默认')}</span>${icon('chevron',14)}`;button.disabled=levels.length<=1;}
}
async function restoreDraft() {
  if (conversation && $("#draft")) {
    ($("#draft") as HTMLTextAreaElement).value = await cached(
      cacheKey(`draft:${conversation.id}`),
      "",
    );
    selectedAttachments = await cached(
      cacheKey(`attachments:${conversation.id}`),
      [],
    );
    renderAttachments();
  }
}
function artifactButton(a: Artifact | string) {
  if (typeof a === "string") {
    const known = artifacts.find((item) => item.id === a);
    if (known) return artifactButton(known);
    return `<button class="file-chip" data-artifact="${esc(a)}">${icon("clip", 15)}附件</button>`;
  }
  if (a.mime.startsWith("image/"))
    return `<button class="image-bubble" data-artifact="${esc(a.id)}"><span data-thumb="${esc(a.id)}">${icon("sparkle", 24)}</span><small>${esc(a.name)}</small></button>`;
  return `<button class="file-chip" data-artifact="${esc(a.id)}">${icon("clip", 15)}<span>${esc(a.name)}</span><small>${bytes(a.size)}</small></button>`;
}
const imagePreviewCache = new Map<string, Promise<string>>();
let messageResizeObserver: ResizeObserver | undefined;
async function thumbnailUrl(blob: Blob) {
  const bitmap = await createImageBitmap(blob);
  const scale = Math.min(1, 480 / Math.max(bitmap.width, bitmap.height));
  const canvas = document.createElement("canvas");
  canvas.width = Math.max(1, Math.round(bitmap.width * scale));
  canvas.height = Math.max(1, Math.round(bitmap.height * scale));
  canvas.getContext("2d")!.drawImage(bitmap, 0, 0, canvas.width, canvas.height);
  bitmap.close();
  const thumbnail = await new Promise<Blob>((resolve) =>
    canvas.toBlob((value) => resolve(value || blob), "image/webp", 0.88),
  );
  return URL.createObjectURL(thumbnail);
}
function loadImagePreviews(container: HTMLElement) {
  container
    .querySelectorAll<HTMLElement>("[data-thumb]")
    .forEach(async (element) => {
      const id = element.dataset.thumb!;
      const key = cacheKey(`image:${id}`);
      let pending = imagePreviewCache.get(key);
      if (!pending) {
        pending = request(`/artifacts/${id}/content`)
          .then((response) => response.blob())
          .then(thumbnailUrl);
        imagePreviewCache.set(key, pending);
        if (imagePreviewCache.size > 64) {
          const current = new Set(
            [...document.querySelectorAll<HTMLElement>("[data-thumb]")].map(
              (node) => cacheKey(`image:${node.dataset.thumb}`),
            ),
          );
          const oldest = [...imagePreviewCache.keys()].find(
            (entry) => !current.has(entry),
          );
          if (oldest) {
            const stale = imagePreviewCache.get(oldest)!;
            imagePreviewCache.delete(oldest);
            void stale
              .then((url) => setTimeout(() => URL.revokeObjectURL(url), 60000))
              .catch(() => {});
          }
        }
      }
      try {
        const url = await pending;
        if (!element.isConnected) return;
        const image = new Image();
        image.alt = "附件画面";
        image.decoding = "async";
        image.loading = "lazy";
        image.src = url;
        element.replaceChildren(image);
      } catch {
        imagePreviewCache.delete(key);
      }
    });
}
function renderMessageList() {
  refreshPortrait();
  if (page !== "chat" || !conversation || !$("#messages")) return;
  const list = $("#messages"),
    scroll = list.scrollTop;
  const disclosures = new Map<string, boolean[]>();
  list.querySelectorAll<HTMLElement>("[data-message]").forEach((element) => {
    disclosures.set(
      element.dataset.message!,
      [...element.querySelectorAll("details")].map((detail) => detail.open),
    );
  });
  const auxiliary = events.filter(
    (e) =>
      !["system", "L3", "l3"].includes(e.layer) &&
      e.kind !== "reply_delta" &&
      (settings.transparency !== "companion" || e.kind === "artifact"),
  );
  const runMessages = new Map(events.filter((e) => e.kind === "run_started" && e.payload.message_id)
    .map((e) => [e.run_id, String(e.payload.message_id)]));
  const delivered = new Map<string, Set<string>>();
  for (const event of events) {
    if (event.kind !== "artifact" || !event.payload.artifact) continue;
    const messageId = runMessages.get(event.run_id);
    if (!messageId) continue;
    if (!delivered.has(messageId)) delivered.set(messageId, new Set());
    delivered.get(messageId)!.add((event.payload.artifact as Artifact).id);
  }
  const visibleFiles = new Map<string, (Artifact | string)[]>(messages.map((m): [string, (Artifact | string)[]] => [m.id,
    (m.attachments || []).filter((a) => !delivered.get(m.id)?.has(typeof a === "string" ? a : a.id))]));
  if (seenConversation !== conversation.id) {
    seenConversation = conversation.id;
    seenMessages.clear();
    messages.forEach((m) => seenMessages.add(m.id));
  }
  const rows: { time: number; html: string }[] = messages.map((m) => {
    const sakiko = m.role !== "user";
    const fresh = !seenMessages.has(m.id);
    seenMessages.add(m.id);
    const note = m.status === "interrupted" || m.status === "stopped" ? "先停在这里" : m.status === "failed" ? "这一段没能写完" : "";
    const streaming = sakiko && ["streaming", "running"].includes(m.status);
    const files = visibleFiles.get(m.id) || [];
    return {
      time: new Date(
        events.find(
          (e) => e.kind === "reply_delta" && e.payload.message_id === m.id,
        )?.created_at || m.created_at,
      ).getTime(),
      html: sakiko
        ? `<article class="message from-sakiko${streaming ? " streaming" : ""}${fresh ? " fresh" : ""}" data-message="${esc(m.id)}"><header class="message-head"><img class="avatar-sm" src="${art("idle_gentle")}" alt="" loading="lazy"><strong>祥子${crown(13)}</strong><time datetime="${esc(m.created_at)}">${clock(m.created_at)}</time>${note ? `<span class="state">${note}</span>` : ""}</header><div class="message-content">${markdown(m.content || "…", { taskStates: taskStates[m.id], artifacts: m.attachments.filter((a): a is Artifact => typeof a !== "string") })}</div>${files.length ? `<div class="message-files">${files.map(artifactButton).join("")}</div>` : ""}<div class="message-actions"><button data-copy-message="${esc(m.id)}" aria-label="复制这段话" title="复制">${icon("copy", 16)}</button><button data-pin-message="${esc(m.id)}" aria-label="钉在这段乐章" title="钉住">${icon("pin", 16)}</button><button data-read="${esc(m.id)}" aria-label="静谧阅读" title="静谧阅读">${icon("book", 16)}</button><button data-fork="${esc(m.id)}" aria-label="从这里另写一段" title="从这里另写一段">${icon("fork", 16)}</button>${settings.transparency === "studio" ? `<button data-raw-message="${esc(m.id)}" aria-label="原始记录" title="原始记录">${icon("archive", 16)}</button>` : ""}</div></article>`
        : `<article class="message from-user${fresh ? " fresh" : ""}" data-message="${esc(m.id)}"><div class="message-content"><div class="user-text">${esc(m.content)}</div></div>${files.length ? `<div class="message-files">${files.map(artifactButton).join("")}</div>` : ""}<footer class="message-meta">${note ? `<span class="state">${note}</span>` : ""}<time datetime="${esc(m.created_at)}">${clock(m.created_at)}</time><button data-copy-message="${esc(m.id)}" aria-label="复制这段话" title="复制">${icon("copy", 15)}</button><button data-pin-message="${esc(m.id)}" aria-label="钉在这段乐章" title="钉住">${icon("pin", 15)}</button></footer></article>`,
    };
  });
  for (const event of auxiliary) {
    const payload = event.payload;
    const text = String(
      payload.text ?? payload.title ?? payload.summary ?? payload.name ?? "",
    );
    if (!text && !payload.artifact) continue;
    const l1 = /1/.test(event.layer);
    rows.push({
      time: new Date(event.created_at).getTime(),
      html: payload.artifact
        ? `<div class="event-artifact">${event.kind === "visual_input" ? "<small>随消息附上的画面</small>" : ""}${artifactButton(payload.artifact as Artifact)}</div>`
        : `<details class="event-pill ${l1 ? "thought" : ""}"><summary>${icon(l1 ? "sparkle" : "check", 15)}${esc(text.slice(0, 150))}</summary><div>${esc(text)}${typeof payload.diagnostic_id === "string" ? `<button class="text-button" data-diagnostic="${esc(payload.diagnostic_id)}">打开主机记录</button>` : ""}${settings.transparency === "studio" ? `<pre>${esc(JSON.stringify(payload, null, 2))}</pre>` : ""}</div></details>`,
    });
  }
  for (const event of events.filter((e) => e.kind === "narration"))
    rows.push({
      time: new Date(event.created_at).getTime(),
      html: `<div class="narration">${esc(event.payload.text)}</div>`,
    });
  rows.sort((a, b) => a.time - b.time);
  let lastDay = "";
  const flowHtml = rows
    .map((row) => {
      const day = Number.isNaN(row.time) ? lastDay : new Date(row.time).toDateString();
      const divider = day && day !== lastDay ? `<div class="day-divider" role="separator">${dayLabel(row.time)}</div>` : "";
      lastDay = day || lastDay;
      return divider + row.html;
    })
    .join("");
  const flow = document.createElement("div");
  flow.className = "message-flow";
  flow.style.height = !rows.length && !pending ? "100%" : "auto";
  flow.innerHTML = rows.length
    ? flowHtml
    : pending
      ? ""
      : `<div class="chat-empty"><div class="cameo-frame">${bow(54)}<img class="empty-portrait" data-mood src="${art()}" alt="祥子"></div><span class="script" aria-hidden="true">Only for you</span><h2>这一刻，只听你说。</h2><p>不用急着整理语言。<br>想到哪里，就从哪里开始吧。</p><div class="starters">${starters()
          .map(([label, text]) => `<button data-starter="${esc(text)}">${heart(13)}<span>${label}</span>${icon("arrow", 16)}</button>`)
          .join("")}</div></div>`;
  list.replaceChildren(flow);
  if (pending)
    flow.insertAdjacentHTML(
      "beforeend",
      `<article class="message from-user queued"><div class="message-content"><div class="user-text">${esc(pending.content)}</div></div><footer class="message-meta"><span class="state">正在寄出</span><button id="retry-send" class="text-button">重新寄出</button></footer></article>`,
    );
  if (activeRun && !stopping)
    flow.insertAdjacentHTML(
      "beforeend",
      `<div class="typing" role="status"><img class="avatar-sm" src="${art("thinking_deep")}" alt=""><span class="typing-hearts">${heart(9)}${heart(9)}${heart(9)}</span><span>正在写回信</span></div>`,
    );
  flow.querySelectorAll<HTMLButtonElement>("[data-starter]").forEach(
    (button) =>
      (button.onclick = () => {
        const input = document.querySelector<HTMLTextAreaElement>("#draft");
        if (!input) return;
        input.value = button.dataset.starter!;
        input.dispatchEvent(new Event("input"));
        input.focus();
        input.setSelectionRange(input.value.length, input.value.length);
      }),
  );
  flow.querySelectorAll<HTMLElement>("[data-message]").forEach((element) => {
    const states = disclosures.get(element.dataset.message!);
    if (states)
      element.querySelectorAll("details").forEach((detail, index) => {
        if (states[index] !== undefined) detail.open = states[index];
      });
  });
  messageResizeObserver?.disconnect();
  messageResizeObserver = new ResizeObserver(() => {
    if (!readLock && list.isConnected) list.scrollTop = list.scrollHeight;
  });
  messageResizeObserver.observe(flow);
  if (readLock) list.scrollTop = scroll;
  else list.scrollTop = list.scrollHeight;
  loadImagePreviews(list);
  void enhance(list).catch(report);
  void loadTasks();
  list
    .querySelectorAll<HTMLInputElement>("[data-task-index]:not(:disabled)")
    .forEach(
      (input) =>
        (input.onchange = async () => {
          const id =
              input.closest<HTMLElement>("[data-message]")!.dataset.message!,
            checked = input.checked;
          input.disabled = true;
          try {
            const result = await api<{ tasks: Record<string, boolean> }>(
              `/messages/${id}/tasks/${input.dataset.taskIndex}`,
              { checked },
              "PATCH",
            );
            taskStates[id] = result.tasks;
            if (checked) {
              portraitCue("proud_smug");
              toast("做得很好。……勉强夸你一句。", true);
            }
            renderMessageList();
          } catch (error) {
            input.checked = !checked;
            input.disabled = false;
            report(error);
          }
        }),
    );
  list.querySelectorAll<HTMLButtonElement>("[data-pin-message]").forEach(
    (b) =>
      (b.onclick = async () => {
        try {
          await addPin(conversation!.id, "message", b.dataset.pinMessage!);
          heartBurst(b);
          portraitCue("proud_smug");
          await refreshPins();
        } catch (error) {
          report(error);
        }
      }),
  );
  list.querySelectorAll<HTMLButtonElement>("[data-copy-message]").forEach(
    (b) =>
      (b.onclick = () =>
        void navigator.clipboard
          .writeText(
            messages.find((m) => m.id === b.dataset.copyMessage)?.content || "",
          )
          .then(() => toast("这段话，替你收好了。"))
          .catch(report)),
  );
  list
    .querySelectorAll<HTMLButtonElement>("[data-read]")
    .forEach((b) => (b.onclick = () => reading(b.dataset.read!)));
  list
    .querySelectorAll<HTMLElement>(".from-sakiko .message-content")
    .forEach(
      (e) =>
        (e.ondblclick = () =>
          reading(e.closest<HTMLElement>("[data-message]")!.dataset.message!)),
    );
  list
    .querySelectorAll<HTMLButtonElement>("[data-fork]")
    .forEach((b) => (b.onclick = () => void fork(b.dataset.fork!)));
  list
    .querySelectorAll<HTMLButtonElement>("[data-artifact]")
    .forEach((b) => (b.onclick = () => void openArtifact(b.dataset.artifact!)));
  list
    .querySelectorAll<HTMLButtonElement>("[data-diagnostic]")
    .forEach(
      (button) =>
        (button.onclick = () =>
          void import("./diagnostics")
            .then((module) => module.openDiagnostic(button.dataset.diagnostic!))
            .catch(report)),
    );
  list
    .querySelectorAll<HTMLButtonElement>("[data-raw-message]")
    .forEach(
      (button) =>
        (button.onclick = () =>
          void import("./diagnostics")
            .then((module) => module.openRawMessage(button.dataset.rawMessage!))
            .catch(report)),
    );
  $("#retry-send")?.addEventListener("click", () => void retryPending());
  refreshSendButton();
  refreshChatStatus();
}
async function refreshPins() {
  const element = $("#chat-pins");
  if (element && conversation)
    await showPins(
      element,
      conversation.id,
      (id) => {
        const target = document.querySelector<HTMLElement>(
          `[data-message="${CSS.escape(id)}"]`,
        );
        if (target) {
          readLock = true;
          target.scrollIntoView({ block: "center", behavior: "smooth" });
        }
      },
      (id) => void openArtifact(id),
    );
}
async function loadTasks() {
  const id = conversation?.id;
  if (!id) return;
  const candidates = messages.filter(
    (m) =>
      ["completed", "stopped"].includes(m.status) &&
      !!document.querySelector(
        `[data-message="${CSS.escape(m.id)}"] [data-task-index]`,
      ) &&
      !taskStates[m.id] &&
      !taskRequests.has(m.id),
  );
  for (const message of candidates) {
    taskRequests.add(message.id);
    try {
      const result = await api<{ tasks: Record<string, boolean> }>(
        `/messages/${message.id}/tasks`,
      );
      taskStates[message.id] = result.tasks;
      if (conversation?.id === id) renderMessageList();
    } catch {
    } finally {
      taskRequests.delete(message.id);
    }
  }
}
async function send() {
  if (!conversation || loading || activeRun) return;
  const draft = $("#draft") as HTMLTextAreaElement;
  const content = draft.value.trim();
  if (!content && !selectedAttachments.length) return;
  if (pending) {
    toast("上一封还没有送达。先重试，或继续保留草稿。");
    return;
  }
  playEffect("send");
  pending = {
    content,
    client_id: crypto.randomUUID(),
    model: selectedModel,
    effort,
    attachments: selectedAttachments.map((a) => a.id),
  };
  await save(cacheKey(`pending:${conversation.id}`), pending);
  draft.value = "";
  draft.style.height = "auto";
  $("#draft-state").textContent = "";
  selectedAttachments = [];
  await save(cacheKey(`attachments:${conversation.id}`), []);
  await save(cacheKey(`draft:${conversation.id}`), "");
  renderAttachments();
  renderMessageList();
  await retryPending();
}
async function retryPending() {
  if (!conversation || !pending || loading) return;
  loading = true;
  const id = conversation.id,
    payload = pending;
  try {
    const result = await api<{ message: Message; run_id: string }>(
      `/conversations/${id}/messages`,
      payload,
    );
    await save(cacheKey(`pending:${id}`), null);
    if (conversation?.id !== id) return;
    pending = undefined;
    activeRun = result.run_id;
    stopping = false;
    const data = await api<{ messages: Message[]; cursor: number }>(
      `/conversations/${id}/messages`,
    );
    mergeMessageSnapshot(data);
    await save(cacheKey(`snapshot:${id}`), { messages, cursor: messageCursor });
    renderMessageList();
    void loadConversations();
  } catch (error) {
    report(error);
  } finally {
    loading = false;
  }
}
async function stop() {
  if (!activeRun) return;
  const id = activeRun;
  stopping = true;
  activeRun = "";
  renderMessageList();
  try {
    await api(`/runs/${id}/stop`, {});
  } catch (error) {
    activeRun = id;
    stopping = false;
    renderMessageList();
    report(error);
  }
}
async function poll() {
  if (
    pollBusy ||
    streamLive ||
    page !== "chat" ||
    !conversation ||
    !credentials().token
  )
    return;
  pollBusy = true;
  const id = conversation.id,
    version = viewVersion;
  try {
    const after = events.at(-1)?.seq || 0;
    const data = await api<{ events: StreamEvent[]; cursor: number }>(
      `/conversations/${id}/events?after=${after}`,
    );
    if (version !== viewVersion) return;
    if (data.events.length) {
      events.push(...data.events.filter((e) => e.seq > after));
      await save(cacheKey(`events:${id}`), events);
      for (const e of data.events) {
        if (e.kind === "run_started" && !stopping) activeRun = e.run_id;
        if (
          ["run_finished", "run_failed", "run_stopped"].includes(e.kind) &&
          e.run_id === activeRun
        ) {
          activeRun = "";
          stopping = false;
          // Android follows replies by polling; give it the same small moment the stream path has.
          if (e.kind === "run_finished") {
            playEffect("reply");
            portraitCue("happy_achieved");
          }
        }
        if (e.kind === "run_failed" && e.payload.message)
          toast(String(e.payload.message));
      }
      const snapshot = await api<{ messages: Message[]; cursor: number }>(
        `/conversations/${id}/messages`,
      );
      if (version !== viewVersion) return;
      mergeMessageSnapshot(snapshot);
      await save(cacheKey(`snapshot:${id}`), {
        messages,
        cursor: messageCursor,
      });
      renderMessageList();
    }
    const reconnected = !connected;
    connected = true;
    if (reconnected && pending && !activeRun && conversation?.id === id) void retryPending();
  } catch {
    connected = false;
  } finally {
    pollBusy = false;
    connectionState();
  }
}
function replayMessageEvent(target: Message[], event: StreamEvent) {
  const id = String(event.payload.message_id || "");
  if (!id) return;
  let message = target.find((item) => item.id === id);
  if (event.kind === "reply_delta") {
    if (!message) {
      message = {
        id,
        conversation_id: event.conversation_id,
        role: "assistant",
        content: "",
        status: "streaming",
        created_at: event.created_at,
        attachments: [],
      };
      target.push(message);
    }
    message.content += String(event.payload.text || "");
  }
  if (message && event.payload.status)
    message.status = String(event.payload.status);
}
function mergeMessageSnapshot(snapshot: {
  messages: Message[];
  cursor: number;
  active_run?: { id: string } | null;
}) {
  const cursor = snapshot.cursor || 0;
  const next = snapshot.messages;
  for (const event of events)
    if (event.seq > cursor) replayMessageEvent(next, event);
  messages = next;
  messageCursor = Math.max(cursor, events.at(-1)?.seq || 0);
  if ("active_run" in snapshot && !stopping) {
    activeRun = snapshot.active_run?.id || "";
    for (const event of events) {
      if (event.seq <= cursor) continue;
      if (event.kind === "run_started") activeRun = event.run_id;
      if (
        ["run_finished", "run_failed", "run_stopped"].includes(event.kind) &&
        activeRun === event.run_id
      )
        activeRun = "";
    }
  }
}
const snapshotRequests = new Set<string>();
const snapshotAgain = new Set<string>();
async function syncRemoteMessages(id: string, version: number) {
  const key = `${id}:${version}`;
  if (snapshotRequests.has(key)) {
    snapshotAgain.add(key);
    return;
  }
  snapshotRequests.add(key);
  try {
    const snapshot = await api<{ messages: Message[]; cursor: number }>(
      `/conversations/${id}/messages`,
    );
    if (version !== viewVersion) return;
    mergeMessageSnapshot(snapshot);
    if (!streamFrame) streamFrame = requestAnimationFrame(flushStreamView);
  } catch {
    // Durable stream replay and the normal reconnect snapshot retain this work.
  } finally {
    snapshotRequests.delete(key);
    if (snapshotAgain.delete(key) && version === viewVersion)
      void syncRemoteMessages(id, version);
  }
}
function flushStreamView() {
  streamFrame = 0;
  if (!conversation || page !== "chat") return;
  void save(cacheKey(`snapshot:${conversation.id}`), {
    messages,
    cursor: messageCursor,
  }).catch(() => {});
  void save(cacheKey(`events:${conversation.id}`), events).catch(() => {});
  const selection = window.getSelection();
  if (
    selection &&
    !selection.isCollapsed &&
    $("#messages")?.contains(selection.anchorNode)
  )
    return;
  renderMessageList();
}
async function startStream(id: string, version: number) {
  if(isAndroidApp())return;
  if (version !== viewVersion || page !== "chat") return;
  streamAbort?.abort();
  const controller = new AbortController();
  streamAbort = controller;
  streamLive = true;
  try {
    await consumeStream(
      `/conversations/${id}/stream?after=${events.at(-1)?.seq || 0}`,
      (event) => {
        if (version !== viewVersion || event.seq <= (events.at(-1)?.seq || 0))
          return;
        events.push(event);
        connected = true;
        const unseen = event.seq > messageCursor;
        if (unseen && event.kind === "message_created")
          void syncRemoteMessages(id, version);
        if (event.kind === "pins_changed") void refreshPins();
        if (event.kind === "widget_updated" && event.payload.message_id) {
          delete taskStates[String(event.payload.message_id)];
          void loadTasks();
        }
        if (unseen && event.kind === "run_started" && !stopping) {
          activeRun = event.run_id;
          void syncRemoteMessages(id, version);
        }
        if (
          unseen &&
          ["run_finished", "run_failed", "run_stopped"].includes(event.kind)
        ) {
          if (event.run_id === activeRun) activeRun = "";
          stopping = false;
        }
        if (unseen) {
          if (event.kind === "run_finished") { playEffect("reply"); portraitCue("happy_achieved"); }
          const messageId = String(event.payload.message_id || "");
          let message = messages.find((m) => m.id === messageId);
          if (event.kind === "reply_delta" && !stopping) {
            if (!message) {
              message = {
                id: messageId,
                conversation_id: id,
                role: "assistant",
                content: "",
                status: "streaming",
                created_at: event.created_at,
                attachments: [],
              };
              messages.push(message);
            }
            message.content += String(event.payload.text || "");
          }
          if (message && event.payload.status)
            message.status = String(event.payload.status);
          messageCursor = event.seq;
        }
        if (event.kind === "run_failed" && event.payload.message)
          toast(String(event.payload.message));
        if (!streamFrame) streamFrame = requestAnimationFrame(flushStreamView);
      },
      controller.signal,
    );
  } catch (error) {
    if (!controller.signal.aborted) {
      connected = false;
      connectionState();
    }
  } finally {
    if (streamAbort === controller) {
      streamLive = false;
      if (!controller.signal.aborted && version === viewVersion)
        setTimeout(() => {
          void poll().then(() => startStream(id, version));
        }, 1500);
    }
  }
}
function openModal(content: string, wide = false) {
  const dialog = $("#modal") as HTMLDialogElement;
  dialog.className = wide ? "wide" : "";
  dialog.innerHTML = `<button class="modal-close icon-button" aria-label="关闭">${icon("close")}</button>${content}`;
  dialog.querySelector<HTMLButtonElement>(".modal-close")!.onclick = () =>
    dialog.close();
  dialog.showModal();
  dialog.onclick = (e) => {
    if (e.target === dialog) {
      const r = dialog.getBoundingClientRect();
      if (
        e.clientX < r.left ||
        e.clientX > r.right ||
        e.clientY < r.top ||
        e.clientY > r.bottom
      )
        dialog.close();
    }
  };
  return dialog;
}
function pairing() {
  if(isAndroidApp()){void initializeAndroid(pair,true).then(bootstrap).catch(report);return;}
  const current = credentials();
  const local = ["localhost", "127.0.0.1"].includes(location.hostname);
  const dialog = openModal(
    `<h2>把琴房连起来</h2>${filigree()}<p class="dialog-lede">钥匙交给我以后，我们的信笺、记忆和珍藏，就都回来了。</p>${local ? `<button class="primary local-pair" id="local-pair">连接这台电脑</button><details class="manual-pair"><summary>使用配对密钥</summary>` : ""}<form id="pair-form"><label>设备名称<input name="device" value="${esc(current.device)}" autocomplete="off" required></label><label>配对密钥<input name="token" type="password" autocomplete="off" required></label><p class="field-note">密钥只保留在当前浏览器会话。</p><button class="primary" type="submit">连接琴房</button></form>${local ? "</details>" : ""}<p id="pair-error" class="form-error" role="alert"></p>`,
  );
  $("#local-pair")?.addEventListener("click", async () => {
    try {
      const response = await fetch("/api/local-pair", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ consent: true }),
      });
      if (!response.ok)
        throw new Error("这台电脑还没有允许本地配对。可以使用配对密钥。");
      const data = await response.json();
      pair(data.token, data.device);
      dialog.close();
      await bootstrap();
    } catch (error) {
      $("#pair-error").textContent =
        error instanceof Error ? error.message : "没有连上琴房。";
    }
  });
  $("#pair-form").onsubmit = async (e) => {
    e.preventDefault();
    const data = new FormData(e.target as HTMLFormElement),
      old = credentials();
    pair(String(data.get("token")), String(data.get("device")));
    try {
      status = await api<HostStatus>("/status");
      connected = true;
      dialog.close();
      await bootstrap();
    } catch (error) {
      pair(old.token, old.device);
      $("#pair-error").textContent =
        error instanceof Error ? error.message : "没有连上琴房。";
    }
  };
}
/** Name, shelf and (inside a chat) how much of her process to show. */
function conversationSettings(c: Conversation, inChat = false) {
  const transparency: [string, string][] = [["companion", "只看回信"], ["balanced", "适度"], ["studio", "全部过程"]];
  const dialog = openModal(
    `<h2>这段乐章</h2>${filigree()}<form id="edit-conversation"><label>名字<input name="title" value="${esc(c.title)}" required maxlength="120"></label><label>放在哪一册<select name="group">${groupNames
      .slice(1, 4)
      .map((g) => `<option ${c.group === g ? "selected" : ""}>${g}</option>`)
      .join("")}</select></label><button class="primary">保存</button></form>${inChat ? `<div class="sheet-section"><span>回信时，让你看到多少她的思考过程</span><div class="segmented" role="group" aria-label="透视度">${transparency
      .map(([value, label]) => `<button data-transparency="${value}" class="${settings.transparency === value ? "selected" : ""}" aria-pressed="${settings.transparency === value}">${label}</button>`)
      .join("")}</div></div>` : ""}`,
  );
  dialog.querySelectorAll<HTMLButtonElement>("[data-transparency]").forEach(
    (button) =>
      (button.onclick = async () => {
        await updateSettings({ transparency: button.dataset.transparency! });
        dialog.querySelectorAll<HTMLButtonElement>("[data-transparency]").forEach((item) => {
          const chosen = item.dataset.transparency === settings.transparency;
          item.classList.toggle("selected", chosen);
          item.setAttribute("aria-pressed", String(chosen));
        });
      }),
  );
  $("#edit-conversation").onsubmit = async (e) => {
    e.preventDefault();
    const data = new FormData(e.target as HTMLFormElement);
    try {
      await api(
        `/conversations/${c.id}`,
        { title: data.get("title"), group: data.get("group") },
        "PATCH",
      );
      c.title = String(data.get("title"));
      c.group = String(data.get("group"));
      dialog.close();
      const title = document.querySelector("#rename-chat");
      if (title && conversation?.id === c.id) title.textContent = c.title;
      await loadConversations();
    } catch (error) {
      report(error);
    }
  };
}
async function fork(messageId: string) {
  if (!conversation) return;
  try {
    const c = await api<Conversation>(
      `/conversations/${conversation.id}/fork`,
      { message_id: messageId, title: `${conversation.title} · 另一段乐章` },
    );
    conversations.unshift(c);
    await openConversation(c.id);
  } catch (error) {
    report(error);
  }
}
function reading(id: string) {
  const message = messages.find((m) => m.id === id);
  if (!message) return;
  const dialog = openModal(
    `<div class="reading-heading"><span class="eyebrow">静谧手稿</span><h2>${esc(conversation?.title || "这一页")}</h2></div><article class="reading-content">${markdown(message.content, { taskStates: taskStates[message.id], readonlyTasks: true })}</article><div class="reading-footer"><span aria-label="祥子">Sakiko</span><button id="copy-reading" class="text-button">复制原文</button><button id="save-reading" class="text-button">保存 Markdown</button><button id="export-knowledge" class="text-button">手账长图</button></div>`,
    true,
  );
  void enhance(dialog).catch(report);
  $("#copy-reading").onclick = () =>
    void navigator.clipboard
      .writeText(message.content)
      .then(() => toast("手稿已经替你收好了。"))
      .catch(report);
  $("#save-reading").onclick = () =>
    downloadBlob(
      new Blob([message.content], { type: "text/markdown;charset=utf-8" }),
      `${conversation?.title || "手稿"}.md`,
    );
  $("#export-knowledge").onclick = () =>
    void import("./knowledge-export")
      .then((module) =>
        module.openKnowledgeExport(
          {
            title: conversation?.title || "这一页",
            text: message.content,
            taskStates: taskStates[message.id],
          },
          storeGeneratedFile,
        ),
      )
      .catch(report);
}

async function loadMemories() {
  try {
    const result = await api<{ memories: Memory[] }>("/memories");
    memories = result.memories;
    await save(cacheKey("memories"), memories);
  } catch (error) {
    memories = await cached(cacheKey("memories"), []);
    if (credentials().token) report(error);
  }
  if (page === "memory") renderMemory(true);
}
function renderMemory(entering = false) {
  $("#view").innerHTML =
    `<section class="page memory-page">${pageHead("记忆", "她记得的，关于你的小事。", `<button class="text-button" id="add-memory">${icon("plus", 18)}记下一件事</button>`, "Little things about you")}${memories.length ? `<ol class="memory-list${entering ? " entering" : ""}">${memories.map((m, i) => `<li class="memory-item"><span class="memory-no">No. ${i + 1}${heart(11)}</span><div><p>${esc(m.content)}</p><small>记于${shortDate(m.updated_at)}</small></div><div class="memory-actions"><button class="icon-button" data-edit-memory="${esc(m.id)}" aria-label="重新写这件事">${icon("edit", 17)}</button><button class="icon-button" data-delete-memory="${esc(m.id)}" aria-label="移除这件事">${icon("trash", 17)}</button></div></li>`).join("")}</ol>` : `<div class="empty">${filigree()}<h2>慢慢认识你。</h2><p>想让她记住的事，由你亲手写下。</p><button class="text-button" id="empty-memory-add">${icon("plus", 17)}写下第一件</button></div>`}</section>`;
  const reminders = document.createElement("section");
  $("#view .memory-page").append(reminders);
  void import("./reminders").then((m) => m.mountReminders(reminders));
  $("#add-memory").onclick = () => editMemory();
  $("#empty-memory-add")?.addEventListener("click", () => editMemory());
  document
    .querySelectorAll<HTMLButtonElement>("[data-edit-memory]")
    .forEach(
      (b) =>
        (b.onclick = () =>
          editMemory(memories.find((m) => m.id === b.dataset.editMemory))),
    );
  document
    .querySelectorAll<HTMLButtonElement>("[data-delete-memory]")
    .forEach(
      (b) => (b.onclick = () => void deleteMemory(b.dataset.deleteMemory!)),
    );
}
function editMemory(memory?: Memory) {
  const dialog = openModal(
    `<h2>${memory ? "重新写下这件事" : "一件想让她记住的事"}</h2>${filigree()}<p class="dialog-lede">喜欢的、在意的、不想被忘记的，都可以写在这里。</p><form id="memory-form"><label>想让她记住的事<textarea name="content" rows="5" required maxlength="10000" placeholder="比如：下雨天喜欢听钢琴曲。">${esc(memory?.content || "")}</textarea></label><button class="primary">收进记忆</button></form>`,
  );
  $("#memory-form").onsubmit = async (e) => {
    e.preventDefault();
    const content = String(
      new FormData(e.target as HTMLFormElement).get("content"),
    ).trim();
    if (!content) return;
    try {
      await api(
        memory ? `/memories/${memory.id}` : "/memories",
        { content },
        memory ? "PATCH" : "POST",
      );
      dialog.close();
      await loadMemories();
      toast(memory ? "改好了。我会记住新的样子。" : "嗯，我记住了。", true);
    } catch (error) {
      report(error);
    }
  };
}
async function deleteMemory(id: string) {
  try {
    await api(`/memories/${id}`, undefined, "DELETE");
    await loadMemories();
    toast("这件事先放进主机回收站了，想找回时还在。");
  } catch (error) {
    report(error);
  }
}
async function updateSettings(changes: Partial<Settings>) {
  const old = settings;
  try {
    if (credentials().token)
      settings = await api<Settings>("/settings", changes, "PATCH");
    else settings = { ...settings, ...changes };
    await save(cacheKey("settings"), settings);
    applyTheme();
    if (page === "host") renderHost();
    if (page === "hub") {
      const art = document.querySelector(".arch-image");
      if (art) art.setAttribute("aria-label", isDay() ? "午后，祥子坐在窗边" : "夜里，祥子坐在亮着灯的窗边");
    }
    if (page === "chat") renderMessageList();
  } catch (error) {
    settings = old;
    report(error);
  }
}

async function loadArtifacts() {
  try {
    artifacts = (await api<{ artifacts: Artifact[] }>("/artifacts")).artifacts;
    await save(cacheKey("artifacts"), artifacts);
  } catch (error) {
    artifacts = await cached(cacheKey("artifacts"), []);
    if (credentials().token) report(error);
  }
  if (page === "vault") renderVault();
}
function renderVault() {
  $("#view").innerHTML =
    `<section class="page vault-page">${pageHead("珍藏", "纸页、原音和画面，都替你收着。", `<button class="text-button" id="export">${icon("download", 17)}导出</button><button class="primary" id="upload-file">${icon("plus", 17)}收进文件</button>`, "Treasures")}<div id="upload-status"></div><div class="tabs" role="tablist"><button class="tab selected" role="tab" data-type="all">全部</button><button class="tab" role="tab" data-type="image">画面</button><button class="tab" role="tab" data-type="video">影像</button><button class="tab" role="tab" data-type="audio">原音</button><button class="tab" role="tab" data-type="document">纸页</button></div><div id="artifact-grid" class="artifact-grid"></div></section>`;
  $("#upload-file").onclick = () =>
    ($("#file-input") as HTMLInputElement).click();
  $("#export").onclick = () => void exportAll();
  document.querySelectorAll<HTMLButtonElement>("[data-type]").forEach(
    (b) =>
      (b.onclick = () => {
        document
          .querySelectorAll("[data-type]")
          .forEach((x) => x.classList.remove("selected"));
        b.classList.add("selected");
        renderArtifactGrid(b.dataset.type!);
      }),
  );
  renderArtifactGrid("all");
}
function artifactVisual(artifact: Artifact) {
  if (artifact.mime.startsWith("image/")) return icon("sparkle", 28);
  const name = artifact.mime.startsWith("audio/")
    ? "microphone"
    : /\.(zip|7z|gz|tar|rar)$/i.test(artifact.name)
      ? "archive"
      : /\.(py|ts|js|rs|go|java|cpp|h|css|html)$/i.test(artifact.name)
        ? "code"
        : "document";
  return `<img class="artifact-icon" src="/artwork/icons/${name}.png" alt="">`;
}
function renderArtifactGrid(type: string) {
  const filtered = artifacts.filter(
    (a) =>
      type === "all" ||
      (type === "document"
        ? !/^(image|video|audio)\//.test(a.mime)
        : a.mime.startsWith(`${type}/`)),
  );
  $("#artifact-grid").innerHTML = filtered.length
    ? filtered
        .map(
          (a) =>
            `<button class="artifact-card" data-open="${esc(a.id)}"><span class="artifact-visual" ${a.mime.startsWith("image/") ? `data-thumb="${esc(a.id)}"` : ""}>${artifactVisual(a)}</span><strong>${esc(a.name)}</strong><small>${bytes(a.size)} · ${esc(a.mime.split("/").at(-1))}</small></button>`,
        )
        .join("")
    : `<div class="empty"><h2>这里还空着。</h2><p>想留下的纸页、原音和画面，都可以交给我。</p></div>`;
  document
    .querySelectorAll<HTMLButtonElement>("[data-open]")
    .forEach((b) => (b.onclick = () => void openArtifact(b.dataset.open!)));
  loadImagePreviews($("#artifact-grid"));
}
function renderAttachments() {
  const el = $("#attachments");
  if (!el) return;
  refreshSendButton();
  el.innerHTML = selectedAttachments
    .map(
      (a) =>
        `<span class="file-chip">${icon("clip", 14)}${esc(a.name)}${a.mime.startsWith("audio/") ? `<button data-transcribe="${esc(a.id)}">转写</button>` : ""}<button data-remove-attachment="${esc(a.id)}" aria-label="取消附带 ${esc(a.name)}">${icon("close", 13)}</button></span>`,
    )
    .join("");
  el.querySelectorAll<HTMLButtonElement>("[data-transcribe]").forEach(
    (b) =>
      (b.onclick = () => {
        const a = selectedAttachments.find(
          (a) => a.id === b.dataset.transcribe,
        );
        if (a)
          void import("./speech-ui")
            .then((m) => m.openSpeech(a, insertTranscript))
            .catch(report);
      }),
  );
  el.querySelectorAll<HTMLButtonElement>("[data-remove-attachment]").forEach(
    (b) =>
      (b.onclick = () => {
        selectedAttachments = selectedAttachments.filter(
          (a) => a.id !== b.dataset.removeAttachment,
        );
        if (conversation)
          void save(
            cacheKey(`attachments:${conversation.id}`),
            selectedAttachments,
          );
        renderAttachments();
      }),
  );
}
async function insertTranscript(text: string) {
  if (page !== "chat") {
    if (conversation) await openConversation(conversation.id);
    else await newChat();
  }
  const draft = $("#draft") as HTMLTextAreaElement;
  if (draft) {
    draft.value += (draft.value ? "\n\n" : "") + text;
    draft.dispatchEvent(new Event("input"));
    draft.focus();
  }
}
async function hashFile(file: File, onProgress: (fraction: number) => void) {
  const worker = new Worker(new URL("./hash-worker.ts", import.meta.url), {
    type: "module",
  });
  return new Promise<string>((resolve, reject) => {
    worker.onmessage = (e) => {
      if (e.data.hash) {
        worker.terminate();
        resolve(e.data.hash);
      } else if (e.data.error) {
        worker.terminate();
        reject(new Error(e.data.error));
      } else onProgress(e.data.total ? e.data.progress / e.data.total : 1);
    };
    worker.onerror = (e) => {
      worker.terminate();
      reject(new Error(e.message));
    };
    worker.postMessage(file);
  });
}
function uploadStatus(text: string, progress?: number) {
  const element = $("#upload-status");
  if (!element) return;
  if (!text) {
    element.innerHTML = "";
    return;
  }
  element.innerHTML = `<div class="upload-progress"><span>${esc(text)}</span>${progress !== undefined ? `<progress max="1" value="${progress}"></progress>` : ""}${uploadBusy ? '<button id="pause-upload" class="text-button">暂停</button>' : ""}</div>`;
  $("#pause-upload")?.addEventListener("click", () => {
    uploadAbort = true;
  });
}
async function upload(file: File) {
  if (uploadBusy) {
    toast("先等这一份文件收好。");
    return;
  }
  if (!credentials().token) {
    pairing();
    return;
  }
  uploadBusy = true;
  uploadAbort = false;
  const attachTo = page === "chat" ? conversation?.id : undefined;
  try {
    uploadStatus(`正在核对「${file.name}」`, 0);
    const hash = await hashFile(file, (p) =>
      uploadStatus(`核对文件 · ${file.name}`, p),
    );
    if (uploadAbort) throw new Error("已暂停。再次选择同一文件便可续传。");
    const opened = await api<{
      id: string;
      offset: number;
      complete: boolean;
      artifact?: Artifact;
    }>("/uploads", {
      name: file.name,
      size: file.size,
      sha256: hash,
      mime: file.type || "application/octet-stream",
    });
    let artifact = opened.artifact;
    if (!opened.complete) {
      let offset = opened.offset;
      while (offset < file.size) {
        if (uploadAbort) throw new Error("已暂停。再次选择同一文件便可续传。");
        const chunk = file.slice(
          offset,
          Math.min(file.size, offset + 4 * 1024 * 1024),
        );
        const result = await (
          await request(`/uploads/${opened.id}?offset=${offset}`, {
            method: "PUT",
            body: isAndroidApp()
              ? new File([chunk], file.name, { type: "application/octet-stream" })
              : chunk,
            headers: { "Content-Type": "application/octet-stream" },
          })
        ).json();
        offset = result.offset;
        uploadStatus(`收好文件 · ${file.name}`, offset / file.size);
      }
      artifact = await api<Artifact>(`/uploads/${opened.id}/complete`, {});
    }
    if (artifact) {
      artifacts = [artifact, ...artifacts.filter((a) => a.id !== artifact!.id)];
      if (attachTo) {
        const attached = await cached<Artifact[]>(
          cacheKey(`attachments:${attachTo}`),
          [],
        );
        const next = [
          ...attached.filter((a) => a.id !== artifact!.id),
          artifact,
        ];
        await save(cacheKey(`attachments:${attachTo}`), next);
        if (page === "chat" && conversation?.id === attachTo) {
          selectedAttachments = next;
          renderAttachments();
        }
      }
      if (page === "vault") renderArtifactGrid("all");
      await save(cacheKey("artifacts"), artifacts);
    }
    uploadBusy = false;
    uploadStatus("");
    return artifact;
  } catch (error) {
    uploadBusy = false;
    uploadStatus(
      error instanceof Error
        ? error.message
        : "没有传完。再次选择同一文件可以续传。",
    );
  } finally {
    uploadBusy = false;
  }
}
async function storeGeneratedFile(file: File): Promise<void> {
  const artifact = await upload(file);
  if (!artifact) throw new Error("这份手稿还没有收进琴房，请稍后再试。");
}
function downloadBlob(blob: Blob, name: string) {
  if(isAndroidApp()){void saveAndroidBlob(blob,name).catch(report);return;}
  const url = URL.createObjectURL(blob);
  const link = document.createElement("a");
  link.href = url;
  link.download = name;
  link.click();
  setTimeout(() => URL.revokeObjectURL(url), 60000);
}
async function openArtifact(id: string, seconds = 0) {
  try {
    let artifact = artifacts.find((a) => a.id === id);
    if (!artifact) {
      const result = await api<{artifacts: Artifact[]}>("/artifacts");
      artifacts = result.artifacts;
      artifact = artifacts.find((a) => a.id === id);
    }
    if (!artifact) throw new Error("这份原件暂时没有找到。");
    const session = await api<{url: string; expires_at: number}>(`/artifacts/${id}/media-session`, {});
    const mime = artifact.mime, url = apiAddress(session.url), name = artifact.name;
    const isDocument = documentPreview(name, mime, artifact.size);
    const isWorkbook = /\.xlsx$/i.test(name) && artifact.size <= 64 * 1024 ** 2;
    const isArchive = /\.zip$/i.test(name);
    const preview =
      mime === "application/pdf"
        ? '<div id="pdf-content"></div>'
        : mime.startsWith("image/")
          ? `<img class="media-preview" src="${url}" alt="${esc(name)}">`
          : mime.startsWith("video/")
            ? `<video class="media-preview" src="${url}" preload="metadata" controls playsinline></video>`
            : mime.startsWith("audio/")
              ? `<audio src="${url}" preload="metadata" controls></audio>`
              : isDocument || isWorkbook || isArchive ? '<div id="artifact-document" class="artifact-document"></div>'
              : '<div class="file-preview">' + artifactVisual(artifact) + "</div>";
    const dialog = openModal(
      `<h2>${esc(name)}</h2>${preview}<div class="media-actions"><a class="primary" href="${url}?download=1" download="${esc(name)}">${icon("download", 18)}保存文件</a>${mime.startsWith("audio/") ? `<button class="text-button" id="transcribe-artifact">${icon("mic", 15)}原音手稿</button>` : ""}${mime.startsWith("image/") ? `<button class="text-button" id="edit-artifact">${icon("palette", 15)}画板标注</button>` : ""}${conversation ? `<button class="text-button" id="pin-artifact">${icon("pin", 15)}钉在当前乐章</button><button class="text-button" id="ask-artifact">${icon("chat", 15)}围绕它继续问</button>` : ""}</div>`,
      mime.startsWith("image/") ||
        mime.startsWith("video/") ||
        mime === "application/pdf" || isDocument || isWorkbook || isArchive,
    );
    if (isDocument || isWorkbook || isArchive || mime === "application/pdf") dialog.classList.add("artifact-dialog");
    if(isAndroidApp())dialog.querySelector<HTMLAnchorElement>('.media-actions a')!.onclick=(event)=>{
      event.preventDefault();void saveAndroidPath(`/api/artifacts/${id}/content`,name,mime).catch(report);
    };
    if ((isDocument || isWorkbook || isArchive) && !mime.startsWith("image/")) {
      const controller = new AbortController();
      dialog.addEventListener("close", () => controller.abort(), { once: true });
      const content = $("#artifact-document");
      const rendering = isWorkbook || isArchive
        ? import("./export-preview").then((m) => (isWorkbook ? m.renderWorkbook : m.renderArchive)(id, content, controller.signal))
        : renderArtifactDocument(url, name, content, controller.signal);
      void rendering
        .catch(() => {
          if (!controller.signal.aborted) {
            const content = dialog.querySelector("#artifact-document");
            if (content) content.textContent = "这一页暂时没能展开，原件仍可保存。";
          }
        });
    }
    if (mime === "application/pdf")
      void import("./pdf-reader")
        .then((m) => m.renderPdf(url, $("#pdf-content")))
        .catch(report);
    const renewal = window.setInterval(() => { void api(`/artifacts/${id}/media-session`, {}).catch(report); }, 20 * 60 * 1000);
    const player = dialog.querySelector<HTMLMediaElement>("video, audio");
    if (player && seconds > 0) player.addEventListener("loadedmetadata", () => {
      player.currentTime = Math.min(seconds, Number.isFinite(player.duration) ? player.duration : seconds);
      void player.play().catch(() => {});
    }, {once:true});
    dialog.addEventListener("close", () => {
      clearInterval(renewal);
      if (player) { player.pause(); player.removeAttribute("src"); player.load(); }
    }, {
      once: true,
    });
    $("#transcribe-artifact")?.addEventListener("click", () => {
      dialog.close();
      if (artifact)
        void import("./speech-ui")
          .then((m) => m.openSpeech(artifact, insertTranscript))
          .catch(report);
    });
    $("#edit-artifact")?.addEventListener("click", async () => {
      try {
        const blob = await (await request(`/artifacts/${id}/content`)).blob();
        const editor = await import("./media-editor");
        dialog.close();
        await editor.openMediaEditor(blob, name, storeGeneratedFile);
      } catch (error) { report(error); }
    });
    $("#pin-artifact")?.addEventListener("click", () => {
      if (conversation)
        void addPin(conversation.id, "artifact", id)
          .then(() => {
            toast("这份资料已经钉在当前乐章了。");
            void refreshPins();
          })
          .catch(report);
    });
    $("#ask-artifact")?.addEventListener("click", async () => {
      if (!artifact || !conversation) return;
      try {
        const attached = await cached<Artifact[]>(cacheKey(`attachments:${conversation.id}`), []);
        selectedAttachments = [...attached.filter(item => item.id !== artifact.id), artifact];
        await save(cacheKey(`attachments:${conversation.id}`), selectedAttachments);
        dialog.close(); page = "chat"; shell(); renderChat();
        await restoreDraft();
      } catch (error) { report(error); }
    });
  } catch (error) {
    report(error);
  }
}
async function exportAll() {
  try {
    if(isAndroidApp()){await saveAndroidPath('/api/export','HajiSaki-回忆档案.zip','application/zip');return;}
    const response = await request("/export");
    downloadBlob(await response.blob(), "HajiSaki-回忆档案.zip");
  } catch (error) {
    report(error);
  }
}
async function record() {
  if (recorder && recorder.state !== "inactive") {
    recorder.stop();
    return;
  }
  let stream: MediaStream | undefined;
  try {
    stream = await navigator.mediaDevices.getUserMedia({ audio: true });
    const mime = MediaRecorder.isTypeSupported("audio/webm;codecs=opus")
      ? "audio/webm;codecs=opus"
      : "";
    recorder = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined);
    recorded = [];
    recordStart = Date.now();
    recorder.ondataavailable = (e) => {
      if (e.data.size) recorded.push(e.data);
    };
    recorder.onstop = () => {
      refreshPortrait();
      document.querySelector(".composer")?.classList.remove("is-recording");
      refreshChatStatus();
      stream?.getTracks().forEach((t) => t.stop());
      clearInterval(recordTimer);
      if ($("#record-status")) $("#record-status").textContent = "";
      $("#record")?.classList.remove("recording");
      const blob = new Blob(recorded, {
        type: recorder?.mimeType || "audio/webm",
      });
      const extension = blob.type.includes("mp4")
        ? "m4a"
        : blob.type.includes("ogg")
          ? "ogg"
          : "webm";
      void upload(
        new File(
          [blob],
          `原音-${new Date().toISOString().replace(/[:.]/g, "-")}.${extension}`,
          { type: blob.type },
        ),
      );
    };
    recorder.start(1000);
    refreshPortrait();
    refreshChatStatus();
    $("#record").classList.add("recording");
    document.querySelector(".composer")?.classList.add("is-recording");
    recordTimer = window.setInterval(() => {
      if ($("#record-status"))
        $("#record-status").textContent =
          `在听 ${Math.floor((Date.now() - recordStart) / 60000)}:${Math.floor(
            ((Date.now() - recordStart) / 1000) % 60,
          )
            .toString()
            .padStart(2, "0")} · 再按一下结束`;
    }, 250);
  } catch {
    stream?.getTracks().forEach((track) => track.stop());
    toast("麦克风还没有打开。允许麦克风访问后，再试一次。");
  }
}

async function refreshStatus() {
  if (!credentials().token) return;
  try {
    status = await api<HostStatus>("/status");
    connected = true;
    await save(cacheKey("status"), status);
  } catch (error) {
    connected = false;
    report(error);
  }
  connectionState();
  if (page === "host") renderHost();
}
function renderHost() {
  const host = status?.host || {},
    capabilities = status?.capabilities || {};
  const readable: Record<string, string> = {
    durable_replay: "断线补回",
    max_upload_bytes: "单文件上限",
    chunk_size: "分块大小",
    native_live_view: "鸿蒙实况窗",
    host_file_mutation: "主机文件改动",
    raw_audio_model_input: "原音模型理解",
    dual_tunnel: "双通道连接",
    provider_images: "模型图像输入",
    attachment_text_excerpts: "附件内容提取",
    artifact_delivery_api: "成品交付入口",
    image_editing_api: "照片与画板批注",
    image_preview_api: "图片预览",
    agent_image_read: "模型读图",
    host_code_references: "电脑代码引用",
    historical_references: "过往乐章引用",
    composer_templates: "常用起笔",
    conversation_tones: "乐章语气",
    context_compaction: "长上下文整理",
    conversation_threads: "选文附页",
    arena_comparison: "同题对照",
    agent_delivery_tools_enabled: "模型主动交付",
    pdf_export: "PDF报告",
    xlsx_export: "Excel工作簿",
    zip_export: "原件归档盒",
    offline_client: "离线阅览",
    sqlite_wal: "聊天落盘",
    fts5: "全文检索",
    cas: "文件仓",
    resumable_uploads: "断点续传",
    live_view: "鸿蒙实况窗",
    biometric_approval: "生物识别授权",
    vpn: "原生私有通道",
    relay: "加密备用通道",
    simulation: "本地模拟器",
    export: "完整导出",
  };
  const personality = settings.personality;
  const sliders: [keyof Settings["personality"], string, string, string, boolean][] = [
    ["formality", "端庄与温柔", "端庄严谨", "卸下防备", true],
    ["detail", "说话的分寸", "点到为止", "事无巨细", false],
    ["teasing", "傲娇的程度", "坦率温和", "嘴硬心软", false],
  ];
  const paired = !!credentials().token;
  const providerLine =
    status?.provider.name === "development"
      ? "本地演练中，这一刻没有调用模型。"
      : connected && status?.provider.available
        ? status.provider.authenticated
          ? "她已经准备好，接住你的下一句话。"
          : "模型登录还待确认，记录会先替你留着。"
        : paired
          ? "灯暂时熄了。草稿和记录都在本机好好收着。"
          : "把琴房的钥匙交给我吧。";
  const chevron = icon("chevronRight", 16);
  $("#view").innerHTML =
    `<section class="page settings-page">${pageHead("设置", "", "", "Just for you")}<div class="presence-card"><img data-mood src="${art()}" alt="祥子"><div><strong><i class="${connected ? "online" : ""}"></i>${connected ? "琴房灯亮着" : "琴房的灯熄着"}</strong><p>${providerLine}</p></div><button class="text-button" id="pair-again">${connected ? "更换配对" : "连接"}</button></div><h3 class="group-title">她说话的样子</h3><div class="group">${sliders
      .map(([key, title, left, right, inverted]) => {
        const value = inverted ? 100 - personality[key] : personality[key];
        return `<label class="slider-row"><span>${title}<small data-slider-value="${key}">${value}</small></span><input type="range" min="0" max="100" value="${value}" data-personality="${key}" aria-label="${title}：从${left}到${right}"><span class="slider-ends"><span>${left}</span><span>${right}</span></span></label>`;
      })
      .join("")}</div><h3 class="group-title">光线</h3><div class="group"><div class="group-pad"><div class="segmented" role="group" aria-label="光线">${[
      ["day", "春日"],
      ["night", "月下"],
      ["auto", "随昼夜"],
    ]
      .map(([value, name]) => `<button data-theme-choice="${value}" class="${settings.theme === value ? "selected" : ""}" aria-pressed="${settings.theme === value}">${name}</button>`)
      .join("")}</div></div></div><h3 class="group-title">声音</h3><div class="group"><label class="group-row"><span>琴音<small>寄出和收到回信时，响起一小段琴声</small></span><input class="switch" type="checkbox" id="sound-toggle" ${settings.sound ? "checked" : ""}></label><label class="group-row"><span>窗边雨声<small>在这台设备上，轻轻放一会儿</small></span><input class="switch" type="checkbox" id="rain-toggle" ${rainPlaying() ? "checked" : ""}></label></div><h3 class="group-title">琴房</h3><div class="group"><button class="group-row" id="reference-roots">可引用的代码目录${chevron}</button><button class="group-row" id="export-all">导出全部回忆${chevron}</button><button class="group-row" id="refresh-status">刷新琴房状态${chevron}</button>${paired ? `<button class="group-row danger" id="disconnect">收起这把钥匙</button>` : ""}</div><h3 class="group-title">琴房详情</h3><details class="group"><summary>演奏者与主机${icon("chevron", 16)}</summary><dl class="status-list"><div><dt>执行通道</dt><dd>${esc(status?.provider.name === "development" ? "本地演练" : status?.provider.name || "尚未连接")}</dd></div><div><dt>登录状态</dt><dd>${status?.provider.name === "development" ? "本地演练无需登录" : status?.provider.authenticated ? "已就绪" : "尚未确认"}</dd></div>${status?.provider.detail ? `<div><dt>当前状态</dt><dd>${esc(status.provider.detail)}</dd></div>` : ""}${Object.entries(
      host,
    )
      .filter(([, v]) => typeof v !== "object")
      .map(
        ([k, v]) =>
          `<div><dt>${esc(({ uptime_seconds: "运行秒数", database: "聊天仓", version: "版本", memory_mb: "内存 MB", proxy: "代理通道", active_runs: "正在演奏", free_bytes: "可用空间", database_bytes: "聊天仓大小", proxy_configured: "出网代理", proxy_reachable: "代理端口", proxy_egress_verified: "出网核验", binding: "默认监听", time: "主机时间" } as Record<string, string>)[k] || k)}</dt><dd>${esc(k.endsWith("_bytes") ? bytes(Number(v)) : k === "binding" ? "仅本机" : k === "proxy_configured" ? (v ? "已配置" : "尚未配置") : k === "proxy_reachable" ? (v ? "可连接" : "暂未连上") : k === "proxy_egress_verified" ? (v ? "已核验" : "尚未核验") : k === "time" ? new Date(String(v)).toLocaleString("zh-CN", { hour12: false }) : v)}</dd></div>`,
      )
      .join("")}</dl></details><details class="group details-gap"><summary>琴房设施${icon("chevron", 16)}</summary><dl class="status-list">${
      Object.keys(capabilities).length
        ? Object.entries(capabilities)
            .map(
              ([k, v]) =>
                `<div><dt>${esc(readable[k] || k)}</dt><dd class="${v === true ? "ready" : ""}">${v === true ? "已接通" : v === false ? "尚未接通" : k === "offline_client" ? "本地缓存" : k === "max_upload_bytes" || k === "chunk_size" ? bytes(Number(v)) : esc(typeof v === "object" ? JSON.stringify(v) : v)}</dd></div>`,
            )
            .join("")
        : "<div><dt>连接后查看实际能力</dt><dd>—</dd></div>"
    }</dl></details></section>`;
  $("#pair-again").onclick = () => pairing();
  $("#refresh-status").onclick = () => void refreshStatus();
  $("#reference-roots").onclick = () => void showReferenceRoots();
  $("#export-all").onclick = () => void exportAll();
  ($("#sound-toggle") as HTMLInputElement).onchange = (e) =>
    void updateSettings({ sound: (e.target as HTMLInputElement).checked });
  ($("#rain-toggle") as HTMLInputElement).onchange = async (e) => {
    const input = e.target as HTMLInputElement;
    try {
      input.checked = await toggleRain();
    } catch {
      input.checked = false;
      toast("雨声还没响起，再试一次吧。");
    }
  };
  document.querySelectorAll<HTMLInputElement>("[data-personality]").forEach(
    (input) => {
      input.oninput = () => {
        const label = document.querySelector(`[data-slider-value="${input.dataset.personality}"]`);
        if (label) label.textContent = input.value;
      };
      input.onchange = () =>
        void updateSettings({
          personality: {
            ...settings.personality,
            [input.dataset.personality!]:
              input.dataset.personality === "formality"
                ? 100 - Number(input.value)
                : Number(input.value),
          },
        });
    },
  );
  document.querySelectorAll<HTMLButtonElement>("[data-theme-choice]").forEach(
    (button) => (button.onclick = () => void updateSettings({ theme: button.dataset.themeChoice! })),
  );
  $("#disconnect")?.addEventListener("click", () => {
    void disconnectAndroid().catch(report);
    disconnect();
    connected = false;
    status = undefined;
    connectionState();
    renderHost();
  });
}
async function bootstrap() {
  await initializeAndroid(pair);
  settings = await cached(cacheKey("settings"), settings);
  applyTheme();
  if (credentials().token) {
    const results = await Promise.allSettled([
      api<Settings>("/settings"),
      api<{ models: Model[] }>("/models"),
      api<HostStatus>("/status"),
    ]);
    if (results[0].status === "fulfilled") settings = results[0].value;
    if (results[1].status === "fulfilled") {
      models = results[1].value.models;
      selectedModel = models[0]?.id || "";
    }
    if (results[2].status === "fulfilled") {
      status = results[2].value;
      connected = true;
    }
    await save(cacheKey("settings"), settings);
  }
  shell();
  render();
  await loadConversations();
}
window.addEventListener("online", () => {
  void refreshStatus();
  void retryPending();
});
window.addEventListener("offline", () => {
  connected = false;
  connectionState();
});
window.addEventListener("beforeunload", () => {
  if (recorder?.state === "recording") recorder.stop();
});
document.addEventListener("selectionchange", () => {
  if (window.getSelection()?.isCollapsed && page === "chat" && !streamFrame)
    streamFrame = requestAnimationFrame(flushStreamView);
});
document.addEventListener("visibilitychange", () => {
  if (!document.hidden) {
    void poll();
    applyTheme();
  }
});
setInterval(() => void poll(), 850);
setInterval(() => {
  if (!document.hidden) {
    if (settings.theme === "auto") applyTheme();
    refreshPortrait();
  }
}, 60000);
shell();
render();
void bootstrap().catch(report);
