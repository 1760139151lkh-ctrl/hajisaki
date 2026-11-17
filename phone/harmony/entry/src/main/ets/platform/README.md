# Native adapters

These adapters use system APIs directly. No location API or location permission is used.

- `Credentials`: stores token, device binding and primary host together in a single encrypted Asset Store `SECRET` (maximum 1024 UTF-8 bytes), under a static application-scoped alias. It requires a lock-screen password, allows retrieval after the first device unlock, and disallows asset sync. Existing credentials are updated in place; there is no remove operation, unencrypted metadata, ordinary file, preferences or SQLite fallback. Unsupported/locked/unavailable secure storage returns an actionable error; only an absent record returns `undefined`. The caller must still validate the restored host with `Gateway.configure` before use. Ordinary app restarts can restore the stored pairing; uninstall retention is not requested.
- `RelayVault`: imports a bounded device-authenticated profile, verifies its HMAC before exposing gateway credentials to a new channel, and stages only public certificates/encrypted PKCS8 inside app-private generated paths. Payload keys, role token, password and gateway binding use a separate Asset SECRET. A successful authenticated channel read precedes installation. Preview mocks cannot commit secure credentials. Device execution and recovery remain to be checked; see `phone/docs/native-relay-import.md` from the workspace root.
- `NativeFiles`: system DocumentViewPicker; 1 MiB asynchronous file reads and SHA-256 updates; server-directed resume offset; bounded upload requests; streamed authenticated download to a private file; size/hash verification before export through the system picker. Download completion requires both HTTP 200 and `dataEnd`, in either arrival order. A two-minute inactivity watchdog resets on received bytes, without imposing a two-minute total transfer limit (`readTimeout: 0`); error/timeout paths reject and detach callbacks before closing the FD. Re-selecting the same unchanged file can resume when the host returns its existing upload session. A cancelled picker does not become a fake uploaded artifact. Partial downloads are retained.
- `NativeRecorder`: asks for microphone permission only on explicit start; records 48 kHz mono AAC at 64 kbit/s into an ADTS `.aac` file; has real pause/resume/stop states and closes its FD on release. No silence timeout or automatic transcript is invented. Original audio remains in application storage. Native AVRecorder's documented profiles do not include Opus; an actual encoder path is still needed for the charter's Opus requirement. Background interruption recovery and 5-minute lossless retention require device validation.
- `authenticate`: invokes system face/fingerprint authentication at ATL3 and checks `UserAuthResultCode.SUCCESS`. Cancellation, timeout, unsupported authentication and initialization errors deny the gate. This is a local access check only. A server-verified operation signature with a one-use challenge is still required before it can authorize remote high-risk actions. Never treat a posted `true` as biometric proof.

The module must declare `ohos.permission.INTERNET`, `ohos.permission.MICROPHONE` with its user-facing reason, and `ohos.permission.ACCESS_BIOMETRIC`. File pickers grant scoped access and do not require broad filesystem permissions. No permissions are pre-granted by this code.

Sources checked during implementation:

- [Secure Asset Store](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-asset/)
- [Adding secure assets](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/asset-js-add/)
- [Querying secure assets](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/asset-js-query/)
- [Updating secure assets](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/asset-js-update/)
- [System file selection](https://developer.huawei.com/consumer/en/doc/doccenter-capabilities/select-user-file/)
- [System file saving](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/save-user-file/)
- [File I/O](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-file-fs/)
- [Incremental SHA-256](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/crypto-generate-message-digest/)
- [HTTP streaming](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/http-request/)
- [HTTP requestInStream, dataEnd and readTimeout contract](https://developer.huawei.com/consumer/en/doc/harmonyos-references/js-apis-http)
- [AVRecorder](https://developer.huawei.com/consumer/en/doc/harmonyos-guides/using-avrecorder-for-recording/)
- [Recorder codecs and containers](https://developer.huawei.com/consumer/en/doc/doccenter-references/api/arkts-apis-media-i/)
- [User authentication](https://developer.huawei.com/consumer/en/doc/doccenter-references/api/js-apis-useriam-userauth/)

Validation state: API contracts and data/resource paths reviewed against the installed SDK. Current regular and explicit-preview API26 builds pass. The actual Previewer has exercised save failures, import structure/secure-storage refusal, retained primary connection and cleared input; secure-storage device readback, HMAC/TLS execution and durable recovery remain unverified. Native latency, thermal, biometric, background and transfer performance targets are not established by source, compiler or preview checks.
