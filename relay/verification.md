# Local verification — 2026-11-15

These observations used normal package entry points and existing gateway APIs. No test suite, fixture, harness or scripted test runner was added. The gateway supervisor at `127.0.0.1:8765` was not restarted by this work.

## Executed observations

| Operation | Actual result |
| --- | --- |
| Python syntax compilation of `relay/` | Completed without syntax errors. |
| Production provisioner with SAN `127.0.0.1` | Wrote separate relay/host/phone certificate sets and private channel configuration, with current-user + SYSTEM directory ACL. No secrets printed. |
| Hidden relay and outbound connector, production mode | Connected over the production mTLS code path on loopback port 9443. `GET /api/status` through encrypted relay returned HTTP 200 and the existing development provider's real `authenticated=false` state. |
| Missing client certificate, correct CA and role token | TLS connection reset before a valid WebSocket HTTP response. No channel was established. |
| Valid client certificate, incorrect role token | WebSocket handshake rejected with HTTP 401. |
| `POST /api/local-pair` through reference phone | Authenticated encrypted HTTP 403, `route_not_allowed`. |
| Absolute external URL as forwarded target | Authenticated encrypted HTTP 403, without forwarding. |
| Malformed `http://[` target | Authenticated encrypted HTTP 400, rather than hanging or claiming execution. |
| Artifact Range `bytes=0-4194304` | HTTP 400, `bounded_single_range_required` (4 MiB + 1 exceeds bound). |
| Existing contract artifact, Range `bytes=0-4496` | HTTP 206, 4,497 bytes, `Content-Range: bytes 0-4496/4497`; downloaded SHA-256 matched artifact metadata and ETag: `726cf9919789915ec4cbf1a5c3aeee531108b32950a125da0e78514983391d2f`. |
| Initial implementation: retry an earlier status request after connector restart and expired original transport window | Before the fresh-read correction below, same ID returned the original 738-byte body, hash `7a38a29f213c61846a5780d34f009133a63dd362ef1e68ee730d3e84fc836d61`. This historical observation is superseded for ordinary GETs by current-state read semantics. |
| Upload the actual delivered relay README | Begin, raw PUT and complete each returned HTTP 200. Gateway created `HajiSaki-relay-guide.md`, 12,898 bytes, artifact ID `1c7c8c532a31417c853a3055131c6d0c`, SHA-256 `aa44ca4e726d5f6259677bd91b9ff62474212b9ac9569d6bf15769f824b9dc14`. |
| Retry the upload-begin request after upload completion | Returned the original upload ID and original `offset:0, complete:false` response, rather than re-running begin. SQLite contained one completed journal row for that ID. |
| Explicit development configuration and CLI flags | Local `ws://127.0.0.1:9444` relay and connector returned HTTP 200 for the existing gateway status. Development helpers were then stopped. |

Transport IDs and local state locations are preserved under `runtime/loopback-mtls/` and `runtime/local-dev/`. These directories contain credentials and personal response bodies; they are excluded from source control and must not be published. The uploaded guide is a real delivered project document, not synthetic test data.

## Review and fixes

An independent read-only source review identified recovery and validation issues during implementation. The final code now reattaches an active identical retry to its original operation, renews old locally authenticated envelopes with the same ID and content, re-encrypts saved responses for the new delivery window, applies a 30-second total HTTP deadline, rejects malformed URL/unpaired-surrogate inputs before creating a claim, type-checks untrusted control metadata, and checks PID creation time before treating a helper as its recorded process. The reviewer read back those changes and reported no new material issue in that bounded review. This is not a claim of an independent security audit.

## Remaining validation and integration

- No publicly reachable relay or real phone mTLS connection was available. The certificates generated here identify loopback and cannot establish the required production WAN endpoint.
- No native HarmonyOS device handshake, secure-key import, VPN/P2P connection or automatic dual-channel failover was exercised by these relay checks.
- No 2 GB upload, 30% packet-loss workload, full 4 MiB upload-boundary stress, 7×24-hour runtime, network power-loss exercise or memory/performance acceptance is claimed.
- The durable `pending` crash-ambiguity behavior and delayed in-flight reconnect repair were source-reviewed; no artificial crash/slow-stream harness was created. Completed-response recovery was directly exercised by restarting only this connector and retrying a real request.
- The private CA provisioner has no revocation service. Certificate renewal, lost-device re-provisioning and public relay deployment remain operational work.
- Large library export remains blocked on a gateway API that exposes a stable export artifact; `/api/export` is excluded to prevent inconsistent multi-range assembly across newly generated ZIP files.
- At-most-once forwarding is limited to this fallback transport's durable request journal. Direct/P2P writes must share gateway idempotency before native automatic A/B racing can safely be enabled.

