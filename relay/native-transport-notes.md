# Native HTTPS integration contract

Native phone transport uses NetworkKit HTTPS with client certificate, private CA verification, TLS 1.3 and a provisioned server public-key pin. The Windows host continues its existing outbound WSS connection. No public gateway listener is needed.

Provision with `--http-port 9445`. The relay role config receives `http_port`; the phone role config receives `https_url` and, in production, `server_public_key_sha256` (standard Base64 SHA-256 of DER SubjectPublicKeyInfo). The native import process must put private key/material in app-private protected storage; no credentials belong in logs, URLs or artwork manifests.

The implemented importer is described in `../phone/docs/native-relay-import.md`. Native profile export now additionally requires the current companion pairing file and authenticates the complete profile for that device. The phone checks this binding before dispatching its gateway credential, keeps encrypted PKCS8 separate from its Asset-stored password, probes the channel before committing it, and only routes a matching gateway pairing through it. The current Previewer proves structure/refusal and UI handling; native HMAC, secure-storage recovery and TLS positive/negative acceptance still require a device runtime.

- Send `POST https://HOST:9445/v1/channels/CHANNEL/request`.
- Outer headers: phone role `Authorization: Bearer TOKEN`, `Content-Type: application/octet-stream`.
- Body: exact HSR1 binary request frame, maximum 4,211,738 bytes. Gateway bearer/device headers remain encrypted inside the frame.
- Outer HTTP 200: parse and authenticate the returned binary HSR1 response, then check direction, ID, expiry and plaintext request digest. Embedded `status` is the gateway result.
- Outer non-200: transport failure only; preserve the original ID and content for retry/reconciliation. Never invent a successful API result or automatically create a new mutation ID.
- The relay gives the whole HTTPS handler 45 seconds; the client should allow TLS setup plus that deadline. The Python reference client has a 55-second overall exchange bound and 50-second read timeout.
- Relay response metadata remains exactly `status`, `headers`, `request_digest`, `outcome_uncertain`. The small artifact read receipts are internal host state and do not change this schema.
- Ordinary non-artifact `GET` requests are fresh reads: a same-ID retry may return newer state, without adding host journal rows. Event polling uses `after`/cursor and event-sequence deduplication. Mutations retain durable at-most-once receipts; immutable artifact ranges retain their strong ETag/hash anchors.
- Cached responses require a new live gateway credential check on every delivery. Revoked/invalid credentials return embedded 401/403 without cached content; unavailable authorization returns 503. The original mutation remains recorded and is not repeated. Preserve `requestId` and the uncertainty flag; authentication denial is not proof that the original mutation never ran.

When production client trust, certificate/key, payload key, role token or the provisioned native public-key pin is absent, the native client must fail closed. Plain HTTP is permitted only in an explicitly selected loopback development setup. This repository's local Python HTTPS verification is not evidence that native NetworkKit has performed a successful or negative-pin device handshake.

## Why the native path uses HTTPS

The inspected public OpenHarmony source commit `c8586cd76da91b90b34b1d700fd000c44ec24e14` sets WebSocket connection flags that skip hostname verification and allow self-signed certificates even before the optional skip-verification setting is applied. Its dispatch table does not install a replacement certificate-verification callback. This is source evidence, not a claim about the unknown phone runtime binary. [OpenHarmony WebSocket implementation](https://github.com/openharmony/communication_netstack/blob/c8586cd76da91b90b34b1d700fd000c44ec24e14/frameworks/js/napi/websocket/websocket_exec/src/websocket_exec.cpp#L695)

The corresponding public libwebsockets commit `a172a806054df0584a09ecc7f075c002de8344e9` accepts self-signed-chain errors under that flag and bypasses hostname setup under the hostname-skip flag. The project therefore does not infer secure native WSS server identity from `skipServerCertVerification: false`. [OpenSSL client verification implementation](https://github.com/openharmony/third_party_libwebsockets/blob/a172a806054df0584a09ecc7f075c002de8344e9/lib/tls/openssl/openssl-client.c#L115)

The same source also shows native WebSocket emitting Origin, with `supportOriginPort` controlling inclusion of the port. Libwebsockets supplies `https://` for TLS. This justified an optional exact `allowed_origins` configuration for independently verified WSS clients; it is not required for the native HTTPS path and remains absent-only by default. [Origin serialization](https://github.com/openharmony/third_party_libwebsockets/blob/a172a806054df0584a09ecc7f075c002de8344e9/lib/roles/http/client/client-http.c#L1895)
