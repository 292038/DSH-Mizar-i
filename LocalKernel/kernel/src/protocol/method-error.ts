/**
 * A method-level failure, adapted from `dsh-mizar` `src/bridge/method-error.ts`.
 *
 * A handler throws one of these when the request itself is at fault — a bad
 * payload, an unknown session, a model that is not in the catalog. Anything a
 * handler throws that is not a MethodError is a kernel bug and answers
 * `INTERNAL` rather than leaking internals.
 */

import type { ErrorCode } from './frames.ts'

export class MethodError extends Error {
  readonly code: ErrorCode
  readonly retryable: boolean

  constructor(code: ErrorCode, message: string, retryable = false) {
    super(message)
    this.name = 'MethodError'
    this.code = code
    this.retryable = retryable
  }
}

/**
 * The payload is not the shape the method's contract names.
 *
 * One factory keeps the messages uniform: the code is what the client branches
 * on, and the message is the sentence a support ticket quotes.
 */
export function malformed(message: string): MethodError {
  return new MethodError('MALFORMED_FRAME', message)
}

/** The named object does not exist. */
export function notFound(message: string): MethodError {
  return new MethodError('REMOTE_ERROR', message)
}

/** The kernel does not carry this surface. */
export function notImplemented(message: string): MethodError {
  return new MethodError('NOT_IMPLEMENTED', message)
}

/** Everything else a handler wants to say with a code. */
export function methodError(code: ErrorCode, message: string, retryable = false): MethodError {
  return new MethodError(code, message, retryable)
}
