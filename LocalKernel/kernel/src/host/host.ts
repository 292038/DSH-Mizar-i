/**
 * The platform host API — everything the kernel cannot do by itself.
 *
 * The kernel is platform-neutral TypeScript. It runs inside a JS engine
 * (JavaScriptCore on iOS, a JS engine on Android, Node for tests), and the
 * embedding platform injects one object shaped like this. Everything the kernel
 * touches outside pure computation goes through here, so the same kernel core
 * runs on every platform and in every test.
 *
 * Two deliberate shapes:
 *
 *  - **Callbacks, not promises, at the bridge.** Every engine exposes promise
 *    machinery differently, and a bridge that must construct and resolve native
 *    promise objects per call is the brittle part of an embedding. The host API
 *    is therefore plain callback style; the kernel wraps it into promises in
 *    exactly one place (`fromCallback()` below), where plain JavaScript can do it.
 *
 *  - **Paths are relative, and the sandbox is the host's job.** The kernel only
 *    ever names paths relative to its root (`'sessions/x/log.jsonl'`); the
 *    platform maps them onto its sandbox and refuses anything that escapes.
 *    The kernel never sees an absolute path except the display `home` string.
 */

/** The outcome side of a callback pair. */
export interface Callback<T> {
  ok(value: T): void
  fail(error: { message: string }): void
}

/** A host HTTP request the kernel issues — engine traffic, web fetches. */
export interface HostHttpRequest {
  readonly url: string
  readonly method: 'GET' | 'POST'
  readonly headers: Record<string, string>
  /** The request body, when the method is POST. Sent as UTF-8 text. */
  readonly body?: string
}

/** Incremental delivery of one response body. */
export interface HostHttpHandlers {
  /** A decoded UTF-8 piece of the response body, in order. */
  onChunk(text: string): void
  /** The request finished with this HTTP status. Called exactly once, last. */
  onDone(status: number): void
  /** The request failed before completing. Called exactly once, last. */
  onError(message: string): void
}

/** A small persistent string store — configuration, api keys, identity. */
export interface HostKv {
  get(key: string, cb: Callback<string | null>): void
  set(key: string, value: string, cb: Callback<void>): void
  delete(key: string, cb: Callback<void>): void
}

/**
 * The injected platform.
 *
 * `fs` paths are `/`-separated and relative to the kernel root; the root itself
 * never crosses the bridge. All fs and kv operations are async through
 * callbacks; everything else is synchronous.
 */
export interface PlatformHost {
  /** The kernel's display name — shown in the client's host list. */
  readonly hostName: string
  /** The kernel home directory, for display in the welcome frame. */
  readonly home: string
  /** The kernel's own version string, for logs and `kernel.status`. */
  readonly platformVersion: string

  readonly fs: {
    /** Read a UTF-8 text file; `null` when it does not exist. */
    readText(path: string, cb: Callback<string | null>): void
    /** Write a UTF-8 text file, creating parent directories; atomic. */
    writeText(path: string, data: string, cb: Callback<void>): void
    /** Append UTF-8 text to a file, creating it (and parents) when missing. */
    appendText(path: string, data: string, cb: Callback<void>): void
    /** Delete a file (not a directory); missing files count as deleted. */
    deletePath(path: string, cb: Callback<void>): void
    /** List a directory's entry names; `null` when it does not exist. */
    listDir(path: string, cb: Callback<string[] | null>): void
    /** Create a directory and every missing parent. */
    makeDir(path: string, cb: Callback<void>): void
  }

  readonly http: {
    /**
     * Issue one HTTP request with incremental body delivery.
     *
     * The handlers are called in order `onChunk*` then exactly one of
     * `onDone`/`onError`. The returned handle aborts the request; after an
     * abort exactly one of `onDone`/`onError` still fires.
     */
    request(
      request: HostHttpRequest,
      handlers: HostHttpHandlers,
    ): { abort(): void }
  }

  readonly kv: HostKv

  /** Structured log sink; the kernel never writes to stdout itself. */
  log(level: 'debug' | 'info' | 'warn' | 'error', message: string): void

  /** A fresh UUID (any collision-resistant form the platform provides). */
  uuid(): string

  /** Wall-clock epoch milliseconds. */
  now(): number

  /** The engine may lack timers, so the host provides them. */
  setTimeout(fn: () => void, ms: number): unknown
  clearTimeout(handle: unknown): void
}

/** A promise over a callback. Internal convenience — never crosses the bridge. */
export function fromCallback<T>(run: (cb: Callback<T>) => void): Promise<T> {
  return new Promise<T>((resolve, reject) => {
    run({
      ok: (value) => resolve(value),
      fail: (error) => reject(new Error(error.message)),
    })
  })
}

/**
 * UTF-8 byte length of a string, computed in pure JavaScript.
 *
 * Page budgets are about the bytes that leave the kernel, and a JS engine has
 * no `Buffer`; a character count would lie by threefold on CJK text. Surrogate
 * pairs are one code point and four bytes, matching every encoder's output for
 * well-formed strings.
 */
export function utf8ByteLength(text: string): number {
  let bytes = 0
  for (let index = 0; index < text.length; index += 1) {
    const code = text.charCodeAt(index)
    if (code >= 0xd800 && code <= 0xdbff && index + 1 < text.length) {
      const next = text.charCodeAt(index + 1)
      if (next >= 0xdc00 && next <= 0xdfff) {
        bytes += 4
        index += 1
        continue
      }
    }
    if (code <= 0x7f) bytes += 1
    else if (code <= 0x7ff) bytes += 2
    else bytes += 3
  }
  return bytes
}
