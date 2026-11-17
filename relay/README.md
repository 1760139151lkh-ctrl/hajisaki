# HajiSaki encrypted outbound fallback

This package implements the fallback transport foundation. The Windows connector makes an outbound WebSocket connection; the phone sends encrypted envelopes through an optional HTTPS ingress or the reference WebSocket ingress. The gateway remains on `127.0.0.1:8765`. The relay has no gateway credentials or end-to-end encryption key.

It is independently runnable Python code, with its own environment and dependency lock. Native profile export/import and secure-storage integration now have implementation paths described in `../phone/docs/native-relay-import.md`; device credential persistence and native TLS acceptance remain unverified. Native HarmonyOS VPN/P2P, complete automatic A/B selection, live-view updates and a deployed reachable Internet relay still require work. A real relay host, its DNS/network access and device conditions remain necessary outside this PC.

## Install

Python 3.11 or newer, in this directory:

```text
python -m venv .venv
.venv\Scripts\python -m pip install -r requirements.txt
```

Use the resulting Python executable in the commands below. The dependency versions are pinned. Runtime state and credentials belong below `runtime/`, which is ignored by source control. Never distribute that directory as part of a source bundle.

## Provision and deploy

Production is the default. Provision into a **new** directory; existing keys are never overwritten:

```text
python -m hajisaki_relay.provision --directory runtime/deployment --relay-name relay.example.net --port 9443 --http-port 9445 --pairing-file ../runtime/pairing.json
```

Replace the relay hostname and gateway pairing-file path with the actual deployment values. Provisioning creates a private CA, a relay server certificate, distinct host and phone client certificates, separate 256-bit role tokens, and a shared 256-bit payload key. It writes no secret values to the terminal. On Windows it restricts the deployment directory to the current account and SYSTEM before writing keys; on POSIX it uses directory mode `0700` and file mode `0600`. Protect copied credentials equivalently at their destination.

`--http-port` enables the additional phone ingress and writes `https_url` into the phone configuration. Production provisioning also supplies `server_public_key_sha256`: Base64 SHA-256 of the relay certificate's DER SubjectPublicKeyInfo, for native HTTP certificate pinning. Obtain that value through trusted provisioning, never from the network peer being authenticated. Omit `--http-port` to retain the WebSocket-only reference setup.

Copy only the following portions to their owners:

| Directory | Destination and contents |
| --- | --- |
| `relay/` | Reachable relay machine: server cert/key, CA cert, channel identifier and hashed role tokens. No payload key or gateway token. |
| `host/` | Windows PC: outbound client cert/key, host role token, payload key, fixed loopback gateway URL, durable journal. |
| `phone/` | Phone's protected storage: phone cert/key, phone role token, payload key and gateway pairing credentials. |
| `authority/` | Offline administration storage: CA signing key; never place it on the relay or phone. |

Leaf certificates are valid for 90 days; the CA lasts 10 years. Renew certificates before expiry. Copying keys in plaintext through chat, public links or the relay defeats this separation. This provisioner does not configure certificate revocation infrastructure; removing a lost device requires new device/channel credentials and secure re-provisioning. Keep the previous host journal with its corresponding key for outcome reconciliation; do not discard it to make a retry succeed.

Run the relay on the relay machine:

```text
python -m hajisaki_relay.server --config /secure/relay/config.json --bind 0.0.0.0 --port 9443
```

Run the outbound connector on Windows without a visible console:

```text
python run_hidden.py start host --config runtime/deployment/host/config.json
python run_hidden.py status host --config runtime/deployment/host/config.json
python run_hidden.py stop host --config runtime/deployment/host/config.json
```

The hidden launcher uses saved Python code, argument-list `subprocess.Popen`, `shell=False` and Windows `CREATE_NO_WINDOW`. It records PID and creation time to avoid acting on a reused PID. It does not install a service, modify firewall rules, enable autostart, or restart the existing gateway. Production service supervision can launch `python -m hajisaki_relay.connector` with the same config. Certificate paths resolve relative to each role's config file.

Both clients verify server hostname and CA. The relay requires client certificates. All production connections require TLS 1.3; no certificate check can be disabled in this package. Authentication additionally requires the role-specific channel token. The gateway address accepts only an explicit loopback IP origin; proxy environment variables and redirects are disabled for forwarding.

