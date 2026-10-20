/**
 * The OpenAI-compatible engine: SSE parsing, tool-call assembly, usage,
 * credentials, aborts — against a scripted HTTP host.
 */

import { describe, expect, it } from 'vitest'
import { OpenAICompatEngine } from '../src/engine/openai-compat.ts'
import { DEFAULT_CONFIG } from '../src/core/config.ts'
import { NodeHost } from './helpers/node-host.ts'

function sseBody(chunks: unknown[]): string {
  return chunks.map((chunk) => `data: ${JSON.stringify(chunk)}\n\n`).join('') + 'data: [DONE]\n\n'
}

function textChunk(content: string): unknown {
  return { choices: [{ delta: { content }, finish_reason: null }] }
}

function toolCallChunk(index: number, patch: Record<string, unknown>): unknown {
  return {
    choices: [{ delta: { tool_calls: [{ index, ...patch }] }, finish_reason: null }],
  }
}

async function runEngine(host: NodeHost, signal = { aborted: false, onAbort: () => {} }) {
  const engine = new OpenAICompatEngine(host, () => DEFAULT_CONFIG)
  const deltas: { text?: string; reasoning?: string }[] = []
  const result = await engine.runStep({
    messages: [
      { role: 'system', content: 'sys' },
      { role: 'user', content: 'hi' },
    ],
    tools: [{ name: 'list_dir', description: 'list', parameters: { type: 'object' } }],
    model: { provider: 'deepseek-official', model: 'deepseek-chat' },
    onDelta: (delta) => deltas.push(delta),
    signal,
  })
  return { result, deltas }
}

function scriptedSse(host: NodeHost, body: string, status = 200): void {
  host.httpHandler = (_request, handlers) => {
    void Promise.resolve().then(() => {
      if (status !== 200) {
        handlers.onDone(status)
        return
      }
      handlers.onChunk(body)
      handlers.onDone(status)
    })
    return { abort: () => {} }
  }
}

