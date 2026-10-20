#!/usr/bin/env bash
#
# Record the HTTP fixtures that HTTPReplayTransport replays.
#
# Starts scripts/mock-host.mjs on the fixture port, performs three real
# exchanges against it, and writes HAR 1.2 files under protocol/fixtures/http/.
# The mock host generates an account id and timestamps at random, so the values
# this script records are normalised to fixed ones; the output is deterministic.
# Running this twice must leave the working tree unchanged:
#
#     scripts/record-http-fixtures.sh
#     git diff --exit-code protocol/fixtures/http
#
# The fixtures are recorded against the default port 19395 because that is the
# origin the app and the UI tests dial; recording on another port would produce
# files that replay nothing. Stop a manually started mock host first.
#
# Usage: scripts/record-http-fixtures.sh [port]
#
# Node is required (the mock host is Node); the app itself has no dependency.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PORT="${1:-19395}"
OUT="$ROOT/protocol/fixtures/http"
HELLO="http://127.0.0.1:${PORT}/mizar/v1/hello"

if curl -fsS -m 1 "$HELLO" >/dev/null 2>&1; then
  echo "record-http-fixtures: something already listens on port ${PORT}; stop it first" >&2
  exit 1
fi

mkdir -p "$OUT"
MOCK_LOG="$(mktemp -t mizar-record-mock.XXXXXX)"

cleanup() {
  if [[ -n "${MOCK_PID:-}" ]]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -f "$MOCK_LOG"
}
trap cleanup EXIT

( cd "$ROOT" && exec node scripts/mock-host.mjs "$PORT" ) >"$MOCK_LOG" 2>&1 &
MOCK_PID=$!

# The host answers as soon as it listens; poll rather than sleep a fixed time so
# the script stays fast on a quiet machine.
for _ in $(seq 1 100); do
  if curl -fsS -m 1 "$HELLO" >/dev/null 2>&1; then break; fi
  if ! kill -0 "$MOCK_PID" 2>/dev/null; then
    echo "record-http-fixtures: the mock host exited before it answered" >&2
    cat "$MOCK_LOG" >&2
    exit 1
  fi
  sleep 0.05
done
if ! curl -fsS -m 1 "$HELLO" >/dev/null 2>&1; then
  echo "record-http-fixtures: the mock host did not answer on port ${PORT}" >&2
  cat "$MOCK_LOG" >&2
  exit 1
fi

MIZAR_RECORD_PORT="$PORT" MIZAR_RECORD_OUT="$OUT" node --input-type=module <<'NODE'
// Recording half of scripts/record-http-fixtures.sh.
//
// Three exchanges, chosen because MizarKit's HTTP clients all speak one of them:
// a pairing success, an account profile, and the 401 a wrong password earns.
// Recording is done with fetch against the mock host, then written as HAR 1.2.

import { writeFileSync } from 'node:fs'
import { join } from 'node:path'

const port = Number(process.env.MIZAR_RECORD_PORT)
const out = process.env.MIZAR_RECORD_OUT
const origin = `http://127.0.0.1:${port}`

// Values the mock host derives from the clock or a random UUID. Fixed here so
// two recordings of the same protocol are byte-identical.
const FIXED_MS = 1_735_689_600_000 // 2025-01-01T00:00:00Z
const FIXED_ACCOUNT_ID = 'mock-account-0000-4000-8000-000000000000'
const DEVICE = {
  id: 'install-1',
  name: 'iPhone',
  model: 'iPhone18,1',
  platform: 'ios',
  appVersion: '0.9.2',
}

/** Perform one exchange and keep the exact text that went over the wire. */
async function exchange(method, path, { token, body } = {}) {
  const headers = { accept: 'application/json' }
  if (body !== undefined) headers['content-type'] = 'application/json'
  if (token) headers.authorization = `Bearer ${token}`
  const request = body === undefined ? undefined : JSON.stringify(body)
  const response = await fetch(origin + path, { method, headers, body: request })
  const text = await response.text()
  return { status: response.status, text, requestHeaders: headers, requestBody: request }
}

function expectStatus(label, got, want) {
  if (got !== want) throw new Error(`${label}: expected status ${want}, got ${got}`)
}