## Export a native phone profile

From this directory, using the relay's own Python environment:

```text
.venv\Scripts\python -m hajisaki_relay.native_bundle --config runtime/deployment/phone/config.json --pairing-file ../runtime/device-provisioning/phone.json --directory runtime/native-transfer
```

Use the current companion device's private pairing file. The new protected directory contains one bounded `hajisaki-relay.hsr.json`; it has CA/client PEM, an encrypted PKCS8 key, channel credentials and a device-bound HMAC. It contains no raw gateway token. The JSON is sensitive provisioning material: the key-file password is separated into Asset Store only after phone installation. Existing directories are refused. The native importer verifies the device-bound envelope before sending gateway credentials, probes the authenticated channel before installing it, and preserves unmatched or uncertain old requests. See the native import document for the exact trust and acceptance boundaries.

The HTTPS listener runs in the same relay process, on the same bind address, with the exact strict TLS context. `proxy_headers` and access logging are disabled. Native integration uses HTTPS with the provisioned server public-key pin rather than assuming the public OpenHarmony WebSocket implementation enforces server identity; see `native-transport-notes.md` for the source evidence and contract. Python clients use CA and hostname verification; native pin verification still requires a device runtime check.

## Reference phone client

```text
python -m hajisaki_relay.phone --config runtime/deployment/phone/config.json request GET /api/status
python -m hajisaki_relay.phone --config runtime/deployment/phone/config.json request GET /api/conversations
python -m hajisaki_relay.phone --config runtime/deployment/phone/config.json request POST /api/conversations --body-file conversation.json
python -m hajisaki_relay.phone --config runtime/deployment/phone/config.json retry REQUEST_ID
```

Every request is persisted encrypted before sending. The terminal shows the opaque request ID, HTTP status, uncertainty flag, byte count and local result path; it does not print tokens or response contents. Response bodies and metadata are stored in the phone state directory. A retry keeps the exact authenticated ID and plaintext content, with a fresh AEAD nonce and expiry; it does not create a second semantic request. Each response attempt remains separately inspectable.

When `https_url` is configured, the reference phone CLI uses HTTPS only. It does not silently downgrade to WebSocket or plaintext on a connection failure.

Uploads use the existing gateway workflow: `POST /api/uploads` with name/size/SHA-256/MIME, `PUT /api/uploads/ID?offset=N` with at most **4 MiB** raw body, then `POST /api/uploads/ID/complete`. Resume using `GET /api/uploads/ID`, rather than guessing an offset. Gateway idempotency rules still apply.

Artifact downloads require one explicit bounded byte range:

```text
python -m hajisaki_relay.phone --config runtime/deployment/phone/config.json request GET /api/artifacts/ID/content --range bytes=0-4194303
```

Use the immutable artifact SHA-256 and returned ETag/Content-Range to assemble and verify later chunks. `--if-range` accepts a strong quoted SHA-256 ETag, as supplied by the gateway. Suffix, open-ended and multi-range requests are refused. If the gateway ignores Range, the connector refuses the full response. Total authenticated response body is limited to 4 MiB for all routes; reduce pagination if that limit is reached.

Artifact ranges retain a small durable receipt instead of the complete response body. Before reading a successful range, the connector pins its strong ETag in SQLite. It then records encrypted response metadata and the chunk SHA-256. An identical retry re-fetches the same range with the pinned `If-Range` and verifies its body hash before returning the original response metadata. Changed or unavailable content is refused. This removes the previous 512 MiB response-cache barrier to multi-gigabyte reads; the total file bytes are not accumulated in the host journal. The phone remains responsible for final whole-file SHA-256 verification and its own cache capacity.

`/api/local-pair`, internal agent delivery/progress APIs, arbitrary URLs, assets outside `/api`, unknown future routes, forwarded Host/Origin/Cookie/proxy headers and redirects are refused. Only the explicit method/path list in `connector.py` is exposed. `/api/export` is intentionally not exposed: the current gateway creates a new ZIP per call, so a stable downloadable export artifact is required before safe multi-chunk export can be supported.