Production loopback helpers are left available for the root agent's integrated acceptance. `run_hidden.py status/stop` with the respective role config controls them without touching the gateway. Local-development helpers are stopped. Runtime keys, response records and journals are retained as reproducibility and recovery evidence.

Cleanup: task-created `relay/__pycache__/` (5,676 bytes) and `relay/hajisaki_relay/__pycache__/` (78,427 bytes) were moved directly to the Windows Recycle Bin, about 84.1 KB of logical file content. No disk-space recovery claim is made. Source, dependencies, credentials and diagnostic evidence remain intact.

## Artifact-read scaling correction

The initial full-response cache would have consumed the 512 MiB journal limit during a large download. Artifact range requests now persist a small encrypted receipt, strong ETag and chunk SHA-256. The ETag is committed before reading any successful response body. Completed or interrupted reads can be fetched again with a connector-supplied `If-Range`; a changed ETag, byte range or saved chunk hash is refused. Mutations keep their previous durable at-most-once behavior. Migration adds two columns and preserves existing records.

Normal reference-client calls fetched a real existing PDF in two ranges, 550,000 and 175 bytes. The host journal retained **543 and 548 bytes** of encrypted receipt respectively, rather than either body. Reassembling those two returned bodies produced SHA-256 `b4cf398c21d054e8774af568395b0f7cd0e2b01322809c5dbd66c4135021ca57`, equal to the existing artifact's full hash. Retrying the first range returned the same 550,000-byte SHA-256 `788c8c924ef37c21928647196e09d0bbcf31431978a288d847251a91ed4c23a3`. Reusing that ID with a different requested range returned HTTP 409 `request_id_reused_with_different_content`. Retrying the earlier upload-begin mutation still returned its original cached result.

This removes response-body accumulation as the 2 GB download blocker. It does not claim that a 2 GB transfer or full-boundary stress run occurred. The finite journal budget still applies to its metadata and retained mutation results.

Source-inspected reminder, inbox and speech routes were added to the explicit allowlist. Real `GET /api/reminders`, `GET /api/inbox?unread=true`, and `GET /api/speech/status` each returned HTTP 200. Their mutation routes were checked against the actual router definitions; no new reminder or speech job was created merely as a fixture.

## HTTPS phone ingress

The native integration uses an optional opaque HTTPS POST ingress because the inspected public OpenHarmony WebSocket source has certificate-verification concerns documented in `native-transport-notes.md`. The relay still forwards encrypted HSR1 bytes without decrypting them, through the same existing host WSS connection. The handler shares the pending-ID bound and has a 45-second total deadline. The provisioner now supports `--http-port` and emits the trusted native `server_public_key_sha256` pin in production phone configuration.

The local production relay was configured with WSS port **9443** and HTTPS port **9445**. The original gateway on 8765 was not restarted. Actual HTTPS observations:

| Operation | Observed result |
| --- | --- |
| Real `GET /api/status`, `/api/inbox?unread=true`, `/api/speech/status` via encrypted HTTPS POST | Outer HTTP 200, authenticated inner API status 200. |
| Retry of the earlier WebSocket PDF request through HTTPS | Authenticated inner 206, 550,000 bytes, same request ID and same chunk body hash. |
| Valid TLS handshake | Negotiated TLS 1.3. |
| TLS 1.2-only client | TLS handshake failed with EOF; no HTTP exchange. |
| Correct CA/role token but no client certificate | Connection reset before an HTTP response. |
| Valid client certificate but no trusted private CA | Certificate verification failed: self-signed certificate in chain. |
| `localhost` against the certificate issued only for `127.0.0.1` | Certificate verification failed with hostname mismatch. |
| Valid client certificate, incorrect phone role token | Outer HTTP 401 `channel_authentication_required`. |
| Authenticated empty binary frame | Outer HTTP 400 `invalid_transport_frame`. |

