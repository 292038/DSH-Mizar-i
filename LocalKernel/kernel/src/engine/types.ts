/**
 * The engine adapter boundary — where the kernel stops and an agent engine
 * starts.
 *
 * The desktop host delegates sessions to the DSH gateway; the kernel has no
 * gateway, so it defines the smallest interface that keeps the wire protocol
 * honest: **one adapter call is one step**. The turn runner drives the loop
 * (history assembly, records, tools, approvals, cancellation); an adapter only
 * has to turn a message list plus tool specs into the next assistant step,
 * streaming its deltas as they arrive.
 *
 * This is the same boundary the three desktop plugins drew between their
 * protocol layer and their engine (`CC-Mizar/src/claude/`, `codex/src/bridge/`):
 * everything engine-specific collapses into "drive the engine, stream the
 * deltas, name the tool calls". A future Claude Code or Codex adapter
 * implements this interface and the whole kernel above it is unchanged.
 */

/** One message as the engine sees it — already projected from the log. */
export interface EngineMessage {
  readonly role: 'system' | 'user' | 'assistant' | 'tool'
  /** The message's text content. */
  readonly content: string
  /** For `role: 'tool'`: the tool call this is the result of. */
  readonly toolCallId?: string
/** For `role: 'assistant'`: the tool calls the message carries. */
  toolCalls?: { callId: string; name: string; arguments: string }[]
}

/** A tool the engine may call, in JSON-Schema form. */
export interface EngineToolSpec {
  readonly name: string
  readonly description: string
  readonly parameters: Record<string, unknown>
}

/** One streamed delta. */
export interface EngineDelta {
  readonly text?: string
  readonly reasoning?: string
}

/** Cancellation the runner controls and the adapter must honor. */
export interface TurnSignal {
  readonly aborted: boolean
  onAbort(cb: () => void): void
}

/** One tool call the engine produced. */
export interface EngineToolCall {
  readonly callId: string
  readonly name: string
  /** The arguments as a JSON string — the desktop log's `tool/call` shape. */
  readonly arguments: string
}

/** Token usage as the desktop's `tokenUsage` projection counts it. */
export interface EngineUsage {
  readonly uncachedInputTokens: number
  readonly outputTokens: number
  readonly cacheReadTokens: number
  readonly cacheWriteTokens: number
}

/** The outcome of one engine step. */
export interface EngineStepResult {
  /** The step's final text, when it produced any. */
  readonly text: string
  /** The step's final reasoning text, when reported separately. */
  readonly reasoning?: string
  readonly toolCalls: readonly EngineToolCall[]
  readonly usage?: EngineUsage
  readonly finishReason: 'stop' | 'tool_calls' | 'aborted' | 'error'
  /** For `finishReason: 'error'`: a stable code when one is known. */
  readonly errorCode?: string
  readonly errorMessage?: string
}

/** One engine call = one step. */
export interface EngineAdapter {
  /** The adapter's identity, for `kernel.status` and logs. */
  readonly id: string
  runStep(request: {
    readonly messages: readonly EngineMessage[]
    readonly tools: readonly EngineToolSpec[]
    readonly model: { readonly provider: string; readonly model: string; readonly reasoningEffort?: string }
    /** Streamed deltas, called as they arrive — before the step resolves. */
    readonly onDelta: (delta: EngineDelta) => void
    readonly signal: TurnSignal
  }): Promise<EngineStepResult>
}
