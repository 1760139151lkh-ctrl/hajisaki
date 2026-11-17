# HajiSaki implementation contract

The original charter remains the product scope. This document fixes interfaces for parallel implementation; it does not redefine completion. Native HarmonyOS is the target. A local browser console and isolated development provider allow honest validation before account/device access.

## Repository

- `host/`: Python FastAPI gateway, SQLite WAL/FTS, CAS, provider adapter, authenticated API.
- `phone/harmony/`: native ArkTS/ArkUI phone application targeting available Harmony SDK, API 26 target documented. The independent iPad task owns `ipad/` and `docs/ipad/`.
- `studio/`: responsive local companion/host console and rich content rendering, served by gateway. This is not a claim of native performance.
- `shared/`: design tokens and generated assets.
- `assets_pipeline/`: reference images, generation prompts and manifest.
- `docs/`: source evidence, acceptance ledger and operating guide.

## HTTP contract v1

Default address `http://127.0.0.1:8765`. Never bind public by default. API authentication is `Authorization: Bearer <token>`; device binding is `X-Haji-Device`. Bootstrap credentials live in a local configuration file; no secrets in source, logs or screenshots. API clients explicitly pair using token/device. Browser uses same-origin API. `/api/health` may expose only coarse unauthenticated liveness; detailed status is authenticated.

- `GET /api/status` -> `{provider:{name,available,authenticated,detail},host:{...},capabilities:{...}}`
- `GET /api/models` -> `{models:[{id,name,efforts:[]}]}` (only verified capabilities, no invented models)
- `GET /api/conversations?q=&group=` -> `{conversations:[{id,title,group,pinned,archived,updated_at,preview}]}`
- `POST /api/conversations` body `{title,group}` -> conversation
- `PATCH /api/conversations/{id}` body partial `{title,group,pinned,archived}`
- `GET /api/conversations/{id}/messages` -> `{messages:[{id,conversation_id,role,content,status,created_at,attachments:[]}],active_run,cursor}`. The snapshot and cursor are read in one SQLite transaction. `active_run` is nullable.
- `POST /api/conversations/{id}/messages` body `{content,client_id,model,effort,attachments:[]}` -> `{message,run_id}` (idempotency by client_id)
- `GET /api/conversations/{id}/events?after=0` -> `{events:[{seq,conversation_id,run_id,layer,kind,payload,created_at}],cursor}` ordered durable replay; poll route usable by native and browser.
- `GET /api/conversations/{id}/stream?after=0` -> authenticated SSE. Each frame is `id: <seq>`, `event: haji`, `data: <full event JSON>`, blank line; supports `Last-Event-ID`, 15-second comment heartbeats and replay after the supplied cursor. `run_id` may be null for reminders, pins and widget updates. A sequence is global, so gaps within one conversation are normal.
- `POST /api/runs/{id}/stop` -> `{status}` preserving partial response.
- `POST /api/conversations/{id}/fork` body `{message_id,title}` -> new conversation.
- `GET /api/memories?q=` -> `{memories:[{id,content,created_at,updated_at}]}`
- `POST /api/memories` body `{content}` -> memory; `PATCH /api/memories/{id}` same; `DELETE /api/memories/{id}` -> `{status}` (removed record exported directly to Recycle Bin, no permanent deletion claim).
- `GET /api/settings` -> `{theme,transparency,personality:{formality,detail,teasing},sound}`; `PATCH /api/settings` partial.
- `GET /api/artifacts` -> `{artifacts:[{id,name,size,mime,sha256,url}]}`
- `POST /api/uploads` body `{name,size,sha256,mime}` -> `{id,offset,complete,artifact?}`
- `PUT /api/uploads/{id}?offset=N` raw bytes -> `{offset}` (bounded chunks)
- `POST /api/uploads/{id}/complete` -> artifact after hash verification.
- `GET /api/artifacts/{id}/content` authenticated bytes, no disk paths exposed.
- `POST /api/artifacts/{id}/media-session` authenticates normal device credentials and returns a public-ID URL plus expiry; its short-lived `HttpOnly; SameSite=Strict` cookie is scoped to that device/artifact path. Browser media GET/HEAD support Range without exposing bearer tokens in URLs or buffering entire files in JavaScript. Device revocation is rechecked during delivery. Native clients can keep using Authorization headers on the original content route.
- `GET /api/export` -> ZIP containing Markdown, JSON, original assets.

