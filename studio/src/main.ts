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
};
const icon = (name: string, size = 20) =>
  `<svg width="${size}" height="${size}" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="${icons[name] || icons.star}"/></svg>`;
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
  const portraits = document.querySelectorAll<HTMLImageElement>(".chat-heading .avatar, .welcome-portrait, .chat-empty img");
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
      if (matchMedia("(prefers-reduced-motion: reduce)").matches) { image.src = url; return; }
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
function bytes(value: number) {
  return value >= 1073741824
    ? `${(value / 1073741824).toFixed(2)} GB`
    : value >= 1048576
      ? `${(value / 1048576).toFixed(1)} MB`
      : value >= 1024
        ? `${(value / 1024).toFixed(1)} KB`
        : `${value} B`;
}
function toast(text: string) {
  $("#toast").textContent = text;
  $("#toast").classList.add("visible");
  window.clearTimeout(errorTimer);
  errorTimer = window.setTimeout(
    () => $("#toast").classList.remove("visible"),
    6000,
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
  const moodTitle = document.querySelector(".welcome-copy .eyebrow");
  if (moodTitle) moodTitle.textContent = theme === "day" ? "CRYCHIC · 初春琴房" : "OBLIVIONIS · 月下剧场";
  document
    .querySelector('meta[name="theme-color"]')
    ?.setAttribute("content", theme === "day" ? "#F6F7FB" : "#05070F");
}
function navButton(p: Page, name: string, glyph: string) {
  return `<button class="nav-item ${page === p || (p === "hub" && page === "chat") ? "active" : ""}" data-nav="${p}" aria-label="${name}" title="${name}">${icon(glyph, 23)}<span>${name}</span></button>`;
}
function shell() {
  $("#app").innerHTML =
    `<aside class="rail"><button class="monogram" data-nav="hub" aria-label="哈基祥首页">H<span>♮</span></button><nav>${navButton("hub", "琴房", "chat")}${navButton("memory", "记忆", "star")}${navButton("vault", "档案", "archive")}${navButton("host", "主机", "host")}</nav><button id="theme-toggle" class="nav-item" aria-label="切换日夜主题">${icon(settings.theme === "day" ? "sun" : "moon", 23)}<span>昼夜</span></button></aside><div class="workspace"><header class="topbar"><button id="home-link" class="wordmark" data-nav="hub">哈基祥 <span>HAJISAKI</span></button><div class="top-actions"><button id="connection" class="connection">${icon("host", 15)}<i class="${connected ? "online" : ""}"></i><span>${connected ? "琴房灯亮着" : "连接琴房"}</span></button><button id="new-chat" class="icon-button" aria-label="新对话">${icon("plus")}</button></div></header><main id="view"></main></div><div id="toast" role="status" aria-live="polite"></div><dialog id="modal"></dialog><input type="file" id="file-input" multiple hidden>`;
  $("#app").addEventListener("click", (e) => {
    const nav = (e.target as HTMLElement).closest<HTMLElement>("[data-nav]");
    if (nav) void navigate(nav.dataset.nav as Page);
  });
  $("#theme-toggle").onclick = () =>
    void updateSettings({
      theme: document.documentElement.dataset.theme === "day" ? "night" : "day",
    });
  $("#connection").onclick = () =>
    connected ? void navigate("host") : pairing();
  $("#new-chat").onclick = () => void newChat();
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
  const el = $("#connection");
  el.innerHTML = `${icon("host", 15)}<i class="${connected ? "online" : ""}"></i><span>${connected ? "琴房灯亮着" : "连接琴房"}</span>`;
}
function header(kicker: string, title: string, action = "") {
  return `<div class="page-heading"><div><span class="eyebrow">${kicker}</span><h1>${title}</h1></div>${action}</div>`;
}
async function navigate(next: Page) {
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
function renderHub() {
  const hour = new Date().getHours();
  const greeting =
    hour < 6
      ? "这么晚了，还没有睡呀。"
      : hour < 12
        ? "早安。今天，也一起吧。"
        : hour < 18
          ? "午后的琴房，留了你的位置。"
          : "回来了。先歇一会儿吧。";
  const list = conversations.filter(
    (c) =>
      (filter === "已归档" ? c.archived : !c.archived) &&
      (filter === "全部" || filter === "已归档" || c.group === filter) &&
      (!query ||
        `${c.title} ${c.preview || ""}`
          .toLowerCase()
          .includes(query.toLowerCase())),
  );
  $("#view").innerHTML =
    `<section class="hub page-pad"><div class="welcome"><div class="welcome-copy"><span class="eyebrow">${document.documentElement.dataset.theme === "day" ? "CRYCHIC · 初春琴房" : "OBLIVIONIS · 月下剧场"}</span><h1>${greeting
      .split("。")
      .filter(Boolean)
      .map((t) => `<span>${t}。</span>`)
      .join(
        "",
      )}</h1><p>有些话，不必整理好了才说。<br>我在听。</p><button class="primary" id="begin-chat">打开二人琴房 ${icon("arrow", 17)}</button><div class="staff" aria-hidden="true"><span>♮</span></div></div><div class="portrait-frame"><img class="welcome-portrait" src="${art()}" alt="祥子温柔地望向你"><span class="portrait-sign">Sakiko</span></div></div><div class="hub-tools"><h2>记忆长廊 <span>${conversations
      .filter((c) => !c.archived)
      .length.toString()
      .padStart(
        2,
        "0",
      )}</span></h2><label class="search">${icon("search", 17)}<input id="search" aria-label="搜索对话" placeholder="寻找一段回忆" value="${esc(query)}"></label></div><div class="tabs">${groupNames.map((g) => `<button data-group="${g}" class="${filter === g ? "selected" : ""}">${g}</button>`).join("")}</div><div class="conversation-list">${list.length ? list.map((c) => `<article class="conversation-row"><button class="conversation-open" data-id="${esc(c.id)}"><span class="conversation-mark">${icon(c.group === "研发工坊" ? "host" : c.group === "资料卷宗" ? "book" : "chat", 22)}</span><span class="conversation-text"><strong>${c.pinned ? '<span class="gold">♮</span> ' : ""}${esc(c.title)}</strong><small>${esc(previewText(c.preview || "还空着的一页，等你落笔。"))}</small></span><time>${shortDate(c.updated_at)}</time>${icon("arrow", 17)}</button><button class="row-action" data-pin="${esc(c.id)}" aria-label="${c.pinned ? "取消置顶" : "置顶"}">${icon("pin", 16)}</button><button class="row-action" data-archive="${esc(c.id)}" aria-label="${c.archived ? "恢复对话" : "归档对话"}">${icon("archive", 16)}</button></article>`).join("") : `<div class="empty-line"><span class="gold">♮</span><p>${query || filter !== "全部" ? "还没找到这一段回忆。" : "第一段回忆，从今天开始。"}</p>${query || filter !== "全部" ? '<button class="text-button" id="clear-filter">查看全部</button>' : '<button class="text-button" id="empty-new">写下第一句</button>'}</div>`}</div></section>`;
  $("#begin-chat").onclick = () => void newChat();
  $("#empty-new")?.addEventListener("click", () => void newChat());
  $("#clear-filter")?.addEventListener("click", () => {
    filter = "全部";
    query = "";
    renderHub();
  });
  $("#search").addEventListener("input", (e) => {
    const input = e.target as HTMLInputElement;
    const pos = input.selectionStart;
    query = input.value;
    renderHub();
    const replacement = $("#search") as HTMLInputElement;
    replacement.focus();
    replacement.setSelectionRange(pos, pos);
  });
  document.querySelectorAll<HTMLButtonElement>("[data-group]").forEach(
    (b) =>
      (b.onclick = () => {
        filter = b.dataset.group!;
        renderHub();
      }),
  );
  document
    .querySelectorAll<HTMLButtonElement>(".conversation-open")
    .forEach((b) => (b.onclick = () => void openConversation(b.dataset.id!)));
  document.querySelectorAll<HTMLButtonElement>("[data-pin]").forEach(
    (b) =>
      (b.onclick = () =>
        void modifyConversation(b.dataset.pin!, {
          pinned: !conversations.find((c) => c.id === b.dataset.pin)?.pinned,
        })),
  );
  document.querySelectorAll<HTMLButtonElement>("[data-archive]").forEach(
    (b) =>
      (b.onclick = () =>
        void modifyConversation(b.dataset.archive!, {
          archived: !conversations.find((c) => c.id === b.dataset.archive)
            ?.archived,
        })),
  );
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
  if (page === "hub") renderHub();
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
function transparencyOptions() {
  return ["companion", "balanced", "studio"]
    .map(
      (v, i) =>
        `<option value="${v}" ${settings.transparency === v ? "selected" : ""}>${["伴侣纯净", "智能平衡", "全透视"][i]}</option>`,
    )
    .join("");
}
function renderChat() {
  if (!conversation) {
    page = "hub";
    renderHub();
    return;
  }
  $("#view").innerHTML =
    `<section class="chat-stage"><div class="chat-heading"><button class="icon-button" id="chat-back" aria-label="回到记忆长廊">${icon("back")}</button><img class="avatar" src="${art(activeRun ? "thinking_deep" : "idle_gentle")}" alt="祥子"><div class="chat-name"><button id="rename-chat">${esc(conversation.title)}</button><small>二人琴房</small></div><select id="transparency" aria-label="对话透视度">${transparencyOptions()}</select><button class="icon-button" id="chat-menu" aria-label="对话设置">${icon("menu", 19)}</button></div><div class="chat-pins" id="chat-pins" hidden></div><div class="messages" id="messages"></div><button id="jump-bottom" class="jump-bottom" hidden>回到最新 ${icon("send", 15)}</button><div class="composer-wrap"><div id="upload-status"></div><div class="composer"><div class="composer-options"><button id="model" class="model-trigger" aria-label="选择模型" aria-haspopup="dialog">${esc(selectedFamily(models,selectedModel)?.name || "等待连接模型")} <span aria-hidden="true">⌄</span></button><span class="small-dot">·</span><button id="effort" class="model-trigger effort-trigger" aria-label="思考强度" aria-haspopup="dialog"></button><span class="composer-spacer"></span><span id="draft-state"></span></div><div id="attachments" class="attachments"></div><textarea id="draft" aria-label="消息" placeholder="慢慢说，我听着呢…" rows="2"></textarea><div class="composer-bottom"><div class="composer-tools"><button id="attach" class="icon-button" aria-label="添加文件">${icon("plus", 23)}</button><button id="record" class="icon-button" aria-label="录制原音">${icon("mic", 21)}</button><button id="quote" class="text-button" title="引用选中的回复">引用</button><button id="draw" class="text-button">画板</button><span id="record-status"></span></div><button id="send" class="send-button" aria-label="${activeRun ? "停止回答" : "发送消息"}">${icon(activeRun ? "stop" : "send", 20)}</button></div></div><p class="composer-foot">${status?.provider.name === "development" ? "模拟演奏 · 当前回复来自本地模拟器" : "只属于我们的这一页。"}</p></div></section>`;
  $("#chat-back").onclick = () => void navigate("hub");
  $("#rename-chat").onclick = () => editConversation();
  $("#chat-menu").onclick = () => editConversation();
  ($("#transparency") as HTMLSelectElement).onchange = (e) =>
    void updateSettings({
      transparency: (e.target as HTMLSelectElement).value,
    });
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
    void save(cacheKey(`draft:${conversation!.id}`), value)
      .then(() => {
        if (draft.isConnected && draft.value === value)
          $("#draft-state").textContent = value ? "草稿留在此处" : "";
      })
      .catch(() => {
        if (draft.isConnected) $("#draft-state").textContent = "草稿尚未保存";
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
  const dialog=openModal(`<div class="model-sheet-heading"><span class="eyebrow">琴房的演奏者</span><h2>选择模型</h2><p>思考强度在输入框旁单独调整</p></div><div class="model-sheet-list">${families.map(family=>`<button class="model-choice ${family.id===current?.id?'selected':''}" data-family="${esc(family.id)}"><span><strong>${esc(family.name)}</strong><small>${family.levels.map(level=>strengthName(level.effort)).join(' · ')}</small></span><span class="model-choice-mark">${family.id===current?.id?icon('check',18):''}</span></button>`).join('')}</div>`);
  dialog.classList.add('model-sheet');
  for(const button of dialog.querySelectorAll<HTMLButtonElement>('[data-family]'))button.onclick=()=>{
    const family=families.find(item=>item.id===button.dataset.family)!;
    const level=family.levels.find(item=>item.effort===effort) || family.levels.find(item=>item.effort==='medium') || family.levels[0];
    if(level){selectedModel=level.wireId;effort=level.effort;}
    $('#model').innerHTML=`${esc(family.name)} <span aria-hidden="true">⌄</span>`;
    refreshEffort();dialog.close();
  };
}
function showStrengthPicker() {
  const family=selectedFamily(models,selectedModel);
  if(!family)return;
  const dialog=openModal(`<div class="model-sheet-heading"><span class="eyebrow">${esc(family.name)}</span><h2>思考强度</h2></div><div class="strength-options">${family.levels.map(level=>`<button data-strength="${esc(level.effort)}" class="${level.effort===effort?'selected':''}">${esc(strengthName(level.effort))}</button>`).join('')}</div>`);
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
  if(button){button.innerHTML=`${esc(strengthName(effort) || '默认')} <span aria-hidden="true">⌄</span>`;button.disabled=levels.length<=1;}
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
    return `<button class="image-bubble" data-artifact="${esc(a.id)}"><span data-thumb="${esc(a.id)}">${icon("moon", 30)}</span><small>${esc(a.name)}</small></button>`;
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
  const rows: { time: number; html: string }[] = messages.map((m) => ({
    time: new Date(
      events.find(
        (e) => e.kind === "reply_delta" && e.payload.message_id === m.id,
      )?.created_at || m.created_at,
    ).getTime(),
    html: `<article class="message ${m.role === "user" ? "from-user" : "from-sakiko"}" data-message="${esc(m.id)}"><div class="message-byline">${m.role === "user" ? "你" : "祥子"}<span>${m.status === "interrupted" || m.status === "stopped" ? "· 已停在这里" : m.status === "failed" ? "· 尚未完成" : ""}</span></div><div class="message-content">${m.role === "user" ? `<div class="user-text">${esc(m.content)}</div>` : markdown(m.content || "…", { taskStates: taskStates[m.id], artifacts: m.attachments.filter((a): a is Artifact => typeof a !== "string") })}</div>${visibleFiles.get(m.id)?.length ? `<div class="message-files">${visibleFiles.get(m.id)!.map(artifactButton).join("")}</div>` : ""}<div class="message-actions"><button data-pin-message="${esc(m.id)}" aria-label="钉住这段话">${icon("pin", 15)}</button><button data-copy-message="${esc(m.id)}" aria-label="复制消息">${icon("copy", 15)}</button>${m.role !== "user" ? `<button data-read="${esc(m.id)}">${icon("book", 15)}静谧阅读</button><button data-fork="${esc(m.id)}">${icon("fork", 15)}分支</button>${settings.transparency === "studio" ? `<button data-raw-message="${esc(m.id)}">原始记录</button>` : ""}` : ""}</div></article>`,
  }));
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
        : `<details class="event-pill ${l1 ? "thought" : ""}"><summary>${icon(l1 ? "moon" : "check", 15)}${esc(text.slice(0, 150))}</summary><div>${esc(text)}${typeof payload.diagnostic_id === "string" ? `<button class="text-button" data-diagnostic="${esc(payload.diagnostic_id)}">打开主机记录</button>` : ""}${settings.transparency === "studio" ? `<pre>${esc(JSON.stringify(payload, null, 2))}</pre>` : ""}</div></details>`,
    });
  }
  for (const event of events.filter((e) => e.kind === "narration"))
    rows.push({
      time: new Date(event.created_at).getTime(),
      html: `<div class="narration">${esc(event.payload.text)}</div>`,
    });
  rows.sort((a, b) => a.time - b.time);
  const flow = document.createElement("div");
  flow.className = "message-flow";
  flow.style.height = !rows.length && !pending ? "100%" : "auto";
  flow.innerHTML = rows.length
    ? rows.map((r) => r.html).join("")
    : pending
      ? ""
      : `<div class="chat-empty"><img src="${art()}" alt="祥子"><span class="eyebrow">A LITTLE ROOM FOR US</span><h2>这一刻，只听你说。</h2><div class="staff" aria-hidden="true"><span>♮</span></div></div>`;
  list.replaceChildren(flow);
  if (pending)
    flow.insertAdjacentHTML(
      "beforeend",
      `<article class="message from-user queued"><div class="message-byline">你 · 等待送达</div><div class="user-text">${esc(pending.content)}</div><button id="retry-send" class="text-button">重新送出</button></article>`,
    );
  if (activeRun && !stopping)
    flow.insertAdjacentHTML(
      "beforeend",
      '<div class="playing"><span class="moon-progress"></span><span>正在续写这一页…</span></div>',
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
            if (checked) portraitCue("proud_smug");
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
  if ($("#send")) {
    $("#send").innerHTML = icon(activeRun ? "stop" : "send", 20);
    $("#send").setAttribute("aria-label", activeRun ? "停止回答" : "发送消息");
  }
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
    `<span class="eyebrow">THE KEY TO OUR ROOM</span><h2>把琴房连起来</h2>${local ? '<button class="primary local-pair" id="local-pair">连接这台电脑</button><details class="manual-pair"><summary>使用配对密钥</summary>' : ""}<form id="pair-form"><label>设备名称<input name="device" value="${esc(current.device)}" autocomplete="off" required></label><label>配对密钥<input name="token" type="password" autocomplete="off" required></label><p class="field-note">密钥只保留在当前浏览器会话。</p><button class="primary" type="submit">连接琴房 ${icon("key", 17)}</button></form>${local ? "</details>" : ""}<p id="pair-error" class="form-error" role="alert"></p>`,
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
function editConversation() {
  if (!conversation) return;
  const c = conversation;
  const dialog = openModal(
    `<h2>这一页的名字</h2><form id="edit-conversation"><label>对话名称<input name="title" value="${esc(c.title)}" required maxlength="120"></label><label>归属<select name="group">${groupNames
      .slice(1, 4)
      .map((g) => `<option ${c.group === g ? "selected" : ""}>${g}</option>`)
      .join("")}</select></label><button class="primary">保存</button></form>`,
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
      const draft = ($("#draft") as HTMLTextAreaElement).value;
      renderChat();
      ($("#draft") as HTMLTextAreaElement).value = draft;
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
    `<div class="reading-heading"><span class="eyebrow">静谧手稿</span><h2>${esc(conversation?.title || "这一页")}</h2></div><article class="reading-content">${markdown(message.content, { taskStates: taskStates[message.id], readonlyTasks: true })}</article><div class="reading-footer"><span>♮ 祥子</span><button id="copy-reading" class="text-button">复制原文</button><button id="save-reading" class="text-button">保存 Markdown</button><button id="export-knowledge" class="text-button">手账长图</button></div>`,
    true,
  );
  void enhance(dialog).catch(report);
  $("#copy-reading").onclick = () =>
    void navigator.clipboard
      .writeText(message.content)
      .then(() => toast("手稿已经收好。"))
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
  if (page === "memory") renderMemory();
}
function renderMemory() {
  $("#view").innerHTML =
    `<section class="page-pad memory-page">${header("CONSTELLATION · 记忆星空", "那些关于你的事", `<button class="primary" id="add-memory">${icon("plus", 18)}添一枚音符</button>`)}<div class="memory-layout"><div class="memory-cards">${memories.length ? memories.map((m, i) => `<article class="memory-card"><span class="memory-number">${(i + 1).toString().padStart(2, "0")} <span>♮</span></span><p>${esc(m.content)}</p><footer><time>${shortDate(m.updated_at)}</time><div><button class="icon-button" data-edit-memory="${esc(m.id)}" aria-label="修改记忆">${icon("edit", 17)}</button><button class="icon-button" data-delete-memory="${esc(m.id)}" aria-label="移除记忆">${icon("trash", 17)}</button></div></footer></article>`).join("") : '<div class="empty-memory"><div class="constellation" aria-hidden="true">✦<span>✧</span>✦<i>✧</i></div><h2>慢慢认识你，<br>也把选择留给你。</h2><p>想让她记住的事，由你亲手写下。</p></div>'}</div><aside class="tuning"><span class="eyebrow">SOUL TUNING</span><h2>灵魂调律</h2><img class="tuning-portrait" src="${art("idle_gentle")}" alt="祥子">${[
      ["formality", "端庄严谨", "卸防温柔"],
      ["detail", "克制留白", "事无巨细"],
      ["teasing", "傲娇轻嗔", ""],
    ]
      .map(
        ([key, left, right]) =>
          `<label class="tuning-slider"><span>${left}<small>${right || `${settings.personality[key as keyof Settings["personality"]]}%`}</small></span><input type="range" min="0" max="100" value="${key === "formality" ? 100 - settings.personality.formality : settings.personality[key as keyof Settings["personality"]]}" data-personality="${key}" aria-label="${left}"></label>`,
      )
      .join(
        "",
      )}<div class="theme-choice"><label for="theme-select">琴房光线</label><select id="theme-select">${[
      ["night", "月下剧场"],
      ["day", "初春琴房"],
      ["auto", "随昼夜变化"],
    ]
      .map(
        ([v, n]) =>
          `<option value="${v}" ${settings.theme === v ? "selected" : ""}>${n}</option>`,
      )
      .join(
        "",
      )}</select></div><label class="sound-choice"><span>琴音微仪式</span><input type="checkbox" id="sound-toggle" ${settings.sound ? "checked" : ""}></label><button class="text-button rain-toggle" id="rain-toggle">${rainPlaying() ? "暂停雨声" : "听一会儿雨"}</button></aside></div></section>`;
  const reminders = document.createElement("section");
  $("#view .memory-page").append(reminders);
  void import("./reminders").then((m) => m.mountReminders(reminders));
  ($("#sound-toggle") as HTMLInputElement).onchange = (e) =>
    void updateSettings({ sound: (e.target as HTMLInputElement).checked });
  $("#rain-toggle").onclick = async () => {
    try {
      $("#rain-toggle").textContent = (await toggleRain())
        ? "暂停雨声"
        : "听一会儿雨";
    } catch {
      toast("雨声还没响起，再按一次试试。");
    }
  };
  $("#add-memory").onclick = () => editMemory();
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
  document.querySelectorAll<HTMLInputElement>("[data-personality]").forEach(
    (input) =>
      (input.onchange = () =>
        void updateSettings({
          personality: {
            ...settings.personality,
            [input.dataset.personality!]:
              input.dataset.personality === "formality"
                ? 100 - Number(input.value)
                : Number(input.value),
          },
        })),
  );
  ($("#theme-select") as HTMLSelectElement).onchange = (e) =>
    void updateSettings({ theme: (e.target as HTMLSelectElement).value });
}
function editMemory(memory?: Memory) {
  const dialog = openModal(
    `<h2>${memory ? "重新写这一枚音符" : "一件想让她记住的事"}</h2><form id="memory-form"><label>记忆<textarea name="content" rows="5" required maxlength="10000">${esc(memory?.content || "")}</textarea></label><button class="primary">收进记忆</button></form>`,
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
    } catch (error) {
      report(error);
    }
  };
}
async function deleteMemory(id: string) {
  try {
    await api(`/memories/${id}`, undefined, "DELETE");
    await loadMemories();
    toast("这一枚音符已移到主机回收站。");
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
    if (page === "memory") renderMemory();
    if (page === "chat") renderMessageList();
    $("#theme-toggle").innerHTML =
      `${icon(document.documentElement.dataset.theme === "day" ? "sun" : "moon", 23)}<span>昼夜</span>`;
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
    `<section class="page-pad vault-page">${header("ARCHIVE · 档案保险箱", "收好的每一份心意", `<div class="heading-actions"><button class="text-button" id="export">${icon("download", 17)}导出全部</button><button class="primary" id="upload-file">${icon("plus", 18)}收进文件</button></div>`)}<div id="upload-status"></div><div class="vault-tabs"><button class="selected" data-type="all">全部档案</button><button data-type="image">图片</button><button data-type="video">视频</button><button data-type="audio">原音</button><button data-type="document">文档</button></div><div id="artifact-grid" class="artifact-grid"></div></section>`;
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
  if (artifact.mime.startsWith("image/")) return icon("moon", 42);
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
    : `<div class="empty-line"><span class="gold">♮</span><p>纸页、原音、画面，都可以收在这里。</p></div>`;
  document
    .querySelectorAll<HTMLButtonElement>("[data-open]")
    .forEach((b) => (b.onclick = () => void openArtifact(b.dataset.open!)));
  loadImagePreviews($("#artifact-grid"));
}
function renderAttachments() {
  const el = $("#attachments");
  if (!el) return;
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
      `<h2>${esc(name)}</h2>${preview}<div class="media-actions"><a class="primary" href="${url}?download=1" download="${esc(name)}">${icon("download", 18)}保存文件</a>${mime.startsWith("audio/") ? '<button class="text-button" id="transcribe-artifact">原音手稿</button>' : ""}${mime.startsWith("image/") ? '<button class="text-button" id="edit-artifact">画板标注</button>' : ""}${conversation ? '<button class="text-button" id="pin-artifact">钉在当前对话</button><button class="text-button" id="ask-artifact">围绕它继续问</button>' : ""}</div>`,
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
            toast("这份资料已经钉在当前对话。");
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
    $("#record").classList.add("recording");
    recordTimer = window.setInterval(() => {
      if ($("#record-status"))
        $("#record-status").textContent =
          `原音 ${Math.floor((Date.now() - recordStart) / 60000)}:${Math.floor(
            ((Date.now() - recordStart) / 1000) % 60,
          )
            .toString()
            .padStart(2, "0")} · 再按结束`;
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
  $("#view").innerHTML =
    `<section class="page-pad host-page">${header("BACKSTAGE · 主机指挥台", "琴房的灯", `<button class="text-button" id="refresh-status">刷新状态</button>`)}<div class="host-hero"><span class="host-orb ${connected ? "connected" : ""}">${icon("host", 45)}</span><div><h2>${connected ? "主机已连接" : "等待主机连接"}</h2><p>${status?.provider.name === "development" ? "本地演练中，这一刻没有调用模型。" : status?.provider.available ? (status.provider.authenticated ? "她已准备好，接住下一句话。" : "模型登录还待确认。") : "先把琴房的钥匙交给我吧。"}</p><button class="text-button" id="pair-again">${connected ? "更换配对" : "连接琴房"} ${icon("arrow", 16)}</button></div></div><div class="host-sections"><section><h2>演奏者</h2><dl class="status-list"><div><dt>执行通道</dt><dd>${esc(status?.provider.name === "development" ? "本地演练" : status?.provider.name || "尚未连接")}</dd></div><div><dt>登录状态</dt><dd>${status?.provider.name === "development" ? "本地演练无需登录" : status?.provider.authenticated ? "已就绪" : "尚未确认"}</dd></div>${status?.provider.detail ? `<div><dt>当前状态</dt><dd>${esc(status.provider.detail)}</dd></div>` : ""}${Object.entries(
      host,
    )
      .filter(([, v]) => typeof v !== "object")
      .map(
        ([k, v]) =>
          `<div><dt>${esc(({ uptime_seconds: "运行秒数", database: "聊天仓", version: "版本", memory_mb: "内存 MB", proxy: "代理通道", active_runs: "正在演奏", free_bytes: "可用空间", database_bytes: "聊天仓大小", proxy_configured: "出网代理", proxy_reachable: "代理端口", proxy_egress_verified: "出网核验", binding: "默认监听", time: "主机时间" } as Record<string, string>)[k] || k)}</dt><dd>${esc(k.endsWith("_bytes") ? bytes(Number(v)) : k === "binding" ? "仅本机" : k === "proxy_configured" ? (v ? "已配置" : "尚未配置") : k === "proxy_reachable" ? (v ? "可连接" : "暂未连上") : k === "proxy_egress_verified" ? (v ? "已核验" : "尚未核验") : k === "time" ? new Date(String(v)).toLocaleString("zh-CN", { hour12: false }) : v)}</dd></div>`,
      )
      .join(
        "",
      )}</dl></section><section><h2>琴房设施</h2><dl class="status-list">${
      Object.keys(capabilities).length
        ? Object.entries(capabilities)
            .map(
              ([k, v]) =>
                `<div><dt>${esc(readable[k] || k)}</dt><dd class="${v === true ? "ready" : ""}">${v === true ? "已接通" : v === false ? "尚未接通" : k === "offline_client" ? "本地缓存" : k === "max_upload_bytes" || k === "chunk_size" ? bytes(Number(v)) : esc(typeof v === "object" ? JSON.stringify(v) : v)}</dd></div>`,
            )
            .join("")
        : "<div><dt>连接后查看实际能力</dt><dd>—</dd></div>"
    }</dl></section></div>${credentials().token ? '<button class="text-button disconnect" id="disconnect">收起这把钥匙</button>' : ""}</section>`;
  $("#refresh-status").onclick = () => void refreshStatus();
  const referenceButton = document.createElement("button");
  referenceButton.className = "text-button";
  referenceButton.id = "reference-roots";
  referenceButton.textContent = "可引用的代码目录";
  referenceButton.onclick = () => void showReferenceRoots();
  $(".host-sections").before(referenceButton);
  $("#pair-again").onclick = () => pairing();
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