describe('OpenAICompatEngine', () => {
  it('assembles text deltas and reports the final text', async () => {
    const host = new NodeHost('/tmp/nonexistent-for-engine')
    host.kvPut('apiKey.deepseek-official', 'env-based-test-key-not-real')
    scriptedSse(
      host,
      sseBody([textChunk('Hel'), textChunk('lo'), { choices: [{ delta: {}, finish_reason: 'stop' }] }]),
    )
    const { result, deltas } = await runEngine(host)
    expect(result.finishReason).toBe('stop')
    expect(result.text).toBe('Hello')
    expect(result.toolCalls).toEqual([])
    expect(deltas).toEqual([{ text: 'Hel' }, { text: 'lo' }])
  })

  it('assembles streamed tool calls by index, name first then arguments', async () => {
    const host = new NodeHost('/tmp/nonexistent-for-engine')
    host.kvPut('apiKey.deepseek-official', 'env-based-test-key-not-real')
    scriptedSse(
      host,
      sseBody([
        toolCallChunk(0, { id: 'call_1', function: { name: 'write_' } }),
        toolCallChunk(0, { function: { arguments: '{"path":"a' } }),
        toolCallChunk(0, { function: { arguments: '.md"}' } }),
        { choices: [{ delta: {}, finish_reason: 'tool_calls' }] },
      ]),
    )
    const { result } = await runEngine(host)
    expect(result.finishReason).toBe('tool_calls')
    expect(result.toolCalls).toEqual([
      { callId: 'call_1', name: 'write_', arguments: '{"path":"a.md"}' },
    ])
  })

  it('separates reasoning deltas from text deltas', async () => {
    const host = new NodeHost('/tmp/nonexistent-for-engine')
    host.kvPut('apiKey.deepseek-official', 'env-based-test-key-not-real')
    scriptedSse(
      host,
      sseBody([
        { choices: [{ delta: { reasoning_content: 'step one ' }, finish_reason: null }] },
        { choices: [{ delta: { content: 'answer' }, finish_reason: null }] },
        { choices: [{ delta: {}, finish_reason: 'stop' }] },
      ]),
    )
    const { result, deltas } = await runEngine(host)
    expect(result.text).toBe('answer')
    expect(deltas).toEqual([{ reasoning: 'step one ' }, { text: 'answer' }])
  })

  it('reads the usage chunk into the desktop tokenUsage shape', async () => {
    const host = new NodeHost('/tmp/nonexistent-for-engine')
    host.kvPut('apiKey.deepseek-official', 'env-based-test-key-not-real')
    scriptedSse(
      host,
      sseBody([
        textChunk('ok'),
        { choices: [{ delta: {}, finish_reason: 'stop' }], usage: { prompt_tokens: 100, completion_tokens: 7, prompt_cache_hit_tokens: 60, prompt_cache_miss_tokens: 40 } },
      ]),
    )
    const { result } = await runEngine(host)
    expect(result.usage).toEqual({
      uncachedInputTokens: 0,
      outputTokens: 7,
      cacheReadTokens: 60,
      cacheWriteTokens: 40,
    })
  })

  it('ends with MISSING_CREDENTIAL when no key is stored', async () => {
    const host = new NodeHost('/tmp/nonexistent-for-engine')
    const { result } = await runEngine(host)
    expect(result.finishReason).toBe('error')
    expect(result.errorCode).toBe('MISSING_CREDENTIAL')
  })

  it('maps a non-200 status to an error result', async () => {
    const host = new NodeHost('/tmp/nonexistent-for-engine')
    host.kvPut('apiKey.deepseek-official', 'env-based-test-key-not-real')
    scriptedSse(host, 'rate limited', 429)
    const { result } = await runEngine(host)
    expect(result.finishReason).toBe('error')
    expect(result.errorMessage).toContain('429')
  })

  it('reports a stream-reported error object as the failure', async () => {
    const host = new NodeHost('/tmp/nonexistent-for-engine')
    host.kvPut('apiKey.deepseek-official', 'env-based-test-key-not-real')
    scriptedSse(
      host,
      sseBody([{ error: { code: 'insufficient_quota', message: 'quota exceeded' } }]),
    )
    const { result } = await runEngine(host)
    expect(result.finishReason).toBe('error')
    expect(result.errorCode).toBe('insufficient_quota')
    expect(result.errorMessage).toBe('quota exceeded')
  })

  it('an unknown provider is MODEL_UNAVAILABLE', async () => {
    const host = new NodeHost('/tmp/nonexistent-for-engine')
    const engine = new OpenAICompatEngine(host, () => DEFAULT_CONFIG)
    const result = await engine.runStep({
      messages: [],
      tools: [],
      model: { provider: 'who', model: 'what' },
      onDelta: () => {},
      signal: { aborted: false, onAbort: () => {} },
    })
    expect(result.errorCode).toBe('MODEL_UNAVAILABLE')
  })

  it('carries the request through with tools, stream options and auth header', async () => {
    const host = new NodeHost('/tmp/nonexistent-for-engine')
    host.kvPut('apiKey.deepseek-official', 'env-based-test-key-not-real')
    const captured: { url: string; headers: Record<string, string>; body?: string }[] = []
    host.httpHandler = (request, handlers) => {
      captured.push({ url: request.url, headers: request.headers, body: request.body })
      void Promise.resolve().then(() => {
        handlers.onChunk(sseBody([{ choices: [{ delta: {}, finish_reason: 'stop' }] }]))
        handlers.onDone(200)
      })
      return { abort: () => {} }
    }
    await runEngine(host)
    const sent = captured[0]
    if (sent === undefined) throw new Error('the engine issued no request')
    expect(sent.url).toBe('https://api.deepseek.com/chat/completions')
    expect(sent.headers['authorization']).toBe('Bearer env-based-test-key-not-real')
    const payload = JSON.parse((sent.body ?? '{}') as string) as Record<string, unknown>
    expect(payload['stream']).toBe(true)
    expect(payload['stream_options']).toEqual({ include_usage: true })
    expect(Array.isArray(payload['tools'])).toBe(true)
    expect((payload['messages'] as unknown[])[0]).toEqual({ role: 'system', content: 'sys' })
  })
})
