/**
 * The Mizar wire protocol, version 1 — the local kernel's side of it.
 *
 * Adapted from `dsh-mizar` `src/protocol/frames.ts` (GPL-3.0-only, © the dsh-mizar
 * authors): the local kernel speaks byte-for-byte the same protocol the desktop
 * host plugin speaks, which is what lets one unmodified client talk to either.
 * The parts that only exist for a network host (the pairing HTTP bodies, the
 * loopback probe) are not carried here; everything a client says on the socket
 * is.
 *
 * The contract's three rules survive unchanged:
 *
 *   - **Every frame carries `v`.** A peer that does not understand the version
 *     is told so explicitly instead of being fed fields it will misread.
 *   - **Requests carry `id`, responses echo it.** Server-initiated frames have
 *     no `id`, so the direction of a frame is unambiguous.
 *   - **Errors are codes, not prose.** The client renders localized text from
 *     the code; the message is for logs and support.
 */

/**
 * The protocol version this build speaks.
 *
 * **Adding an optional field to an existing payload is not a version bump.**
 * Changing what an existing field means, renaming one, or requiring a new one
 * *is* a bump.
 */
export const PROTOCOL_VERSION = 1

/**
 * Machine-readable failure codes.
 *
 * The same table the desktop host declares (`dsh-mizar src/protocol/frames.ts`),
 * so a client branches on one vocabulary everywhere. The kernel emits a subset
 * of these and answers `NOT_IMPLEMENTED` for the surfaces it does not carry.
 */
export const ERROR_CODES = [
  'PROTOCOL_VERSION_MISMATCH',
  'MALFORMED_FRAME',
  'UNAUTHENTICATED',
  'PAIRING_REQUIRED',
  'PAIRING_CODE_INVALID',
  'PAIRING_CODE_EXPIRED',
  'PAIRING_CODE_UNKNOWN',
  'RATE_LIMITED',
  'DEVICE_REVOKED',
  // The session is held by another writer. A local kernel has one writer (the
  // turn runner), so this only names a state the kernel can never be in while
  // it answers; kept for table parity with the desktop host.
  'WRITER_HELD',
  // The requested provider/model pair is not in the available catalog.
  'MODEL_UNAVAILABLE',
  // An engine call failed for a reason this layer does not classify. The
  // original code is preserved in the message.
  'REMOTE_ERROR',
  'NOT_IMPLEMENTED',
  'INTERNAL',
  /**
   * The answer exists but is too large to deliver.
   *
   * Its own code because it is not a fault in the request and not a bug in the
   * kernel: the answer is real and the transport cannot carry it. Saying so
   * lets the client ask for less instead of retrying the same thing.
   */
  'RESPONSE_TOO_LARGE',
  'UPLOAD_UNKNOWN',
  'UPLOAD_BAD_CHUNK',
  'UPLOAD_TOO_LARGE',
  'UPLOAD_INCOMPLETE',
  'ATTACHMENT_UNKNOWN',
  'ATTACHMENT_TOO_LARGE',
  'ATTACHMENT_UNSUPPORTED',
  'ATTACHMENT_FAILED',
] as const

/** One failure code. */
export type ErrorCode = (typeof ERROR_CODES)[number]

/** The `hello` frame: the first frame a client must send on a connection. */
export interface ClientHelloFrame {
  readonly v: typeof PROTOCOL_VERSION
  /**
   * Correlation id, echoed by nothing.
   *
   * A `welcome` frame carries no `id`: the kernel answers a `hello` once, and
   * the captured golden frame in `protocol/fixtures/welcome.json` is the record
   * of that. This field is accepted because a client may send one, not because
   * anything comes back with it.
   */
  readonly id?: string
  readonly type: 'hello'
  /**
   * The device token. A desktop host requires one from pairing; a local kernel
   * has nothing to pair with, so any token (including the empty string) is
   * accepted. Kept on the wire so the client's hello frame needs no change.
   */
  readonly token: string
  /** App marketing version, for logs. */
  readonly appVersion?: string
  /** Device model, for logs. */
  readonly deviceModel?: string
  /** The client's protocol version, so a mismatch is reported precisely. */
  readonly protocolVersion?: number
}

/**
 * A request that expects a correlated response.
 *
 * Method arguments live in `payload` rather than at the top level. Keeping the
 * envelope closed is what lets the frame types narrow.
 */
export interface ClientRequestFrame {
  readonly v: typeof PROTOCOL_VERSION
  readonly id: string
  readonly type: string
  /** Method-specific arguments; the method validates its own shape. */
  readonly payload?: unknown
}

/** Any frame a client may send. */
export type ClientFrame = ClientHelloFrame | ClientRequestFrame

/**
 * Narrow a client frame to `hello`.
 *
 * Written as a guard rather than relying on `frame.type === 'hello'`:
 * {@link ClientRequestFrame} carries `type: string`, so a plain comparison
 * yields an intersection that still includes the request branch.
 */
export function isHelloFrame(frame: ClientFrame): frame is ClientHelloFrame {
  return frame.type === 'hello'
}