// 1. Pairing. The request body is deliberately not recorded: the app fills
// `appVersion` from its own bundle, which differs between the host test runner
// and a device, so method + URL is the part of this exchange that is stable.
const pair = await exchange('POST', '/mizar/v1/pair', {
  body: { code: 'MOCK-CODE', deviceName: 'iPhone', deviceModel: 'iPhone18,1', appVersion: '0.9.2', protocolVersion: 1 },
})
expectStatus('pair', pair.status, 200)

// 2. Account profile. The mock host starts with no accounts, so register once
// to get a token, then read /me exactly as AccountClient.me does.
const register = await exchange('POST', '/account/v1/register', {
  body: { username: 'mock-user', email: 'mock@example.com', password: 'mock-password', device: DEVICE },
})
expectStatus('register', register.status, 200)
const token = JSON.parse(register.text).token
if (!token) throw new Error('register: response has no token')

const me = await exchange('GET', '/account/v1/me', { token })
expectStatus('me', me.status, 200)
const profile = JSON.parse(me.text)
if (!profile.user) throw new Error('me: response has no user')
profile.user.id = FIXED_ACCOUNT_ID
profile.user.createdAt = FIXED_MS
profile.user.lastSeenAt = FIXED_MS
for (const device of profile.user.devices ?? []) {
  device.loginAt = FIXED_MS
  device.lastSeenAt = FIXED_MS
}
const meText = JSON.stringify(profile)

// 3. A refusal from the same API, with its request body recorded: this is the
// fixture that makes "same route, different credentials" observable in tests.
const login = await exchange('POST', '/account/v1/login', {
  body: { identifier: 'a@b.com', password: 'wrong-password', device: DEVICE },
})
expectStatus('login', login.status, 401)

// MARK: - HAR 1.2

/** The headers the mock host answers with on every route. */
function recordedResponseHeaders() {
  return [
    { name: 'content-type', value: 'application/json' },
    { name: 'cache-control', value: 'no-store' },
  ]
}

function recordedHeaders(headers) {
  return Object.entries(headers).map(([name, value]) => ({ name, value }))
}

/** One HAR entry; the fixed timestamp keeps the file byte-identical across runs. */
function entry({ method, path, headers, requestBody, sentBodySize, status, responseText }) {
  const contentSize = Buffer.byteLength(responseText, 'utf8')
  const bodySize = sentBodySize ?? (requestBody === undefined ? 0 : Buffer.byteLength(requestBody, 'utf8'))
  return {
    startedDateTime: '2026-01-01T00:00:00.000Z',
    time: 0,
    request: {
      method,
      url: origin + path,
      httpVersion: 'HTTP/1.1',
      cookies: [],
      headers: recordedHeaders(headers),
      queryString: [],
      headersSize: -1,
      bodySize,
      ...(requestBody === undefined
        ? {}
        : { postData: { mimeType: 'application/json', text: requestBody } }),
    },
    response: {
      status,
      statusText: status === 200 ? 'OK' : 'Unauthorized',
      httpVersion: 'HTTP/1.1',
      cookies: [],
      headers: recordedResponseHeaders(),
      content: { size: contentSize, mimeType: 'application/json', text: responseText },
      redirectURL: '',
      headersSize: -1,
      bodySize: contentSize,
    },
    cache: {},
    timings: { blocked: 0, dns: 0, connect: 0, send: 0, wait: 0, receive: 0, ssl: 0 },
  }
}

function write(name, entry) {
  const document = {
    log: {
      version: '1.2',
      creator: { name: 'record-http-fixtures.sh', version: '1' },
      entries: [entry],
    },
  }
  writeFileSync(join(out, name), JSON.stringify(document, null, 2) + '\n')
}

write('pair-success.har', entry({
  method: 'POST',
  path: '/mizar/v1/pair',
  headers: pair.requestHeaders,
  // The body was sent but is not recorded (see above), so the size is the only
  // truthful trace of it; `postData` staying absent is what makes the fixture
  // match a device whose app version differs from this recording.
  sentBodySize: Buffer.byteLength(pair.requestBody, 'utf8'),
  status: pair.status,
  responseText: pair.text,
}))

write('account-me.har', entry({
  method: 'GET',
  path: '/account/v1/me',
  headers: me.requestHeaders,
  status: me.status,
  responseText: meText,
}))

write('login-401.har', entry({
  method: 'POST',
  path: '/account/v1/login',
  headers: login.requestHeaders,
  requestBody: login.requestBody,
  status: login.status,
  responseText: login.text,
}))

console.log(`recorded 3 exchanges against ${origin} into ${out}`)
NODE
