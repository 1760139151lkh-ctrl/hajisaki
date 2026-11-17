# HajiSaki Studio

Local companion and host console. This browser client supplements the native HarmonyOS application; it is not evidence of native frame rate, cold start, Live View, biometrics or background behavior.

## Run

Use Node 22.12+ and the project gateway. From this directory, run `npm ci`, then `npm run build`. The gateway serves `dist/` at `/` and generated artwork/audio at `/artwork/`. For development, `npm run dev` proxies the API to `127.0.0.1:8765`.

Pair using the explicit **连接这台电脑** action on the loopback gateway, or provide device/token credentials. The token is kept in session storage; offline messages, drafts, attached artifact metadata and settings are in IndexedDB under the device namespace. A separately enabled development provider is always labelled as non-AI.

Queued messages retry with their original client ID once the host connection returns, and on reopening their conversation. This does not repeatedly resubmit every validation failure. Actual host stop/start was used to observe a retained offline message automatically delivered once.

## Delivered documents and interactive cards

Small UTF-8 text/source documents (up to 1MiB) open directly; Markdown uses the existing rich reader, and plain CSV/source remains copyable text. Self-contained HTML opens in a Blob iframe with `sandbox="allow-scripts"`, an opaque origin and no access to the parent, storage, device permissions or app credentials. Its CSP blocks resource/network loads; the parent restricts frames to Blob documents. A fixed footer keeps save/continue controls outside the card. Closing destroys the frame and releases its Blob URL.

Real MCP-created Markdown, CSV and HTML were opened through ordinary UI actions. The HTML checkbox counter and reset were exercised; parent document and local storage reads returned SecurityError. These observations do not claim an exhaustive browser-security audit. HTML-local interaction is distinct from the existing durable Markdown task-state API.

## Native reader

`dist/render-frame.html` is an API-independent offline reader. Copy this file with its transitive files from `dist/.vite/manifest.json`, retaining relative paths, or copy the complete current build. Do not use old hashed chunks left by prior builds as dependency evidence.

Call `window.loadDocument({text,theme:'night'|'day'})` using a JSON-serialized argument, never string interpolation into JavaScript. The reader reports measured height through `window.HajiNative.height(String(height))` and a parent `hajisaki-height` message. External link navigation is suppressed; internal footnotes and generated local SVG downloads remain available. Native saving still needs the native WebView download integration.

Markdown is parsed with HTML disabled. Only explicit details/summary tokens are reconstructed; raw HTML remains text. KaTeX/mhchem uses `trust:false`, SVGs are sanitized, Mermaid uses strict mode and native SVG labels. `echarts` fenced blocks accept JSON (not executable functions), with canvas-style rich text tooltips. `abc` fences render a score. Task controls remain disabled until an actual durable task-state response is loaded.

## Verification boundaries

Normal browser actions and direct application entry points were used, not a new test suite. Captures and exported SVG evidence are in `inspection/`. Implemented microphone capture has not been exercised with the user's microphone. The original public `jfk.flac` asset was used through the real speech API and review UI. Sound files are opt-in; no auditory or hardware timing claim is made.

Large-file hashing runs incrementally in a worker; transmission uses bounded resumable chunks. Media/PDF preview currently decodes a selected file in the browser, so opening a very large preview has different memory costs from uploading it. Offline cache supports previously opened text and drafts; it is not a claim that every historical original media file is available offline.