The explicit allowlist also covers reminder listing/creation/update, inbox listing/read acknowledgement, speech status/hotwords, transcription submission/status/stop, and speech cleanup. SSE `/stream` remains unsupported; use durable `/events?after=...` polling through the relay.

## Local development mode

There is a separate, explicit development mode for loopback-only work:

```text
python -m hajisaki_relay.provision --directory runtime/local-dev --relay-name 127.0.0.1 --port 9444 --pairing-file ../runtime/pairing.json --development
python run_hidden.py start relay --config runtime/local-dev/relay/config.json --port 9444 --development
python run_hidden.py start host --config runtime/local-dev/host/config.json --development
python -m hajisaki_relay.phone --config runtime/local-dev/phone/config.json --development request GET /api/status
```

Development uses authenticated `ws://` plus payload AEAD, without TLS. Both the config and command must explicitly select development. Its relay may bind only a loopback IP and its clients may connect only to a loopback IP. A production config cannot be downgraded with a command-line flag. The local production-mTLS verification also uses loopback, but exercises the real certificate requirement and TLS 1.3 path.

## Protocol v1

One reference WebSocket phone and one host may connect to `/v1/channels/CHANNEL/phone` and `/v1/channels/CHANNEL/host`. They send `Authorization: Bearer ROLE_TOKEN` in the TLS-protected handshake, never a query string. The relay stores only SHA-256 token digests. Additional simultaneous WebSocket connections for either role are rejected. WebSocket origins remain absent-only by default; an optional `allowed_origins` list permits at most eight exact HTTPS origins in production (HTTP loopback origins in development), without wildcards.

The HTTPS phone ingress is `POST /v1/channels/CHANNEL/request`, with `Authorization: Bearer PHONE_ROLE_TOKEN`, `Content-Type: application/octet-stream`, and exactly the same raw binary envelope below. HTTP 200 carries the opaque host response frame; the actual API status remains encrypted inside it. Other HTTP statuses contain untrusted `{transport: code, id?: request_id}` notices, never proof that a mutation did not execute. The HTTPS handler shares the eight pending-ID cap with WebSocket traffic, limits HTTP waiters to eight, bounds request-body reading to ten seconds and the total handler deadline to 45 seconds. A concurrent duplicate ID is rejected with transport HTTP 409; retry the same ID after the previous exchange completes. Neither ingress decrypts any payload.

Application messages are binary; WebSocket compression is disabled. Frame layout:

| Bytes | Meaning |
| --- | --- |
| 4 | ASCII `HSR1` |
| 2 | Big-endian unsigned header length |
| Header length | Canonical JSON `{v:1,kind:"request" or "response",id:32-lowercase-hex,iat:unix-ms,exp:unix-ms,nonce:standard-base64}` |
| Remaining | AES-256-GCM ciphertext followed by its 16-byte authentication tag |

Header JSON is ASCII, sorted keys, compact separators, no duplicate keys or non-finite numbers. Header length is at most 1,024 bytes. `nonce` decodes to 12 fresh CSPRNG bytes. `exp - iat` is at most 120,000 ms; receivers refuse expired frames and timestamps more than 30 seconds into the future. Device clocks must be synchronized. Only local persisted ciphertext can bypass expiry for authenticated renewal; network input cannot.

From the 32-byte master key, derive separate request and response keys using HKDF-SHA-256, 32-byte output, salt `SHA256(ASCII CHANNEL)`, info `ASCII "HajiSaki/relay/v1/request"` or `ASCII "HajiSaki/relay/v1/response"`. Associated authenticated data is `ASCII CHANNEL || 0x00 || exact header bytes`.

Decrypted plaintext is `uint32-be metadata_length || UTF-8 JSON metadata || raw body`. Metadata is at most 16 KiB, body at most 4 MiB. Maximum complete frame is 4,211,738 bytes (`MAX_FRAME` is authoritative). Do not Base64 the raw body or entire frame.

Request metadata has exactly `method`, `path`, `headers`. Gateway bearer token and `X-Haji-Device` are inside these encrypted headers. Response metadata has exactly `status`, `headers`, `request_digest`, `outcome_uncertain`. `request_digest` is SHA-256 of the original complete plaintext request; phone clients must match it as well as ID and direction before accepting a result.

