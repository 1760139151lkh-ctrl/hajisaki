# Antigravity ACP 图文通道

Current contract (2026-11-16): `hajisaki/acp.py` is a client of the installed Google-signed Antigravity CLI harness. The CLI loads its ordinary `antigravity-cli/settings.json` and default customizations. Its existing `hajisaki-acp` trajectory store remains so old conversations continue; old restrictive `gateway-tools-*` settings profiles are no longer selected. The app does not replace the agent, system prompt, model provider, native-tool catalog or permission engine. App delivery tools remain available and App delivery requirements remain mandatory. Both `acp` and legacy `agy` names use this same path. Native tool calls are forwarded without cancelling the entire turn. Reads within the working folders or of files explicitly named in the current user request may be allowed once; other unconfirmed operations are declined individually, and a full native approval UI remains separate work. User prohibitions and the no-extra-credits constraint remain. See `../docs/native-harness-contract.md`.

The records below describe earlier restricted-profile experiments, retained as history. They are not the current launch policy.

Run from `host/` with the project Python:

```text
../.venv/Scripts/python.exe -m hajisaki.acp --data-dir ../runtime/acp-discovery --proxy http://127.0.0.1:10808
../.venv/Scripts/python.exe -m hajisaki.acp --data-dir ../runtime/acp-discovery --proxy http://127.0.0.1:10808 --session-config
../.venv/Scripts/python.exe -m hajisaki.acp --data-dir ../runtime/acp-image --proxy http://127.0.0.1:10808 --prompt-file ../runtime/acp-image-request.txt --image ../shared/assets/avatars-youth/idle_gentle.png
```

The second command creates and closes one empty ACP session to obtain account configuration. The third explicitly submits a real inline image request. Results are saved in the private diagnostic directory as `capabilities.json`. Normal completion closes the diagnostic transport; this is not model-session failure recovery.

## Actual observations, 2026-11-15

- Installed server identifies itself as `Antigravity ACP Server`, version `1.5.9`, and negotiated protocol `1`.
- Advertised prompt capabilities: images `true`, embedded context `true`, audio `false`.
- Advertised session operations include load, resume, list, close and additional directories. The server also advertises appending a system prompt.
- Empty session creation succeeded using the already cached Google AI Pro login. It returned 18 concrete model IDs, grouped model choices, the active thinking-level choices, and execution-mode options. No model generation or tool action occurred.
- The isolated empty session `b84ad7ac-9a92-475c-94cd-b67fb3b3fee6` was closed using `session/close`. Its state remains in the dedicated profile; no files were deleted.
- An absolute `--app-data-dir` passes initialization but fails session setup with `must not be absolute`. The working invocation uses the relative application name `hajisaki-acp` with `--cli_dir_name gateway`; its profile is `~/.gemini/hajisaki-acp/`, and its CLI settings are `~/.gemini/hajisaki-acp/gateway/settings.json`.
- A dedicated strict/deny policy was written only into that app-owned profile. The normal `~/.gemini/antigravity-cli/settings.json` content fingerprint remained unchanged. No credential file was copied or printed.
- The isolated policy disables extra credits, direct API-provider selection, global customization inclusion, and all file/command/MCP/browser actions. Its settings file was read back with the expected values. Initialization and empty-session configuration do **not** expose the effective permission engine state, so `effective_permission_policy_verified` remains `false`.
- A subsequent genuine image turn in session `91bc887e-1c40-43e5-9326-f96be46845a7` completed with `end_turn`, 10 public text deltas, no server permission/filesystem/terminal requests and no unexpected tool attempt. Its description matched the actual image's hair, navy/gold clothing and white collar. This used an old reference solely for protocol verification, not approval of the old character design; current UI resources use the youth variant. Evidence: `runtime/acp-image/capabilities.json`.
- Model completion and session closure succeeded. Final console printing then hit a Windows cp1252 Unicode error; stdout was changed to UTF-8. The persisted success was retained without repeating the request or replacing the session.

## Integration boundary

The original `gateway` profile remains inline-only with all tools denied. The current gateway provider uses a separate `gateway-tools-v2` profile for the owned bridge described below. Earlier profiles remain on disk unchanged. Arbitrary host commands, filesystem actions, browser use and other MCP tools remain disabled; this is not a general approved execution channel. `agent_thought_chunk` is discarded rather than saved or displayed.

Gateway sessions persist as `acp:<sessionId>`. Historical replay during load is not appended as new text; current public deltas use the existing durable stream. L4 `visual_input` means prepared input, not proof of visual review. A future phone approval must bind the exact operation to verified device proof; `approved:true` is insufficient. Raw audio needs another supported route because this server advertises `audio:false`.

Sources: [Antigravity ACP guide](https://antigravity.google/docs/ide/extensions/acp), [ACP initialization](https://agentclientprotocol.com/protocol/v1/initialization), [ACP session setup](https://agentclientprotocol.com/protocol/v1/session-setup).

## Run-scoped engineering bridge — actual integration

`session/new` and `session/load` receive one `hajisaki` MCP stdio server, launched with project Pythonw and a private run-grant file. A dedicated settings profile `~/.gemini/hajisaki-acp/gateway-tools-v2/settings.json` allowlists exact bridge tools while denying filesystem, command and URL actions. It does not replace earlier profiles or global user settings. The v2 allowlist adds trusted, data-only PDF/XLSX/ZIP exporters; no model code or arbitrary command is accepted. Their input/resource budgets and artifact readers are documented in `host/README.md`.

The installed server reports the bridge operation through structured `toolCall.name` as `mcp_hajisaki_<name>`, `kind:other`, plus `args`. It also adds a display-only `toolSummary` field and can request confirmation even for the exact allowlist: observed `agy_tool_safety` marked a generic MCP tool unsupported. The client now permits only an exact owned bridge name, known argument names (plus that display field), matching active session and an `allow_once` option. It never authorizes from display title alone and never chooses an always-allow option. Bridge/HTTP argument validation, conversation attachment checks and managed-output path checks remain independently enforced.

Normal Studio conversations actually read an existing engineering contract, created/delivered `handoff.md`, `handoff.csv` and a self-contained interactive `study-card.html`. The HTML run `48bedcdcfd4a44f9a5bde20680a1989a` completed with `unexpected_tool_attempt:false`. The earlier file-delivery run was deliberately stopped through the ordinary UI to verify partial text and both files survived; its grant was revoked. A subsequent offline-outbox message automatically sent once when the host returned and completed in the same provider conversation. This is not terminal-runtime-error recovery, and no replacement model session was created.

An expired/ended grant was rejected for progress writes, a live grant was rejected for a real PDF outside its conversation, and stopped-run authorization was rejected after stop. These focused observations are not an exhaustive adversarial proof or biometric approval. Original files, process state, precise run IDs and verification boundaries are recorded in `docs/acceptance-ledger.md`.

Subsequent real runs in the same provider conversation `acp:3ac93481-a1da-4e23-88ed-b06ef41fda65` read the actual engineering contract and delivered a six-page Chinese PDF, two-sheet XLSX and a ZIP containing those files and the original. An initial workbook worker hit a local OpenBLAS allocation failure; limiting numerical-library threads fixed it without replacing the model conversation. Final run `333b9565b8ff4f3f87c6c35c83ae25d9` completed; the final workbook retained all original cell values, and its grant ended with `enabled=0, expires_at=0`. A mistakenly supplied artifact ID was denied as outside the conversation; the model used the genuinely shared original instead.
