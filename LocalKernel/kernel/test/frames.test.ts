/**
 * The frame envelope: version handling, correlation, tolerance.
 */

import { describe, expect, it } from 'vitest'
import {
  encodeFrame,
  errorFrame,
  eventFrame,
  okFrame,
  parseClientFrame,
  isHelloFrame,
  PROTOCOL_VERSION,
} from '../src/protocol/frames.ts'
import { helloFrameText } from './helpers/harness.ts'

describe('parseClientFrame', () => {
  it('accepts a well-formed request', () => {
    const result = parseClientFrame('{"v":1,"id":"m1","type":"session.list"}')
    expect(result).toEqual({ ok: true, frame: { v: 1, id: 'm1', type: 'session.list' } })
  })

  it('carries the payload through untouched', () => {
    const result = parseClientFrame('{"v":1,"id":"m1","type":"session.messages","payload":{"sessionId":"s"}}')
    expect(result.ok && result.frame).toMatchObject({ payload: { sessionId: 's' } })
  })

  it('accepts a hello and keeps its optional fields', () => {
    // The frame comes from the harness's single hello constructor, which is
    // where the protocol's auth-field vocabulary lives; this test asserts
    // the optional fields survive the parse.
    const result = parseClientFrame(
      helloFrameText({ id: 'h1', appVersion: '1.0', deviceModel: 'iPhone', protocolVersion: 1 }),
    )
    expect(result.ok).toBe(true)
    if (result.ok && isHelloFrame(result.frame)) {
      expect(result.frame.id).toBe('h1')
      expect(result.frame.appVersion).toBe('1.0')
      expect(result.frame.deviceModel).toBe('iPhone')
      expect(result.frame.protocolVersion).toBe(1)
    } else {
      expect.unreachable()
    }
  })

  it('rejects a wrong version explicitly', () => {
    const result = parseClientFrame('{"v":2,"id":"m1","type":"session.list"}')
    expect(result).toMatchObject({ ok: false, code: 'PROTOCOL_VERSION_MISMATCH' })
  })

  it('rejects a version that is not a number', () => {
    const result = parseClientFrame('{"v":"1","id":"m1","type":"session.list"}')
    expect(result).toMatchObject({ ok: false, code: 'PROTOCOL_VERSION_MISMATCH' })
  })

  it('rejects non-JSON and non-objects with MALFORMED_FRAME', () => {
    expect(parseClientFrame('not json')).toMatchObject({ ok: false, code: 'MALFORMED_FRAME' })
    expect(parseClientFrame('[1,2]')).toMatchObject({ ok: false, code: 'MALFORMED_FRAME' })
    expect(parseClientFrame('null')).toMatchObject({ ok: false, code: 'MALFORMED_FRAME' })
  })

  it('rejects a request without an id', () => {
    expect(parseClientFrame('{"v":1,"type":"session.list"}')).toMatchObject({
      ok: false,
      code: 'MALFORMED_FRAME',
    })
  })

  it('rejects a hello without a token string', () => {
    expect(parseClientFrame('{"v":1,"type":"hello"}')).toMatchObject({ ok: false, code: 'MALFORMED_FRAME' })
  })
})

describe('server frames', () => {
  it('encode ok frames with the correlation id', () => {
    expect(JSON.parse(encodeFrame(okFrame('m1', { a: 1 })))).toEqual({ v: 1, id: 'm1', type: 'ok', result: { a: 1 } })
  })

  it('omit the result key when a method answers nothing', () => {
    const frame = JSON.parse(encodeFrame(okFrame('m1'))) as Record<string, unknown>
    expect('result' in frame).toBe(false)
  })

  it('encode error frames with code, message and retryable', () => {
    expect(JSON.parse(encodeFrame(errorFrame('REMOTE_ERROR', 'boom', 'm7', true)))).toEqual({
      v: 1,
      type: 'error',
      code: 'REMOTE_ERROR',
      message: 'boom',
      retryable: true,
      id: 'm7',
    })
  })

  it('welcome and event frames carry no id', () => {
    const welcome = JSON.parse(
      encodeFrame({
        v: PROTOCOL_VERSION,
        type: 'welcome',
        hostId: 'h',
        hostName: 'n',
        protocolVersion: 1,
        home: '/home',
        deviceId: 'd',
      }),
    ) as Record<string, unknown>
    expect('id' in welcome).toBe(false)
    const event = JSON.parse(encodeFrame(eventFrame('interactions.changed', { approvals: 0, questions: 0 }))) as Record<
      string,
      unknown
    >
    expect('id' in event).toBe(false)
    expect(event['event']).toBe('interactions.changed')
  })
})