## Bounded generated artifacts and readers

The owned run-scoped MCP additionally accepts structured PDF, XLSX and ZIP creation requests. Each output is exclusively created below the active run's managed directory, imported into CAS, attached to the assistant message and persisted as L4 with an L2 action record. The model never supplies executable exporter code or arbitrary source paths. PDF/XLSX export dependencies are installed with the project; capability flags `pdf_export`, `xlsx_export` and `zip_export` are truthful about local availability. Detailed budgets are in `host/README.md`.

Authenticated `GET /api/artifacts/{id}/sheet?sheet=0&offset=0&limit=20` reads one bounded XLSX window after ZIP inspection. `sheet` is zero-based, row 1 is returned as `header`, and `offset` counts subsequent data rows from zero. It returns `sheet_names`, `sheet`, `name`, `header`, `rows`, `row_offset`, `data_rows`, `columns`, `total_columns`, and `complete`, plus `supported`/a safe failure reason. Cells carry the actual literal value, type and limited display style; formulas are never evaluated. Each request covers at most50 data rows and64 columns from an original of at most64MiB. Strings longer than2000 characters explicitly carry `truncated:true`. The original remains separately downloadable.

Studio renders these windows with sheet selection, paging and independent table scrolling, and lists verified ZIP entries through the existing `/inspect` route. Its document modal keeps title and save/continue actions outside the reading scroll. Native readers use the bounded APIs described below; physical-device acceptance remains separate.

Authenticated `GET /api/artifacts/{id}/page-image?page=0&width=2048` reads a bounded PDF page through an independent PDFium process. It returns `supported`, `page`, `pages`, `width`, `height`, `mime`, `image_base64` and `source_sha256`, or a safe failure reason. Source limit64MiB, at most2 concurrent384MiB workers/20seconds, image area at most6million pixels. Normally PNG; oversized photographic PNG uses JPEG90 with unchanged pixel dimensions and declaredMIME. Encoded image budget is below3MiB, leaving Base64+JSON within the existing4MiB relay body. Native usesArkUIImage and caches actual visited pages; original bytes remain separately downloadable. ZIP `/text` now returns additive `total_entries`/`expanded_size` and accepts an entry-page limit up to100 (default remains100).

Native PDF/XLSX/ZIP reading is implemented within these budgets; physical-device rendering, original-file export, large-format coverage and persistent-storage recovery remain separate acceptance requirements. Cached pages do not count as evidence that the network has reconnected.

## Native image studio

Authenticated `POST /api/image-studio/preview` accepts `{source_id,operations}`; `/export` additionally requires a device-scoped `operation_id` and returns a standard Artifact. Source IDs resolve only to managed CAS objects. Operations are bounded data for pen/number/mosaic/clockwise rotation/projective four-corner rectification/grayscale paper enhancement, applied in order. Same device/key/payload exports replay the same artifact; a changed payload conflicts. Originals remain separate. PNG ink declarations use the existing `hajisaki-ink-v1` whitelist, never an instruction or an inspection receipt.

The native Canvas/Image client stores edit history and actual image checkpoints in its existing local store, then attaches the result without auto-sending. The two explicit POST routes are added to the relay allowlist. Budgets and observed boundaries are maintained in `phone/docs/native-image-studio.md`; they do not replace physical-device or external-tunnel acceptance.

Authenticated `GET /api/artifacts/{id}/thumbnail?width=480` returns bounded 480/960 image variants with `source_sha256`, real `thumbhash`, predecoded `placeholder_base64` and `animated` first-frame metadata. Source originals remain unchanged. The exact GET route is allowed through the existing encrypted relay. Native inline images/gallery cache visited data by immutable source identity; big-image overlays retain underlying reading position. “围绕这张图追问” attaches the original to an unsent draft. Detailed budgets and observations: `phone/docs/native-images.md`.

