import MarkdownIt from "markdown-it";
import { diagramActions } from "./diagram-view";
import DOMPurify from "dompurify";
import katex from "katex";
import "katex/contrib/mhchem";
import "katex/dist/katex.min.css";
import hljs from "highlight.js/lib/core";
import python from "highlight.js/lib/languages/python";
import javascript from "highlight.js/lib/languages/javascript";
import typescript from "highlight.js/lib/languages/typescript";
import json from "highlight.js/lib/languages/json";
import bash from "highlight.js/lib/languages/bash";
import xml from "highlight.js/lib/languages/xml";
import css from "highlight.js/lib/languages/css";
import sql from "highlight.js/lib/languages/sql";
import footnotes from "markdown-it-footnote";
for (const [name, language] of Object.entries({
  python,
  javascript,
  typescript,
  json,
  bash,
  xml,
  css,
  sql,
}))
  hljs.registerLanguage(name, language);
export const escape = (value: unknown) =>
  String(value ?? "").replace(
    /[&<>"']/g,
    (c) =>
      ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" })[
        c
      ]!,
  );
const md = new MarkdownIt({
  html: false,
  linkify: true,
  breaks: true,
  highlight: (text, lang) => {
    if (lang && hljs.getLanguage(lang)) {
      try {
        return hljs.highlight(text, { language: lang }).value;
      } catch {}
    }
    return escape(text);
  },
});
// The plugin's declaration targets MarkdownIt's CJS entry; its runtime API is identical.
md.use(footnotes as unknown as (instance: MarkdownIt) => void);
md.inline.ruler.before('link', 'native_file_reference', (state, silent) => {
  if (state.src[state.pos] !== '[') return false;
  const labelEnd = state.md.helpers.parseLinkLabel(state, state.pos, false);
  if (labelEnd < 0 || state.src[labelEnd + 1] !== '(') return false;
  const destination = state.md.helpers.parseLinkDestination(state.src, labelEnd + 2, state.posMax);
  if (!destination.ok || !/^file:\/\//i.test(destination.str)) return false;
  let end = destination.pos;
  while (/\s/.test(state.src[end] || '') && end < state.posMax) end++;
  if (state.src[end] !== ')') return false;
  if (!silent) {
    const label = state.src.slice(state.pos + 1, labelEnd);
    let filename = destination.str.replace(/\\/g, '/').split('/').at(-1) || '';
    try { filename = decodeURIComponent(filename); } catch {}
    const artifact = (state.env?.artifacts as {id:string;name:string}[] | undefined)?.find(item => item.name === filename);
    const token = state.push(artifact ? 'html_inline' : 'text', '', 0);
    token.content = artifact
      ? `<button type="button" class="artifact-inline-link" data-artifact="${escape(artifact.id)}">${escape(label)}</button>`
      : label;
  }
  state.pos = end + 1;
  return true;
});
md.block.ruler.before("fence", "safe_details", (state, start, end, silent) => {
  const first = state.src
    .slice(state.bMarks[start] + state.tShift[start], state.eMarks[start])
    .trim();
  if (!/^<details(?:\s+open)?\s*>$/i.test(first)) return false;
  let next = start + 1,
    depth = 1;
  for (; next < end; next++) {
    const line = state.src.slice(state.bMarks[next], state.eMarks[next]).trim();
    if (/^<details(?:\s+open)?\s*>$/i.test(line)) depth++;
    if (/^<\/details>$/i.test(line) && --depth === 0) break;
  }
  if (silent) return true;
  let bodyStart = start + 1,
    title = "展开手稿";
  const summary = state.src
    .slice(state.bMarks[bodyStart] || 0, state.eMarks[bodyStart] || 0)
    .trim()
    .match(/^<summary>(.*?)<\/summary>$/i);
  if (summary) {
    title = summary[1];
    bodyStart++;
  }
  const open = state.push("details_open", "details", 1);
  open.attrSet("class", "prose-details");
  if (/\sopen/i.test(first)) open.attrSet("open", "");
  state.push("summary_open", "summary", 1);
  const heading = state.push("inline", "", 0);
  heading.content = title;
  heading.children = [];
  state.push("summary_close", "summary", -1);
  const body = state.src.slice(
    state.bMarks[bodyStart] || state.src.length,
    next < end ? state.bMarks[next] : state.src.length,
  );
  state.md.block.parse(body, state.md, state.env, state.tokens);
  state.push("details_close", "details", -1);
  state.line = next < end ? next + 1 : end;
  return true;
});
md.core.ruler.after("inline", "safe_interactions", (state) => {
  let listDepth = 0,
    taskIndex = 0;
  for (let i = 0; i < state.tokens.length; i++) {
    const token = state.tokens[i];
    if (token.type === "list_item_open") listDepth++;
    if (token.type === "list_item_close") listDepth--;
    if (token.type === "blockquote_open") {
      const inline = state.tokens[i + 2],
        match =
          inline?.type === "inline"
            ? inline.content.match(
                /^\[!(NOTE|TIP|IMPORTANT|WARNING|CAUTION)\]\s*/,
              )
            : null;
      if (match) {
        token.attrJoin("class", "github-alert alert-" + match[1].toLowerCase());
        token.meta = { alert: match[1] };
        inline.content = inline.content.slice(match[0].length);
        inline.children = [];
        state.md.inline.parse(
          inline.content,
          state.md,
          state.env,
          inline.children,
        );
      }
    }
    if (token.type === "inline" && listDepth > 0) {
      const task = token.content.match(/^\[([ xX])\]\s+/);
      if (task) {
        token.content = token.content.slice(task[0].length);
        token.children = [];
        state.md.inline.parse(
          token.content,
          state.md,
          state.env,
          token.children,
        );
        const box = new state.Token("task_checkbox", "input", 0);
        box.meta = {
          index: taskIndex++,
          checked: task[1].toLowerCase() === "x",
          label: token.content,
        };
        token.children.unshift(box);
      }
    }
  }
});
md.renderer.rules.blockquote_open = (tokens, index, options, _env, self) => {
  const token = tokens[index],
    title = (
      {
        NOTE: "笔记",
        TIP: "小提示",
        IMPORTANT: "请留意",
        WARNING: "请当心",
        CAUTION: "请谨慎",
      } as Record<string, string>
    )[token.meta?.alert];
  return (
    self.renderToken(tokens, index, options) +
    (title ? '<div class="alert-title">' + title + "</div>" : "")
  );
};
md.renderer.rules.task_checkbox = (tokens, index, _options, env) => {
  const task = tokens[index].meta,
    enabled = !!env?.taskStates && !env?.readonlyTasks;
  const checked = env?.taskStates?.[String(task.index)] ?? task.checked;
  return (
    '<input class="task-checkbox" type="checkbox" data-task-index="' +
    task.index +
    '" aria-label="' +
    escape(task.label) +
    '" ' +
    (checked ? "checked " : "") +
    (enabled ? "" : 'disabled title="只读待办"') +
    ">"
  );
};

md.inline.ruler.after("escape", "math", (state, silent) => {
  const p = state.pos;
  if (
    state.src[p] !== "$" ||
    state.src[p + 1] === "$" ||
    /\s/.test(state.src[p + 1] || "")
  )
    return false;
  let end = p + 1;
  while ((end = state.src.indexOf("$", end)) !== -1) {
    if (state.src[end - 1] !== "\\") break;
    end++;
  }
  if (
    end < 0 ||
    /\s/.test(state.src[end - 1]) ||
    /\d/.test(state.src[end + 1] || "")
  )
    return false;
  if (!silent) {
    const t = state.push("math_inline", "math", 0);
    t.content = state.src.slice(p + 1, end);
  }
  state.pos = end + 1;
  return true;
});
md.block.ruler.before("fence", "math_block", (state, start, end, silent) => {
  const first = state.src.slice(
    state.bMarks[start] + state.tShift[start],
    state.eMarks[start],
  );
  if (!first.startsWith("$$")) return false;
  let content = first.slice(2);
  let next = start;
  if (content.trimEnd().endsWith("$$"))
    content = content.trimEnd().slice(0, -2);
  else {
    let found = false;
    for (next = start + 1; next < end; next++) {
      const line = state.src.slice(state.bMarks[next], state.eMarks[next]);
      if (line.trimEnd().endsWith("$$")) {
        content += "\n" + line.trimEnd().slice(0, -2);
        found = true;
        break;
      }
      content += "\n" + line;
    }
    if (!found) return false;
  }
  if (silent) return true;
  const token = state.push("math_block", "div", 0);
  token.content = content;
  token.map = [start, next + 1];
  state.line = next + 1;
  return true;
});
const math = (text: string, displayMode = false) =>
  katex.renderToString(text, {
    displayMode,
    throwOnError: false,
    trust: false,
    strict: "ignore",
    maxExpand: 1000,
  });
md.renderer.rules.math_inline = (tokens, i) => math(tokens[i].content);
md.renderer.rules.math_block = (tokens, i) =>
  `<div class="math-scroll">${math(tokens[i].content, true)}</div>`;
const fence = md.renderer.rules.fence!;
md.renderer.rules.fence = (tokens, i, options, env, self) => {
  const token = tokens[i],
    lang = token.info.trim();
  if (["mermaid", "echarts", "abc"].includes(lang))
    return `<div class="${lang}-block" data-source="${encodeURIComponent(token.content)}"><span class="render-pending">正在展开${lang === "abc" ? "乐谱" : "图谱"}…</span></div>`;
  const code = fence(tokens, i, options, env, self);
  return `<div class="code-block"><div class="code-label"><span>${escape(token.info.trim() || "文本")}</span><button type="button" data-copy-code>复制</button></div>${token.content.split("\n").length > 30 ? `<details><summary>展开 ${token.content.split("\n").length} 行代码</summary>${code}</details>` : code}</div>`;
};
md.renderer.rules.table_open = () => '<div class="table-scroll"><table>';
md.renderer.rules.table_close = () => "</table></div>";
const defaultLink =
  md.renderer.rules.link_open || ((t, i, o, e, s) => s.renderToken(t, i, o));
md.renderer.rules.link_open = (tokens, i, o, e, s) => {
  tokens[i].attrSet("target", "_blank");
  tokens[i].attrSet("rel", "noopener noreferrer");
  return defaultLink(tokens, i, o, e, s);
};
export function markdown(
  text: string,
  options?: { taskStates?: Record<string, boolean>; readonlyTasks?: boolean; artifacts?: {id:string;name:string}[] },
) {
  return DOMPurify.sanitize(md.render(text, options), {
    ADD_ATTR: ["target", "data-copy-code", "data-source"],
    FORBID_TAGS: ["style", "iframe", "object", "embed"],
  });
}
let diagramCounter = 0;
let diagramQueue: Promise<void> = Promise.resolve();
export async function enhance(container: HTMLElement) {
  const theme =
    container.closest<HTMLElement>("[data-theme]")?.dataset.theme ||
    document.documentElement.dataset.theme;
  const exporting = !!container.closest("[data-export]");
  container.querySelectorAll<HTMLButtonElement>("[data-copy-code]").forEach(
    (button) =>
      (button.onclick = async () => {
        await navigator.clipboard.writeText(
          button.closest(".code-block")?.querySelector("code")?.textContent ||
            "",
        );
        button.textContent = "已复制";
        setTimeout(() => {
          if (button.isConnected) button.textContent = "复制";
        }, 1200);
      }),
  );
  const diagrams = [
    ...container.querySelectorAll<HTMLElement>(
      ".mermaid-block:not([data-rendered])",
    ),
  ];
  if (diagrams.length) {
    const { default: mermaid } = await import("mermaid");
    for (const element of diagrams) {
      element.dataset.rendered = "true";
      try {
        const diagramId = `diagram-${++diagramCounter}`;
        const pending = diagramQueue.then(async () => {
          mermaid.initialize({
            startOnLoad: false,
            securityLevel: "strict",
            htmlLabels: false,
            flowchart: { htmlLabels: false },
            theme: theme === "day" ? "default" : "dark",
            suppressErrorRendering: true,
          });
          return mermaid.render(
            diagramId,
            decodeURIComponent(element.dataset.source || ""),
          );
        });
        diagramQueue = pending.then(
          () => undefined,
          () => undefined,
        );
        const { svg } = await pending;
        if (element.isConnected) {
          element.innerHTML = DOMPurify.sanitize(svg, {
            USE_PROFILES: { svg: true, svgFilters: true },
          });
          diagramActions(element);
        }
      } catch {
        element.textContent = "这段图谱还没有写完。";
      }
    }
  }
  const charts = [
    ...container.querySelectorAll<HTMLElement>(
      ".echarts-block:not([data-rendered])",
    ),
  ];
  if (charts.length) {
    const echarts = await import("echarts");
    for (const element of charts) {
      element.dataset.rendered = "true";
      try {
        const option = JSON.parse(
          decodeURIComponent(element.dataset.source || "%7B%7D"),
        );
        if (!option || typeof option !== "object" || Array.isArray(option))
          throw new Error("Invalid chart");
        element.innerHTML = "";
        const chart = echarts.init(
          element,
          theme === "day" ? undefined : "dark",
          { renderer: "svg" },
        );
        chart.setOption({
          ...option,
          ...(exporting ? { animation: false } : {}),
          backgroundColor: "transparent",
          tooltip: {
            ...(option.tooltip || {}),
            renderMode: "richText",
            confine: true,
          },
        });
        const observer = new ResizeObserver(() => {
          if (!element.isConnected) {
            observer.disconnect();
            chart.dispose();
            return;
          }
          chart.resize();
        });
        observer.observe(element);
      } catch {
        element.textContent = "这张图表的数据还没有写完整。";
      }
    }
  }
  const scores = [
    ...container.querySelectorAll<HTMLElement>(
      ".abc-block:not([data-rendered])",
    ),
  ];
  if (scores.length) {
    const abc = await import("abcjs");
    for (const element of scores) {
      element.dataset.rendered = "true";
      try {
        element.innerHTML = "";
        abc.renderAbc(
          element,
          decodeURIComponent(element.dataset.source || ""),
          { responsive: "resize" },
        );
        element.innerHTML = DOMPurify.sanitize(element.innerHTML, {
          USE_PROFILES: { svg: true, svgFilters: true },
        });
        element.querySelectorAll("a").forEach((a) => a.removeAttribute("href"));
        element.style.height = "auto";
        element.style.paddingBottom = "0";
        const score = element.querySelector("svg");
        if (score) {
          score.style.position = "static";
          score.style.width = "100%";
          score.style.height = "auto";
        }
        diagramActions(element, "乐谱");
      } catch {
        element.textContent = "这段乐谱还没有写完。";
      }
    }
  }
}
