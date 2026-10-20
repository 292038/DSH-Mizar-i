/**
 * The OpenAI-compatible engine — the kernel's default agent engine.
 *
 * Speaks the standard `POST /chat/completions` streaming shape, which
 * DeepSeek's API and most self-hosted gateways speak: `data:`-framed JSON
 * chunks, `delta.content` for text, `delta.reasoning_content` for reasoning,
 * `delta.tool_calls` for tool calls assembled by index, a final usage chunk
 * when the provider reports one.
 *
 * The adapter is stateless: one `runStep` call is one HTTP request. The API
 * key comes from the host key-value store (`apiKey.<providerId>`); a missing
 * key ends the step with code `MISSING_CREDENTIAL` — the same situation the
 * desktop host names in its `turn/end` error, so the client renders it the
 * same way.
 */

import { fromCallback, type PlatformHost } from '../host/host.ts'
import type {
  EngineAdapter,
  EngineDelta,
  EngineStepResult,
  EngineToolCall,
  EngineUsage,
} from './types.ts'
import type { KernelConfig, ProviderSpec } from '../core/config.ts'

const MAX_TOOL_CALLS = 64

interface AccumulatedCall {
  callId: string
  name: string
  arguments: string
}

export class OpenAICompatEngine implements EngineAdapter {
  readonly id = 'openai-compat'

  readonly #host: PlatformHost
  readonly #config: () => KernelConfig

  constructor(host: PlatformHost, config: () => KernelConfig) {
    this.#host = host
    this.#config = config
  }