Authenticated `GET /api/artifacts/{id}/image-info` returns only `supported,width,height,thumbhash,source_sha256,animated`, before the image transfer. The same encrypted relay explicitly permits this exact route. Native `ThumbHash.ets` decodes real hash bytes locally, including alpha, and writes a bounded PNG; its raw hash metadata cache is `picture_meta_v2`, with legacy-cache read compatibility. Placeholder geometry uses the actual image metadata so letterboxing remains stable during the fade. MIT notices are included in the HAP raw resources. Actual opaque/transparent reference pixel comparisons, native intermediate frames, GIF first-frame/model reading and cached offline re-entry are recorded in the phone document above.

Run-scoped MCP `read_attachment_image({artifact_id,page?})` returns actual image content (or one zero-based PDF page) only from currently shared/pinned conversation artifacts. Success persists L4 `image_tool_read` with `status: pixels_returned_by_tool`, source digest, dimensions and PDF page, plus an L2 summary. This receipt proves authorized pixel extraction, not model attention or comprehension. New grants explicitly opt into tool profile3 / `gateway-tools-v3`; versionless existing grants retain the exact older 13-tool catalog. Existing model session IDs and old policy files are preserved.

## Event semantics

Checklist items may include `source_start_line` and `source_end_line`, directly from valid MarkdownIt inline token maps (zero-based, end-exclusive). Existing `index`, `text`, and `initial_checked` fields are unchanged. Missing source maps are omitted rather than guessed.

L1 = public provider-supplied reasoning summary only, never private hidden chain of thought. L2 = tool activity capsule with expandable authorized detail. L3 = narration/reply; `reply_delta` payload `{message_id,text}`, `narration` `{text}`. L4 = artifact/visual `{artifact}`. Lifecycle layer `system`: `run_started`, `run_finished`, `run_stopped`, `run_failed`, payload includes message_id and truthful status. Sequence persisted transactionally with message updates. Missing layers remain absent, not fabricated. Simulation provider, if explicitly enabled, is conspicuously labelled and never mistaken for a live model.

Exact provider retry banners are separate L2 `provider_notice` records with `{summary,diagnostic_id}`. They are not main reply text. Authenticated `GET /api/diagnostics/{id}` and `GET /api/messages/{id}/raw` expose explicitly requested original detail. A known historical banner uses an audited public projection; original database messages/events remain unchanged. Clients should accept additive fields and unknown event kinds without erasing their cache. A refreshed snapshot with the same cursor can carry a corrected public presentation.

## Independent device credentials

The software device registry is integrated in the main service, with actual companion issuance and native API use verified. Bootstrap token/device remains compatible for the local operator. SID-verified localhost pairing issues a separate browser credential instead of exposing the bootstrap key; the native reader uses a distinct companion credential.

- `GET /api/devices` -> `{devices:[{id,name,role,created_at,revoked_at,bootstrap}]}`, owner only.
- `POST /api/devices` body `{name,role:"companion"|"owner"}` -> HTTP 201, `{device,token,name,role,created_at,...}`. Raw token is returned once and must go directly into protected client storage; never logs, URLs or screenshots.
- `POST /api/devices/{id}/revoke` -> public device record, owner only. Revocation blocks new API calls and closes existing SSE readers at the next checked event/wakeup.

Each device uses its own token plus `X-Haji-Device`; copying the owner bootstrap token to phone and iPad is not multi-device pairing. Registry roles govern device administration, not separate-user tenancy: enrolled companions still share this owner's conversation library and host settings. Software IDs and token hashes do not prove a hardware fingerprint or biometric approval. Multi-device relay routing is a separate integration requirement; current phone-channel limits remain until actually verified.

## Safety and delivery

No model-driven arbitrary shell execution without a concrete approval bridge. Native biometric authorization is required before claiming high-risk approval support. Deletions go directly to Windows Recycle Bin; no permanent wipe workflow. Preserve raw provider diagnostics privately; UI receives actionable character-consistent copy. Original task demands remain in acceptance ledger even if environment validation is pending. No new test harnesses without explicit test-development authorization; normal API/UI calls and builds are required.