/** The `welcome` frame: the kernel's answer to an accepted `hello`. */
export interface ServerWelcomeFrame {
  readonly v: typeof PROTOCOL_VERSION
  readonly type: 'welcome'
  /** Stable kernel identity, generated once per kernel home. */
  readonly hostId: string
  /** Human-readable kernel name — the device name the platform host reported. */
  readonly hostName: string
  /** The protocol version the kernel speaks. */
  readonly protocolVersion: number
  /** The kernel home directory, shown in the client's host details. */
  readonly home: string
  /**
   * The device id the presented token belongs to.
   *
   * A network host issues one per paired device. A local kernel has one client
   * in principle, so it answers with the id it generated at first boot.
   */
  readonly deviceId: string
}

/** A successful response to a correlated request. */
export interface ServerOkFrame {
  readonly v: typeof PROTOCOL_VERSION
  readonly id: string
  readonly type: 'ok'
  /** Method-specific payload; absent when the method has no result. */
  readonly result?: unknown
}

/** A failed response, or an unsolicited failure. */
export interface ServerErrorFrame {
  readonly v: typeof PROTOCOL_VERSION
  readonly id?: string
  readonly type: 'error'
  readonly code: ErrorCode
  readonly message: string
  /** Whether retrying the same request could succeed. */
  readonly retryable?: boolean
}

/** A kernel-initiated notification. */
export interface ServerEventFrame {
  readonly v: typeof PROTOCOL_VERSION
  readonly type: 'event'
  readonly event: string
  readonly data: unknown
}

/** Any frame the kernel may send. */
export type ServerFrame =
  | ServerWelcomeFrame
  | ServerOkFrame
  | ServerErrorFrame
  | ServerEventFrame

/** Outcome of validating an inbound frame. */
export type ParseResult =
  | { readonly ok: true; readonly frame: ClientFrame }
  | { readonly ok: false; readonly code: ErrorCode; readonly message: string }

/**
 * Encode a frame for the wire.
 */
export function encodeFrame(frame: ServerFrame): string {
  return JSON.stringify(frame)
}

/**
 * Build an error frame.
 */
export function errorFrame(
  code: ErrorCode,
  message: string,
  id?: string,
  retryable = false,
): ServerErrorFrame {
  return {
    v: PROTOCOL_VERSION,
    type: 'error',
    code,
    message,
    retryable,
    ...(id === undefined ? {} : { id }),
  }
}

/**
 * Build a success frame.
 */
export function okFrame(id: string, result?: unknown): ServerOkFrame {
  return { v: PROTOCOL_VERSION, type: 'ok', id, ...(result === undefined ? {} : { result }) }
}

/**
 * Build an event frame.
 */
export function eventFrame(event: string, data: unknown): ServerEventFrame {
  return { v: PROTOCOL_VERSION, type: 'event', event, data }
}

/**
 * Validate and narrow one inbound frame.
 *
 * Validation is intentionally strict about shape and permissive about payload:
 * a method that does not recognise a field must say so itself, because only the
 * method knows its own contract.
 */
export function parseClientFrame(raw: string): ParseResult {
  let parsed: unknown
  try {
    parsed = JSON.parse(raw)
  } catch {
    return { ok: false, code: 'MALFORMED_FRAME', message: 'frame is not valid JSON' }
  }

  if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
    return { ok: false, code: 'MALFORMED_FRAME', message: 'frame must be a JSON object' }
  }

  const record = parsed as Record<string, unknown>

  if (record['v'] !== PROTOCOL_VERSION) {
    const seen = record['v']
    return {
      ok: false,
      code: 'PROTOCOL_VERSION_MISMATCH',
      message: `expected protocol version ${PROTOCOL_VERSION}, received ${JSON.stringify(seen)}`,
    }
  }

  const type = record['type']
  if (typeof type !== 'string' || type === '') {
    return { ok: false, code: 'MALFORMED_FRAME', message: 'frame has no type' }
  }

  const id = record['id']
  if (id !== undefined && typeof id !== 'string') {
    return { ok: false, code: 'MALFORMED_FRAME', message: 'frame id must be a string' }
  }

  if (type === 'hello') {
    const token = record['token']
    if (typeof token !== 'string') {
      return { ok: false, code: 'MALFORMED_FRAME', message: 'hello frame has no token string' }
    }
    return {
      ok: true,
      frame: {
        v: PROTOCOL_VERSION,
        type: 'hello',
        token,
        ...(id === undefined ? {} : { id }),
        ...(typeof record['appVersion'] === 'string' ? { appVersion: record['appVersion'] } : {}),
        ...(typeof record['deviceModel'] === 'string' ? { deviceModel: record['deviceModel'] } : {}),
        ...(typeof record['protocolVersion'] === 'number'
          ? { protocolVersion: record['protocolVersion'] }
          : {}),
      },
    }
  }

  if (id === undefined || id === '') {
    return { ok: false, code: 'MALFORMED_FRAME', message: `frame "${type}" has no id` }
  }

  return {
    ok: true,
    frame: {
      v: PROTOCOL_VERSION,
      id,
      type,
      ...(record['payload'] === undefined ? {} : { payload: record['payload'] }),
    },
  }
}