Relay text messages such as `{"transport":"host_offline","id":"..."}` are untrusted transport notices. They are never model replies, API results or evidence that an operation did not execute. The relay can observe timings, sizes, request IDs, channel and availability; AEAD hides request paths, credentials and content, not traffic metadata. The relay can also delay or drop traffic.

The AES-GCM implementation uses the library's authenticated-encryption API; nonce uniqueness and authenticated associated data are essential to its contract. See [cryptography authenticated encryption](https://cryptography.io/en/latest/hazmat/primitives/aead/). Connection queue, message-size, origin and TLS behavior use the pinned library's documented parameters: [websockets 13.1 server](https://websockets.readthedocs.io/en/13.1/reference/legacy/server.html).

## Retry and crash semantics

For `POST`, `PATCH`, `PUT` and `DELETE`, the connector commits a SQLite request ID and plaintext digest with `synchronous=FULL` before HTTP forwarding, then commits the encrypted response before delivery. Same ID/digest returns the saved result (freshly encrypted for its delivery window); same ID/different digest returns a conflict and never executes. An identical active retry waits for the original operation. Immutable artifact range reads instead use the small, ETag-pinned receipts described above; their repeated HTTP reads are deliberate and carry no mutation.

Before delivering any completed cached response, the connector revalidates that request's encrypted `Authorization` and `X-Haji-Device` against the live gateway's authenticated `GET /api/status`. The check is bounded to five seconds, does not retain the status body, and is never cached across requests. A revoked or invalid device receives 401/403 without the old response; an unavailable gateway or inconclusive authorization receives 503. The original mutation receipt remains intact and the mutation is never re-forwarded. Denial does not mean the original operation failed to execute, so callers retain its ID and reconcile through an authorized device. Device administration routes remain excluded from the relay allowlist.

Other authenticated `GET` requests are **fresh reads**, including status, conversation/event polling, reminders, inbox and speech status. They do not write a durable request or response row. Retrying the same ID and content re-reads current gateway state, so its body may legitimately change; the client still verifies the authenticated request digest and response ID. Concurrent IDs remain bounded and an active same-ID/different-content request is refused. A collision with a previously persisted mutation/range identity is also refused. Event consumers must resume from `after`/cursor and deduplicate durable event sequence IDs; a transport request ID is not an event snapshot. Old generic-GET journal records are retained without deletion, but matching retries now return fresh state rather than their obsolete cached body.

If the host dies after committing a mutation claim but before committing its response, that ID stays `pending`. Its next retry returns HTTP 409 with `outcome_uncertain=true`. This is intentional **at-most-once mutation forwarding**, not a claim of exactly-once execution: the gateway may already have performed the operation. Reconcile through normal read APIs and gateway message `client_id`/upload offsets before deciding what to do. Never silently generate a new mutation ID after a timeout. An interrupted `read_pending` artifact request may resume with its durable ETag pin; no read body is delivered before its receipt is committed. Invalid or rejected requests that were never forwarded need not consume a durable claim.

The relay and connector permit eight in-flight request IDs, use a two-message WebSocket receive queue, and cap each gateway call at 30 seconds total. The relay does not keep an offline queue. Phone outbox and host journal carry recovery state across reconnects. Journal storage reserves full response capacity for outstanding mutation results and 64 KiB for each pending artifact read receipt. It stops accepting new durable mutation/range IDs at a 512 MiB metadata/result budget and never silently prunes deduplication records. Ordinary GET polling bypasses that budget and does not accumulate journal rows. Existing records remain intact. Manage completed deployment data deliberately, retaining keys and request records needed for reconciliation.

## Integration boundaries

Native HarmonyOS needs to implement this binary codec, use secure key/certificate storage, perform mTLS WebSocket connections, and feed the existing durable conversation event cursor and upload offset into its transport selection. A/B failover must preserve request ID and message `client_id` rather than race duplicate writes down two channels. Direct-channel writes must share the same gateway idempotency contract before automatic dual-channel racing can be enabled.

No native phone, public relay, domestic mobile-network reachability, automatic failover latency, multi-day uptime, 2 GB upload, or Pura frame-rate result is claimed by the local verification. See `verification.md` for actual observations.