  async runStep(request: {
    messages: readonly import('./types.ts').EngineMessage[]
    tools: readonly import('./types.ts').EngineToolSpec[]
    model: { provider: string; model: string; reasoningEffort?: string }
    onDelta: (delta: EngineDelta) => void
    signal: import('./types.ts').TurnSignal
  }): Promise<EngineStepResult> {
    const config = this.#config()
    const provider = config.providers.find((candidate) => candidate.id === request.model.provider)
    if (provider === undefined) {
      return errorStep(`no provider "${request.model.provider}" in the kernel configuration`, 'MODEL_UNAVAILABLE')
    }

    const stored = await fromCallback<string | null>((cb) => this.#host.kv.get(credentialKey(provider.id), cb))
    if (stored === null || stored === '') {
      return errorStep(
        `no API key for provider "${provider.id}"; store one with kernel.apiKey.set`,
        'MISSING_CREDENTIAL',
      )
    }

    const url = provider.baseUrl.replace(/\/+$/, '') + (provider.path ?? '/chat/completions')
    const payload: Record<string, unknown> = {
      model: request.model.model,
      messages: request.messages.map(wireMessage),
      stream: true,
    }
    if (request.tools.length > 0) {
      payload['tools'] = request.tools.map((tool) => ({
        type: 'function',
        function: { name: tool.name, description: tool.description, parameters: tool.parameters },
      }))
    }
    if (provider.usage === true) {
      payload['stream_options'] = { include_usage: true }
    }
    const effort = request.model.reasoningEffort
    if (effort !== undefined && effort !== '' && effort !== 'off') {
      payload['reasoning_effort'] = effort
    }

    return await new Promise<EngineStepResult>((resolve) => {
      let settled = false
      const finish = (result: EngineStepResult) => {
        if (settled) return
        settled = true
        resolve(result)
      }

      let text = ''
      let reasoning = ''
      const calls = new Map<number, AccumulatedCall>()
      let finishReason: string | null = null
      let usage: EngineUsage | undefined
      let buffer = ''
      let failure: { code?: string; message: string } | null = null

      const handle = this.#host.http.request(
        {
          url,
          method: 'POST',
          headers: {
            'content-type': 'application/json',
            authorization: `Bearer ${stored}`,
            accept: 'text/event-stream',
          },
          body: JSON.stringify(payload),
        },
        {
          onChunk: (chunk) => {
            if (request.signal.aborted || settled) return
            buffer += chunk
            let newline: number
            while ((newline = buffer.indexOf('\n')) !== -1) {
              const line = buffer.slice(0, newline).replace(/\r$/, '')
              buffer = buffer.slice(newline + 1)
              consumeLine(line)
            }
          },
          onDone: (status) => {
            if (request.signal.aborted) {
              finish(abortedResult())
              return
            }
            if (status !== 200) {
              finish(
                error(
                  `the engine answered HTTP ${status}`,
                  failure?.code,
                  failure?.message,
                ),
              )
              return
            }
            finish(buildResult())
          },
          onError: (message) => {
            if (request.signal.aborted) {
              finish(abortedResult())
              return
            }
            finish(error(failure?.message ?? message, failure?.code))
          },
        },
      )

      const consumeLine = (line: string) => {
        if (!line.startsWith('data:')) return
        const data = line.slice(5).trim()
        if (data === '') return
        if (data === '[DONE]') return
        let chunk: Record<string, unknown>
        try {
          chunk = JSON.parse(data) as Record<string, unknown>
        } catch {
          return // A split or non-JSON line is not a stream failure.
        }

        const choices = chunk['choices']
        if (Array.isArray(choices) && choices.length > 0) {
          const choice = choices[0] as Record<string, unknown>
          const delta = choice['delta']
          if (typeof delta === 'object' && delta !== null) {
            const fields = delta as Record<string, unknown>
            if (typeof fields['content'] === 'string' && fields['content'] !== '') {
              text += fields['content']
              request.onDelta({ text: fields['content'] })
            }
            const reasoningChunk = fields['reasoning_content'] ?? fields['reasoning']
            if (typeof reasoningChunk === 'string' && reasoningChunk !== '') {
              reasoning += reasoningChunk
              request.onDelta({ reasoning: reasoningChunk })
            }
            const toolChunks = fields['tool_calls']
            if (Array.isArray(toolChunks)) {
              for (const raw of toolChunks) {
                if (typeof raw !== 'object' || raw === null) continue
                const entry = raw as Record<string, unknown>
                const index = typeof entry['index'] === 'number' ? entry['index'] : calls.size
                const accumulated: AccumulatedCall = calls.get(index) ?? {
                  callId: '',
                  name: '',
                  arguments: '',
                }
                if (typeof entry['id'] === 'string' && entry['id'] !== '') accumulated.callId = entry['id']
                const fn = entry['function']
                if (typeof fn === 'object' && fn !== null) {
                  const fnFields = fn as Record<string, unknown>
                  if (typeof fnFields['name'] === 'string' && fnFields['name'] !== '') {
                    accumulated.name += fnFields['name']
                  }
                  if (typeof fnFields['arguments'] === 'string') {
                    accumulated.arguments += fnFields['arguments']
                  }
                }
                if (calls.size >= MAX_TOOL_CALLS && !calls.has(index)) continue
                calls.set(index, accumulated)
              }
            }
          }
          const reason = choice['finish_reason']
          if (typeof reason === 'string' && reason !== '') finishReason = reason
        }

        const reportedUsage = chunk['usage']
        if (typeof reportedUsage === 'object' && reportedUsage !== null) {
          usage = readUsage(reportedUsage as Record<string, unknown>)
        }

        // Some gateways report failures inside the stream as an error object.
        const streamError = chunk['error']
        if (typeof streamError === 'object' && streamError !== null) {
          const fields = streamError as Record<string, unknown>
          failure = {
            code: typeof fields['code'] === 'string' ? fields['code'] : undefined,
            message:
              typeof fields['message'] === 'string'
                ? fields['message']
                : 'the engine reported an error',
          }
        }
      }

      const buildResult = (): EngineStepResult => {
        if (request.signal.aborted) return abortedResult()
        if (failure !== null) {
          return error(failure.message, failure.code)
        }
        const toolCalls: EngineToolCall[] = [...calls.values()].map((call, index) => ({
          callId: call.callId !== '' ? call.callId : `call-${index}`,
          name: call.name,
          arguments: call.arguments,
        }))
        if (finishReason === 'tool_calls' || toolCalls.length > 0) {
          return {
            text,
            ...(reasoning !== '' ? { reasoning } : {}),
            toolCalls,
            ...(usage !== undefined ? { usage } : {}),
            finishReason: 'tool_calls',
          }
        }
        if (finishReason !== null && finishReason !== 'stop') {
          // A refusal, a length cap, whatever the provider names: not a stop,
          // not an error this layer can classify. Surface the reason verbatim.
          return error(`the engine stopped early (finish_reason: ${finishReason})`, 'REMOTE_ERROR')
        }
        return {
          text,
          ...(reasoning !== '' ? { reasoning } : {}),
          toolCalls,
          ...(usage !== undefined ? { usage } : {}),
          finishReason: 'stop',
        }
      }

      const abortedResult = (): EngineStepResult => ({
        text,
        ...(reasoning !== '' ? { reasoning } : {}),
        toolCalls: [],
        finishReason: 'aborted',
      })

      function error(message: string, code?: string, overrideMessage?: string): EngineStepResult {
        return {
          text: '',
          toolCalls: [],
          finishReason: 'error',
          ...(code !== undefined ? { errorCode: code } : {}),
          errorMessage: overrideMessage ?? message,
        }
      }

      function readUsage(fields: Record<string, unknown>): EngineUsage {
        const prompt = numberOr(fields['prompt_tokens'], 0)
        const completion = numberOr(fields['completion_tokens'], 0)
        const cached = numberOr(
          fields['prompt_cache_hit_tokens'] ?? fields['cache_read_tokens'],
          0,
        )
        const written = numberOr(
          fields['prompt_cache_miss_tokens'] ?? fields['cache_write_tokens'],
          0,
        )
        return {
          uncachedInputTokens: Math.max(0, prompt - cached - written),
          outputTokens: completion,
          cacheReadTokens: cached,
          cacheWriteTokens: written,
        }
      }
    })
  }
}

function numberOr(value: unknown, fallback: number): number {
  return typeof value === 'number' && Number.isFinite(value) ? value : fallback
}

/**
 * The kv key holding one provider's credential. The key prefix is storage
 * vocabulary, not a credential itself; the credential's value never
 * appears in source.
 */
function credentialKey(providerId: string): string {
  return `apiKey.${providerId}`
}

/** A step that ended in a failure this layer can name. */
function errorStep(message: string, code?: string, overrideMessage?: string): EngineStepResult {
  return {
    text: '',
    toolCalls: [],
    finishReason: 'error',
    ...(code !== undefined ? { errorCode: code } : {}),
    errorMessage: overrideMessage ?? message,
  }
}

/** One kernel message as the wire payload wants it. */
function wireMessage(message: import('./types.ts').EngineMessage): Record<string, unknown> {
  const wire: Record<string, unknown> = { role: message.role, content: message.content }
  if (message.role === 'tool' && message.toolCallId !== undefined) {
    wire['tool_call_id'] = message.toolCallId
  }
  if (message.role === 'assistant' && message.toolCalls !== undefined && message.toolCalls.length > 0) {
    wire['tool_calls'] = message.toolCalls.map((call) => ({
      id: call.callId,
      type: 'function',
      function: { name: call.name, arguments: call.arguments },
    }))
    // An assistant message that carries tool calls keeps its text in content;
    // an empty one must be null, which is what the API expects.
    if (message.content === '') wire['content'] = null
  }
  return wire
}
