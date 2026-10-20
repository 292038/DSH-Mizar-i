# HTTP replay from HAR fixtures

`MizarKit` can answer HTTP from recordings instead of a host. This is the
replay test layer for HTTP, next to the fixture host the UI tests use: the bytes
a real host returned are stored as HAR 1.2 files, and a transport serves them
back to the existing clients.

- Layer: `HTTPReplayTransport` in `MizarKit/Sources/MizarKit/HTTPReplay.swift`
- Fixtures: `protocol/fixtures/http/*.har` (shared with anything else that reads them)
- Recorder: `scripts/record-http-fixtures.sh`
- Tests: `MizarKit/Tests/MizarKitTests/HTTPReplayTests.swift`

It is opt-in. `URLSessionHTTPTransport` remains the default the app builds, and
nothing here changes a production code path.

## What was already in place

The request "make the HTTP layer injectable" is satisfied before this change, so
no second abstraction was added:

| What | Where |
|---|---|
| HTTP seam | `PairingClient.swift` — `HTTPTransport` protocol + `URLSessionHTTPTransport` (the only production *HTTP* session) |
| Inject into pairing | `PairingClient.init(transport: any HTTPTransport = URLSessionHTTPTransport(), ...)` |
| Inject into account | `AccountClient.init(baseURL:transport: any HTTPTransport = URLSessionHTTPTransport())` |
| WebSocket seam | `WebSocketTransport.swift` — same pattern, `URLSessionWebSocketTransport` |
| `URLSession.shared` in app/library sources | 0 (`grep` below; the 20 hits are UI-test helpers, not app traffic) |

```sh
grep -rn 'URLSession\.shared' MizarKit/Sources DSH-Mizar DSH-Mizar-LiveActivity
# (no matches; all 20 `URLSession.shared` hits are in DSH-MizarUITests helpers)

grep -rn 'URLSession(' MizarKit/Sources
# PairingClient.swift:35        URLSessionHTTPTransport  <- the HTTP transport
# WebSocketTransport.swift:54  URLSessionWebSocketTransport
```

Every HTTP exchange the app makes already goes through the injected transport,
which is what made a replay transport additive instead of another seam.

## Why a transport, not a `URLProtocol`

`URLProtocol` was considered because it intercepts `URLSession` without changing
call sites. It is the weaker seam here for four reasons:

1. **A miss cannot be made structurally offline.** `URLProtocol` is asked to
   handle a request; if it returns `false`, the real network is used. Keeping
   replay offline is a convention inside `startLoading` (fail the task), and one
   forgotten code path or one new `URLSession` puts a test on the network. The
   replay transport has no `URLSession` member at all — a miss has nowhere to go
   but `HTTPReplayError.noFixture`.
2. **The injection point already exists and is used.** Clients take
   `any HTTPTransport`; tests already substitute scripted transports. A
   `URLProtocol` would add a second, process-global way to fake HTTP while the
   per-client seam stays the one the tests trust.
3. **Global registration breaks parallel tests.** `URLProtocol.registerClass` and
   `configuration.protocolClasses` are process-wide: two tests replaying
   different recordings would need serialization. A transport value is per test,
   which is why the suite in `HTTPReplayTests` runs in parallel like the rest.
4. **It only covers `URLSession`.** The WebSocket is a separate transport
   (`URLSessionWebSocketTask`); replaying it through `URLProtocol` is not
   supported. Keeping both seams as injected protocols means the recording story
   is one idea, not two.

The trade-off is explicit: replay works only where a transport is injected. In
this codebase that is exactly where HTTP is made — there is no third call site.

## The transport

```swift
let replay = try HTTPReplayTransport(fixturesDirectory: fixturesURL)
let pairing = PairingClient(transport: replay)
let account = AccountClient(baseURL: origin.appendingPathComponent("account/v1"),
                            transport: replay)
```

- **Hits** return the recorded status, headers and body as an `HTTPURLResponse`.
- **Misses** throw `HTTPReplayError.noFixture(method:url:)`. There is no retry,
  fallback, or silent skip.
- **Loading fails closed**: unreadable directory, no `.har` files, malformed HAR,
  bad base64, a non-HTTP status, or two recordings of the same request all throw
  at `init` time. A broken fixture set must not become a transport that misses
  every request.
- **Opt-in from the environment**: `HTTPReplayTransport.fromEnvironment()`
  returns `nil` when `MIZAR_HTTP_FIXTURES` is unset and throws when it is set but
  unusable. The composition root decides what to do with it:
  ```swift
  let transport = try HTTPReplayTransport.fromEnvironment() ?? URLSessionHTTPTransport()
  ```
- **Counters**: `await replay.stats()` reports `attempts`, `hits`, `misses`, and
  `networkAttempts` (always `0` — the type owns no session). The tests assert the
  number instead of trusting a comment.

### Matching rules

| Part | Rule |
|---|---|
| Method | case-insensitive equality (`POST` == `post`) |
| URL | absolute URL, exact by default (scheme, host, port, path, query) |
| Body | matched only when the fixture's `request.postData.text` exists; JSON is compared structurally (member order and whitespace are not content), otherwise byte-exact |
| Headers | not matched; they are recorded metadata |
| Duplicates | rejected at load when method, URL and recorded body are all identical: first-match-wins would make the answer depend on file names |

