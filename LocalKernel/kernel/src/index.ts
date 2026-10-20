/**
 * The Mizar local kernel — public surface.
 *
 * An embedding creates a kernel with a {@link PlatformHost} and opens
 * connections; everything else happens through protocol frames. See
 * `LocalKernel/docs/kernel-api.md` for the complete wire contract.
 */

export { createKernel } from './kernel.ts'
export type { Kernel, KernelConnection } from './kernel.ts'
export { PROTOCOL_VERSION, ERROR_CODES } from './protocol/frames.ts'
export type { ClientFrame, ServerFrame, ErrorCode } from './protocol/frames.ts'
export type { PlatformHost, HostHttpRequest, HostHttpHandlers, HostKv, Callback } from './host/host.ts'
export { utf8ByteLength } from './host/host.ts'
export { DEFAULT_CONFIG } from './core/config.ts'
export type { KernelConfig, ProviderSpec, ModelSpec } from './core/config.ts'
export type { EngineAdapter, EngineMessage, EngineToolSpec, EngineStepResult, EngineUsage } from './engine/types.ts'
export { OpenAICompatEngine } from './engine/openai-compat.ts'
export { InteractionsBroker } from './core/interactions.ts'
export type {
  PendingApprovalView,
  PendingQuestionView,
  QuestionAnswerItem,
  QuestionItem,
} from './core/interactions.ts'
export { SessionStore } from './core/session-store.ts'
export type { SessionRow, SessionMeta } from './core/session-store.ts'
export { TurnRunner } from './core/turn-runner.ts'
export { builtinTools } from './core/tools.ts'