These negative checks exercised the Python HTTPS relay/reference transport. They are not evidence of native NetworkKit pin behavior on a device. The runtime phone config contains `https_url` and the public-key pin derived locally from the trusted relay certificate; secret values were not printed. HTTPS clients never fall back to WSS or plaintext after failure. The optional exact-origin WSS setting was source-reviewed but is not required by this native HTTPS path and remains absent in the local production config.

After the final server reload, another ordinary status request returned inner 200 and the original PDF range retry returned inner 206 with 550,000 bytes. The running process records are the authority for current helper PIDs. The regenerated `relay/hajisaki_relay/__pycache__/` (94,841 bytes, about 94.8 KB logical content) was moved directly to the Recycle Bin; runtime credentials, journals and actual response evidence were retained.

## Ordinary polling without host journal growth

Ordinary non-artifact GETs now bypass durable response storage. They are authenticated fresh reads, including retries of the same request ID; event clients use `after`/cursor and sequence deduplication. Active same-ID/different-digest requests remain rejected, as do collisions with a different persisted mutation/range digest. Existing records are retained, with no pruning or deletion. POST/PATCH/PUT/DELETE and immutable artifact range handling retain their previous durable protection.

After syntax parsing and a reload of only the outbound connector, normal HTTPS reference-client status requests returned HTTP 200. The same ID `ae42e0586e294f0abf3d028fb349603f` first reported host uptime **506.8 seconds**, then **520.8 seconds** on retry: current state was fetched again. A further new-ID status call also returned 200. The host journal stayed at **16 rows** throughout; zero rows were created for the new polling ID. This directly checks the polling-growth correction without a test harness or synthetic fixture.

Targeted rechecks preserved the other semantics: the original upload-begin mutation still returned its original upload ID/offset, and an existing artifact-range retry returned 206 with **550,000 bytes**, SHA-256 `788c8c924ef37c21928647196e09d0bbcf31431978a288d847251a91ed4c23a3`. Its durable encrypted receipt stayed **543 bytes**, and the total journal row count remained 16. This removes the continuous-GET accumulation failure; it is not a 7×24-hour runtime claim.

The Python cache regenerated by this final polling check, `relay/hajisaki_relay/__pycache__/` (68,754 bytes, about 68.8 KB logical content), was moved directly to the Recycle Bin. Source, private deployment configuration, journal and response evidence were retained.

## Revocation before cached delivery

Completed cached responses now require a fresh authenticated gateway `GET /api/status` before every delivery. Only the encrypted request's validated Authorization/device headers are used. The check has a five-second overall deadline, does not read/store the status body and does not cache authorization. A denied/unavailable check returns an encrypted 401/403 or 503; the original receipt remains unchanged and its mutation is never forwarded again. Device-management routes remain absent from the relay allowlist.

This was exercised through the running HTTPS ingress after the real device registry was loaded. A separately paired companion uploaded the actual `native-transport-notes.md` project document through begin/PUT/complete, then successfully retrieved its cached begin response (200, 69 bytes). The device owner revoked only that companion through the normal device API. Retrying the same original transport ID, `ab1b63aa6023482f9a93a80311ed2e0f`, then returned **401**, `outcome_uncertain:true`, and only a 55-byte `gateway_access_revoked_or_invalid` response. No cached upload result was included.

The original journal row stayed `complete`, 397 bytes, with SHA-256 `5d0e3def970c29e0fb7df3bfb44fcca05f8e699fe315dd433c53a1ac3527556d` before and after revocation; its per-ID row count stayed one. The valid bootstrap owner's earlier cached mutation continued to return its original 200/69-byte result. The device-registry task independently observed the other companion and owner remaining authorized. The revoked companion's configuration and encrypted request/response evidence are retained privately under `runtime/loopback-mtls/phone/`; no token or private key was printed.

For the unavailable-authority branch, a normal direct call to the existing `revalidate_cached_access` function used an in-memory gateway origin pointing to confirmed-unbound loopback port 1. It returned **503**, `gateway_authentication_unavailable`. No live gateway configuration was changed and no service was interrupted for this check. This verifies the helper's real connection-failure path; it is not an end-to-end gateway-outage exercise. Syntax parsing passed. Only the owned outbound connector was reloaded after observing no active HTTPS requests; its current PID is recorded in the normal private process record.

The regenerated `relay/hajisaki_relay/__pycache__/` from this check (70,666 bytes, about 70.7 KB logical content) was moved directly to the Recycle Bin. All operation receipts, protected credentials, source and diagnostic evidence were preserved.