`HTTPReplayURLMatching.rewriting(recorded:requested:)` is the one deliberate
exception: it replaces a recorded origin with a requested one before matching, so
a recording made at `http://127.0.0.1:19395` can be replayed against
`http://10.255.255.1:19395`. That is how the offline proof in `HTTPReplayTests`
works: a route-null address can only have been answered from the fixture. It is
explicit because silently ignoring hosts would let a recording answer a request
for a different machine.

### HAR subset

Only what is needed to replay is read: `log.version` (must be `1.2`),
`entries[].request.{method,url,postData.text,postData.mimeType}`,
`entries[].response.{status,headers,content.text,content.encoding}`. Everything
else a real recording carries (`cookies`, `timings`, `cache`, pages, sizes)
decodes away, so a HAR exported from a browser proxy loads unchanged.

- `content.encoding: "base64"` is decoded; any other encoding is treated as UTF-8
  text, which is what a HAR written by hand uses.
- Repeated response headers collapse to the last value: `HTTPURLResponse` only
  carries a header dictionary.
- HAR is a container, not a scenario: a file may hold several entries, and every
  `.har` file in the directory is loaded (sorted by name for determinism).

## The fixtures

`protocol/fixtures/http/` holds three deterministic recordings made from
`scripts/mock-host.mjs`:

| File | Exchange | Why |
|---|---|---|
| `pair-success.har` | `POST /mizar/v1/pair` → 200 | the pairing body the app stores |
| `account-me.har` | `GET /account/v1/me` → 200 (bearer) | the profile the settings screen reads |
| `login-401.har` | `POST /account/v1/login` → 401 `UNAUTHENTICATED` | a refusal, with the request body recorded, so body matching is observable |

They are recorded at `http://127.0.0.1:19395`, the origin the app and the UI
tests dial.

### Regenerating

```sh
scripts/record-http-fixtures.sh        # starts the mock host on 19395, records, writes the .har files
git diff --exit-code protocol/fixtures/http   # must be empty: the recording is deterministic
```

The script normalises the values the mock host generates (account id and
timestamps become fixed constants, the HAR `startedDateTime` is fixed), so two
runs produce byte-identical files. It refuses to run if something is already
listening on 19395 — a reused host would change what is recorded. Node is needed
because the fixture host is Node; the app itself still has no dependency.

The pairing fixture deliberately records no request body: `PairingClient` fills
`appVersion` from its own bundle, which differs between the host test runner and
a device, and pinning it would make the recording replay only one of them.
Method + URL is the stable contract for that exchange.

### Recording from a real host instead

The transport reads ordinary HAR, so a browser/proxy capture works:

1. Put a recording proxy in front of the host (Charles, Proxyman, mitmproxy) or
   export the host's exchanges from the browser dev tools as HAR.
2. Save the file as `protocol/fixtures/http/<name>.har`.
3. Make sure every `request.url` is the absolute URL the app will dial
   (`http://127.0.0.1:19395/...` for the mock host, the relay origin for
   production), or pass `.rewriting(recorded:requested:)`.
4. Remove or replace volatile values (tokens, dates, ids) so the file is stable
   in git; JSON response bodies are just text, so any value is allowed as long as
   the model can decode it.
5. Run `scripts/swift.sh test`; a fixture the tests do not request is harmless,
   but an unrecorded request in a test is a loud miss — by design.

## Live layer

The live layer is the same switch the UI tests use, so one environment variable
turns both on:

```sh
MIZAR_TEST_MODE=live MIZAR_LIVE_BASE_URL=http://127.0.0.1:19395 scripts/swift.sh test
```

- Without both variables, `LiveNetworkTests` is skipped with
  `live layer: needs MIZAR_TEST_MODE=live and MIZAR_LIVE_BASE_URL`. The default
  run stays offline.
- With both, the suite dials `MIZAR_LIVE_BASE_URL` and calls the real `/hello`.
  A missing address is a skip rather than a failure, matching
  `TestLayer.requireValue` in the UI test target, so `--live` without an address
  does not fail the unit suite before the UI layer runs.
- `scripts/test-select.sh` exports `MIZAR_TEST_MODE=replay` for the unit suite
  too, which is why the gate reads that name.

## Verification

Measured in this working tree:

- `scripts/swift.sh build` — clean.
- `scripts/swift.sh test` — 487 tests in 61 suites pass, 9 of them the replay
  suite; `LiveNetworkTests` reports one skip without the live environment.
- Two consecutive `scripts/record-http-fixtures.sh` runs produce identical
  SHA-256 hashes for all three files.
- A live run against the mock host (`MIZAR_TEST_MODE=live
  MIZAR_LIVE_BASE_URL=http://127.0.0.1:19395 scripts/swift.sh test --filter
  LiveNetworkTests`) passes.

Unverified here: no capture from the production relay (the fixtures come from
the mock host), no on-device run, and the HAR subset is not the full 1.2 spec —
fields outside the table above are ignored on load.
