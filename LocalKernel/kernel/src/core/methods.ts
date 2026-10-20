/**
 * The kernel's method table — every method the wire names, with the validation
 * the protocol document pins.
 *
 * The shapes and the refusal rules are the desktop host's (`dsh-mizar`
 * `src/bridge/index.ts`), because the client branches on them. Two rules worth
 * restating, they matter so much:
 *
 *  - **A payload field with the wrong type is `MALFORMED_FRAME`, never a
 *    silent default.** A call that changes host state must not guess.
 *  - **`afterSeq` has three states.** A number: only records after it.
 *    `null`: the caller holds nothing — full tail page, ledger ignored.
 *    Absent: use the delivery ledger. `undefined`, `null` and a number are
 *    three different requests.
 */

import type { MethodError } from '../protocol/method-error.ts'
import { malformed, methodError, notFound, notImplemented } from '../protocol/method-error.ts'
import type { ClientApprovalOutcome, QuestionAnswerItem } from './interactions.ts'
import {
  ACTIVITY_DEFAULT_ENTRIES,
  ACTIVITY_MAX_ENTRIES,
  activityEntryOf,
  collectToolNames,
  findRunningTurn,
  oldestPageSeq,
  oldestPageSeq as pageOldestSeq,
  summaryRecords,
  turnOf,
  withinActivityBudget,
  withinPageBudget,
  eventOf,
  recordSeq,
} from './records.ts'
import { buildStatsFrame } from './stats.ts'
import { permissionCatalog, PRESET_IDS } from './permissions.ts'
import type { KernelImpl } from '../kernel.ts'
import type { SelectedModel } from './session-store.ts'

/** What a method handler receives. */
export interface MethodContext {
  readonly kernel: KernelImpl
  /** The connected device the request came from, for the delivery ledger. */
  readonly deviceId: string
  /**
   * Register a hook to run after the ok frame has been delivered — the only
   * moment a page may move the delivery ledger's cursor.
   */
  onDelivered(hook: () => void): void
}

type Handler = (payload: unknown, ctx: MethodContext) => Promise<unknown>

/** The payload as an object, or a refusal. */
function payloadObject(payload: unknown, method: string): Record<string, unknown> {
  if (payload === undefined) return {}
  if (typeof payload !== 'object' || Array.isArray(payload) || payload === null) {
    throw malformed(`${method}: payload must be an object`)
  }
  return payload as Record<string, unknown>
}

function stringField(payload: Record<string, unknown>, method: string, field: string): string {
  const value = payload[field]
  if (typeof value !== 'string' || value === '') {
    throw malformed(`${method}: payload."${field}" must be a non-empty string`)
  }
  return value
}

function optionalNumber(payload: Record<string, unknown>, method: string, field: string): number | undefined {
  const value = payload[field]
  if (value === undefined) return undefined
  if (typeof value !== 'number' || !Number.isFinite(value) || value < 0 || Math.floor(value) !== value) {
    throw malformed(`${method}: payload."${field}" must be a non-negative number`)
  }
  return value
}

function optionalString(payload: Record<string, unknown>, method: string, field: string): string | undefined {
  const value = payload[field]
  if (value === undefined) return undefined
  if (typeof value !== 'string') {
    throw malformed(`${method}: payload."${field}" must be a string`)
  }
  return value
}

/** The newest raw window of a session's log. */
function rawWindow(
  records: readonly unknown[],
  maxMessages: number | undefined,
  beforeSeq: number | undefined,
): { window: unknown[]; hasMore: boolean } {
  const limit = maxMessages ?? 400
  let window = records as unknown[]
  if (beforeSeq !== undefined) {
    window = window.filter((record) => {
      const seq = recordSeq(record)
      return seq === null || seq < beforeSeq
    })
  }
  let hasMore = false
  if (window.length > limit) {
    hasMore = true
    window = window.slice(window.length - limit)
  } else {
    // Fewer records than the limit does not mean nothing older exists: the
    // client pages back with beforeSeq, and hasMore must say whether the log
    // continues below the window it read.
    const oldest = pageOldestSeq(window)
    hasMore = oldest !== null && oldest > 1
  }
  return { window, hasMore }
}

// ---------------------------------------------------------------------------
// The table
// ---------------------------------------------------------------------------

export function buildMethodTable(): Record<string, Handler> {
  return {
    'ping': async () => ({ pong: true }),

    'host.info': async (_payload, ctx) => {
      const identity = ctx.kernel.identity()
      return {
        hostId: identity.hostId,
        hostName: identity.hostName,
        home: identity.home,
        protocolVersion: ctx.kernel.protocolVersion,
      }
    },

    'workspace.list': async (_payload, ctx) => {
      const identity = ctx.kernel.identity()
      const sessions = ctx.kernel.store.list()
      return {
        items: [
          {
            workspaceId: 'kernel',
            name: 'Local workspace',
            path: `${identity.home}/workspace`,
            sessionIds: sessions.map((session) => session.sessionId),
          },
        ],
        complete: true,
      }
    },

    'session.list': async (_payload, ctx) => ({ items: ctx.kernel.store.list() }),

    'session.stats': async (payload, ctx) => {
      const fields = payloadObject(payload, 'session.stats')
      const sessionId = stringField(fields, 'session.stats', 'sessionId')
      const frame = buildStatsFrame(ctx.kernel.store, sessionId, ctx.kernel.config())
      if (frame === null) {
        throw notFound(`session.stats: no session "${sessionId}"`)
      }
      return frame
    },

    'session.messages': async (payload, ctx) => {
      const fields = payloadObject(payload, 'session.messages')
      const sessionId = stringField(fields, 'session.messages', 'sessionId')
      const maxMessages = optionalNumber(fields, 'session.messages', 'maxMessages')
      const beforeSeq = optionalNumber(fields, 'session.messages', 'beforeSeq')
      // afterSeq is three states, and `in` is what tells them apart.
      const hasAfterSeq = 'afterSeq' in fields
      const afterSeqValue = fields['afterSeq']
      if (hasAfterSeq && afterSeqValue !== null) {
        if (typeof afterSeqValue !== 'number' || !Number.isFinite(afterSeqValue) || afterSeqValue < 0) {
          throw malformed('session.messages: payload."afterSeq" must be a non-negative number or null')
        }
      }

      const store = ctx.kernel.store
      const meta = store.get(sessionId)
      if (meta === null) {
        // An unknown session is an empty answer, not an error — the desktop
        // answers the same way, and a client that raced an archive must not
        // see a failure for it.
        return { sessionId, asOfSeq: null, records: [], hasMore: false }
      }

      const { window, hasMore } = rawWindow(store.records(sessionId), maxMessages, beforeSeq)
      const summarized = summaryRecords(window)

      // Only what the caller does not already hold, and only when reading
      // forward: a backwards page ignores the cursor entirely.
      const floor =
        beforeSeq === undefined
          ? hasAfterSeq
            ? afterSeqValue === null
              ? -1
              : (afterSeqValue as number)
            : (ctx.kernel.ledger.deliveredThrough(ctx.deviceId, sessionId) ?? -1)
          : undefined
      const fresh =
        floor === undefined
          ? summarized
          : summarized.filter((record) => {
              const seq = recordSeq(record)
              // A record with no position cannot be proven old, so it travels.
              return seq === null || seq > floor
            })

      const sent = withinPageBudget(fresh)
      ctx.onDelivered(() => {
        ctx.kernel.ledger.recordResult(ctx.deviceId, sessionId, sent)
      })

      return {
        sessionId,
        asOfSeq: meta.lastSeq,
        records: sent,
        hasMore,
      }
    },

    'session.activity': async (payload, ctx) => {
      const fields = payloadObject(payload, 'session.activity')
      const sessionId = stringField(fields, 'session.activity', 'sessionId')
      const maxEntries = optionalNumber(fields, 'session.activity', 'maxEntries')
      const beforeSeq = optionalNumber(fields, 'session.activity', 'beforeSeq')
      let turn = optionalNumber(fields, 'session.activity', 'turn')
      if (beforeSeq !== undefined && turn === undefined) {
        throw malformed('session.activity: payload."turn" is required when "beforeSeq" is given')
      }
      if (turn !== undefined && beforeSeq === undefined) {
        // A turn without a cursor is ignored on the forward read, exactly as
        // the desktop documents it.
        turn = undefined
      }

      const store = ctx.kernel.store
      const meta = store.get(sessionId)
      if (meta === null) {
        return { sessionId, asOfSeq: null, turn: null, entries: [], hasMore: false, oldestSeq: null }
      }

      const records = store.records(sessionId)
      const limit = maxEntries === undefined || !Number.isFinite(maxEntries) || maxEntries < 1
        ? ACTIVITY_DEFAULT_ENTRIES
        : Math.min(ACTIVITY_MAX_ENTRIES, Math.floor(maxEntries))
      // The activity window is the newest 200 raw records, like the desktop's
      // ACTIVITY_PAGE_MESSAGES; backwards reads look before the cursor.
      const bound = beforeSeq !== undefined ? beforeSeq : undefined
      const window = records.filter((record) => {
        const seq = recordSeq(record)
        return seq === null || (bound === undefined || seq < bound)
      })
      const pageWindow = window.slice(Math.max(0, window.length - 200))

      const oldestSeq = oldestPageSeq(pageWindow)
      const pageHasMore = pageWindow.length > 0 && (() => {
        const oldest = pageOldestSeq(pageWindow)
        return oldest !== null && oldest > 1
      })()

      if (beforeSeq === undefined) {
        const running = findRunningTurn(pageWindow)
        if (running === null) {
          return { sessionId, asOfSeq: meta.lastSeq, turn: null, entries: [], hasMore: false, oldestSeq }
        }
        const callNames = collectToolNames(pageWindow)
        const mapped = []
        for (const record of pageWindow) {
          const event = eventOf(record)
          if (event === null || turnOf(event) !== running) continue
          const entry = activityEntryOf(record, callNames)
          if (entry !== null) mapped.push(entry)
        }
        const entries = withinActivityBudget(mapped.length > limit ? mapped.slice(mapped.length - limit) : mapped)
        return {
          sessionId,
          asOfSeq: meta.lastSeq,
          turn: running,
          entries,
          hasMore: entries.length !== mapped.length || pageHasMore,
          oldestSeq,
        }
      }

      // The backwards read: only the named turn's rows in the window.
      const callNames = collectToolNames(pageWindow)
      const mapped = []
      for (const record of pageWindow) {
        const event = eventOf(record)
        if (event === null || turnOf(event) !== turn) continue
        const entry = activityEntryOf(record, callNames)
        if (entry !== null) mapped.push(entry)
      }
      const entries = withinActivityBudget(mapped.length > limit ? mapped.slice(mapped.length - limit) : mapped)
      return {
        sessionId,
        asOfSeq: meta.lastSeq,
        turn,
        entries,
        hasMore: entries.length !== mapped.length || (pageHasMore && mapped.length > 0),
        oldestSeq,
      }
    },

    'session.create': async (payload, ctx) => {
      const fields = payloadObject(payload, 'session.create')
      const cwd = optionalString(fields, 'session.create', 'cwd')
      const sessionId = optionalString(fields, 'session.create', 'sessionId')
      const agentPreset = optionalString(fields, 'session.create', 'agentPreset')
      if (cwd !== undefined) {
        // The kernel manages its own sandboxes; a foreign cwd would promise a
        // directory the file tools cannot touch.
        const workspaceRoot = `${ctx.kernel.identity().home}/workspace`
        if (!cwd.startsWith(workspaceRoot)) {
          throw methodError(
            'REMOTE_ERROR',
            `session.create: the local kernel manages its own workspaces; omit "cwd" or pass the kernel workspace root (${workspaceRoot})`,
          )
        }
      }
      const meta = await ctx.kernel.store.create({
        ...(cwd !== undefined ? { cwd } : {}),
        ...(sessionId !== undefined ? { sessionId } : {}),
        ...(agentPreset !== undefined ? { agentPreset } : {}),
      })
      return { sessionId: meta.sessionId, agentPreset: meta.agentPreset ?? '' }
    },

    'session.prompt': async (payload, ctx) => {
      const fields = payloadObject(payload, 'session.prompt')
      const sessionId = stringField(fields, 'session.prompt', 'sessionId')
      const text = optionalString(fields, 'session.prompt', 'text')
      const mode = optionalString(fields, 'session.prompt', 'mode')
      if (mode !== undefined && mode !== 'queue' && mode !== 'steer') {
        throw malformed('session.prompt: payload."mode" must be "queue" or "steer"')
      }
      const attachmentIds = fields['attachmentIds']
      if (attachmentIds !== undefined) {
        if (!Array.isArray(attachmentIds) || attachmentIds.some((id) => typeof id !== 'string')) {
          throw malformed('session.prompt: payload."attachmentIds" must be an array of strings')
        }
        if (attachmentIds.length > 0) {
          throw notImplemented(
            'session.prompt: the local kernel does not support attachments yet',
          )
        }
      }
      if (text === undefined || text.trim() === '') {
        throw malformed('session.prompt: payload."text" must be a non-empty string')
      }
      if (ctx.kernel.store.get(sessionId) === null) {
        throw notFound(`session.prompt: no session "${sessionId}"`)
      }

      // The idempotency key: the caller's, or a fresh one. A repeated key is
      // the same prompt arriving twice — accepted once.
      const requestId = optionalString(fields, 'session.prompt', 'requestId') ?? ctx.kernel.host.uuid()
      const clientTimeZone = optionalString(fields, 'session.prompt', 'clientTimeZone')

      ctx.kernel.acceptPrompt(sessionId, {
        text,
        requestId,
        ...(clientTimeZone !== undefined ? { clientTimeZone } : {}),
      })
      return { accepted: true, requestId }
    },

    'session.cancel': async (payload, ctx) => {
      const fields = payloadObject(payload, 'session.cancel')
      const sessionId = stringField(fields, 'session.cancel', 'sessionId')
      if (ctx.kernel.store.get(sessionId) === null) {
        throw notFound(`session.cancel: no session "${sessionId}"`)
      }
      ctx.kernel.runner.cancel(sessionId)
      return { accepted: true }
    },

    'session.rename': async (payload, ctx) => {
      const fields = payloadObject(payload, 'session.rename')
      const sessionId = stringField(fields, 'session.rename', 'sessionId')
      const title = stringField(fields, 'session.rename', 'title')
      await ctx.kernel.store.rename(sessionId, title)
      return { renamed: true }
    },

    'session.archive': async (payload, ctx) => {
      const fields = payloadObject(payload, 'session.archive')
      const sessionId = stringField(fields, 'session.archive', 'sessionId')
      const stopActivity = fields['stopActivity']
      if (stopActivity !== undefined && typeof stopActivity !== 'boolean') {
        throw malformed('session.archive: payload."stopActivity" must be a boolean')
      }
      if (ctx.kernel.store.get(sessionId) === null) {
        throw notFound(`session.archive: no session "${sessionId}"`)
      }
      if (ctx.kernel.runner.isRunning(sessionId)) {
        if (stopActivity !== true) {
          // Refuse, never stop silently: archiving is about the session, and
          // a running turn is the operator's business.
          throw methodError(
            'REMOTE_ERROR',
            `session.archive: session "${sessionId}" still has a running turn; pass stopActivity to stop it`,
          )
        }
        ctx.kernel.runner.cancel(sessionId)
      }
      await ctx.kernel.store.archive(sessionId)
      ctx.kernel.ledger.forgetSession(sessionId)
      return { archived: true }
    },

    'model.catalog': async (_payload, ctx) => {
      const config = ctx.kernel.config()
      const providers = config.providers.map((provider) => ({
        id: provider.id,
        name: provider.name,
        models: provider.models.map((model) => ({
          id: model.id,
          name: model.name,
          ...(model.description !== undefined ? { description: model.description } : {}),
          ...(model.efforts !== undefined
            ? { efforts: model.efforts.map((effort) => ({ ...effort })), defaultEffort: model.defaultEffort ?? effortIdOf(model.efforts) }
            : {}),
        })),
      }))
      return {
        default: { ...config.defaultModel },
        providers,
        failures: [],
      }
    },

    'session.model.set': async (payload, ctx) => {
      const fields = payloadObject(payload, 'session.model.set')
      const sessionId = stringField(fields, 'session.model.set', 'sessionId')
      const providerId = stringField(fields, 'session.model.set', 'provider')
      const modelId = stringField(fields, 'session.model.set', 'model')
      const effort = optionalString(fields, 'session.model.set', 'reasoningEffort')

      const config = ctx.kernel.config()
      const provider = config.providers.find((candidate) => candidate.id === providerId)
      const model = provider?.models.find((candidate) => candidate.id === modelId)
      if (provider === undefined || model === undefined) {
        throw methodError(
          'MODEL_UNAVAILABLE',
          `session.model.set: ${providerId}/${modelId} is not in the available catalog`,
        )
      }
      const efforts = model.efforts ?? []
      const selected: SelectedModel = {
        provider: providerId,
        model: modelId,
        ...(effort !== undefined
          ? { reasoningEffort: effort }
          : efforts.length > 0
            ? { reasoningEffort: model.defaultEffort ?? efforts[0]?.id ?? 'off' }
            : {}),
      }
      await ctx.kernel.store.setModel(sessionId, selected)
      return { sessionId, selected }
    },

    'permissions.catalog': async () => permissionCatalog(),

    'session.permission.set': async (payload, ctx) => {
      const fields = payloadObject(payload, 'session.permission.set')
      const sessionId = stringField(fields, 'session.permission.set', 'sessionId')
      const preset = stringField(fields, 'session.permission.set', 'preset')
      if (!(PRESET_IDS as readonly string[]).includes(preset)) {
        throw methodError(
          'REMOTE_ERROR',
          `unknown preset "${preset}" (available: ${PRESET_IDS.join(', ')})`,
        )
      }
      await ctx.kernel.store.setPermission(sessionId, preset)
      return { commandResult: { preset } }
    },

    'interactions.pending': async (_payload, ctx) => ({
      approvals: ctx.kernel.broker.listApprovals(),
      questions: ctx.kernel.broker.listQuestions(),
    }),

    'approval.answer': async (payload, ctx) => {
      const fields = payloadObject(payload, 'approval.answer')
      const requestId = stringField(fields, 'approval.answer', 'requestId')
      const outcome = fields['outcome']
      if (outcome !== 'allowed-once' && outcome !== 'rejected') {
        throw malformed('approval.answer: payload."outcome" must be "allowed-once" or "rejected"')
      }
      const by = optionalString(fields, 'approval.answer', 'by')
      ctx.kernel.broker.answerApproval(requestId, outcome as ClientApprovalOutcome, by)
      return { accepted: true }
    },

    'question.answer': async (payload, ctx) => {
      const fields = payloadObject(payload, 'question.answer')
      const callId = stringField(fields, 'question.answer', 'callId')
      const answers = fields['answers']
      if (!Array.isArray(answers)) {
        throw malformed('question.answer: payload."answers" must be an array')
      }
      const pending = ctx.kernel.broker.listQuestions().find((batch) => batch.callId === callId)
      if (pending !== undefined) {
        // Each question is named exactly once — checked here, where the batch
        // shape is known, before the broker settles anything.
        const seen = new Set<string>()
        for (const item of answers) {
          if (typeof item !== 'object' || item === null) {
            throw malformed('question.answer: every answer must be an object')
          }
          const answerFields = item as Record<string, unknown>
          if (typeof answerFields['id'] !== 'string') {
            throw malformed('question.answer: every answer needs an "id"')
          }
          if (!Array.isArray(answerFields['selected'])) {
            throw malformed('question.answer: every answer needs a "selected" array')
          }
          if (seen.has(answerFields['id'])) {
            throw malformed(`question.answer: question "${answerFields['id']}" is answered twice`)
          }
          seen.add(answerFields['id'])
        }
        for (const question of pending.questions) {
          if (!seen.has(question.id)) {
            throw malformed(`question.answer: question "${question.id}" was not answered`)
          }
        }
      }
      ctx.kernel.broker.answerQuestion(callId, answers as readonly QuestionAnswerItem[])
      return { accepted: true }
    },

    // -- Push ------------------------------------------------------------
    //
    // A local kernel has no relay to deliver anything to, and the protocol
    // doc's rule is that the three push methods answer compatibly rather
    // than failing: a client must not have to know which kind of host it
    // reached.

    'push.register': async (payload) => {
      const fields = payloadObject(payload, 'push.register')
      // Validate exactly like the desktop does — a client bug must surface,
      // even though the registration itself is a no-op here.
      const token = stringField(fields, 'push.register', 'token')
      if (token === '') throw malformed('push.register: payload."token" must be non-empty')
      const platform = optionalString(fields, 'push.register', 'platform') ?? 'ios'
      if (platform !== 'ios' && platform !== 'android') {
        throw malformed('push.register: payload."platform" must be "ios" or "android"')
      }
      if (platform === 'ios') {
        const environment = fields['environment']
        if (environment !== 'sandbox' && environment !== 'production') {
          throw malformed('push.register: payload."environment" must be "sandbox" or "production" for platform "ios"')
        }
        const liveActivityToken = optionalString(fields, 'push.register', 'liveActivityToken')
        if (liveActivityToken !== undefined && !/^[0-9a-f]{1,200}$/.test(liveActivityToken)) {
          throw malformed('push.register: payload."liveActivityToken" must be 1-200 lowercase hex characters')
        }
      }
      return { registered: false }
    },

    'push.presence': async (payload) => {
      const fields = payloadObject(payload, 'push.presence')
      if (typeof fields['foreground'] !== 'boolean') {
        throw malformed('push.presence: payload."foreground" must be a boolean')
      }
      return { accepted: true }
    },

    'push.unregister': async () => ({ unregistered: true }),

    // -- Uploads ----------------------------------------------------------

    'upload.begin': async () => notImplementedUpload(),
    'upload.chunk': async () => notImplementedUpload(),
    'upload.finish': async () => notImplementedUpload(),
    'upload.abort': async () => notImplementedUpload(),

    // -- The kernel's own extension namespace -----------------------------
    //
    // These are local-kernel surfaces the desktop host does not have. The
    // GUI builds its settings screen on them; the protocol's unknown-method
    // tolerance means older clients simply never call them.

    'kernel.status': async (_payload, ctx) => {
      const identity = ctx.kernel.identity()
      return {
        kernelVersion: KERNEL_VERSION,
        protocolVersion: ctx.kernel.protocolVersion,
        engine: 'openai-compat',
        hostId: identity.hostId,
        home: identity.home,
        sessions: ctx.kernel.store.list().length,
      }
    },

    'kernel.config.get': async (_payload, ctx) => ({ config: ctx.kernel.config() }),

    'kernel.config.set': async (payload, ctx) => {
      const fields = payloadObject(payload, 'kernel.config.set')
      const patch: Record<string, unknown> = {}
      for (const key of ['providers', 'defaultModel', 'contextWindow', 'systemPromptAddendum', 'defaultPreset']) {
        if (key in fields) patch[key] = fields[key]
      }
      if (Object.keys(patch).length === 0) {
        throw malformed(
          'kernel.config.set: payload must name at least one of providers, defaultModel, contextWindow, systemPromptAddendum, defaultPreset',
        )
      }
      const config = ctx.kernel.updateConfig(patch)
      await ctx.kernel.persistConfig()
      return { config }
    },

    'kernel.apiKey.set': async (payload, ctx) => {
      const fields = payloadObject(payload, 'kernel.apiKey.set')
      const provider = stringField(fields, 'kernel.apiKey.set', 'provider')
      const key = stringField(fields, 'kernel.apiKey.set', 'key')
      if (!ctx.kernel.config().providers.some((candidate) => candidate.id === provider)) {
        throw methodError('MODEL_UNAVAILABLE', `kernel.apiKey.set: no provider "${provider}"`)
      }
      await thenSet(ctx, `apiKey.${provider}`, key)
      return { set: true }
    },

    'kernel.apiKey.clear': async (payload, ctx) => {
      const fields = payloadObject(payload, 'kernel.apiKey.clear')
      const provider = stringField(fields, 'kernel.apiKey.clear', 'provider')
      await thenDelete(ctx, `apiKey.${provider}`)
      return { cleared: true }
    },

    'kernel.apiKey.status': async (_payload, ctx) => {
      const providers = []
      for (const provider of ctx.kernel.config().providers) {
        const key = await thenGet(ctx, `apiKey.${provider.id}`)
        providers.push({ id: provider.id, name: provider.name, hasKey: key !== null && key !== '' })
      }
      return { providers }
    },
  }
}

function notImplementedUpload(): never {
  throw notImplemented('the local kernel does not support attachment uploads yet')
}

function effortIdOf(efforts: readonly { id: string }[]): string {
  return efforts[0]?.id ?? 'off'
}

// Small async helpers over the host kv, via the context's host handle.

function thenGet(ctx: MethodContext, key: string): Promise<string | null> {
  return new Promise((resolve, reject) => {
    ctx.kernel.host.kv.get(key, {
      ok: resolve,
      fail: (error) => reject(new Error(error.message)),
    })
  })
}

function thenSet(ctx: MethodContext, key: string, value: string): Promise<void> {
  return new Promise((resolve, reject) => {
    ctx.kernel.host.kv.set(key, value, {
      ok: () => resolve(),
      fail: (error) => reject(new Error(error.message)),
    })
  })
}

function thenDelete(ctx: MethodContext, key: string): Promise<void> {
  return new Promise((resolve, reject) => {
    ctx.kernel.host.kv.delete(key, {
      ok: () => resolve(),
      fail: (error) => reject(new Error(error.message)),
    })
  })
}

/** The kernel's own version, reported by `kernel.status`. */
export const KERNEL_VERSION = '0.1.0'

// Re-exported for the type surface of the table.
export type { MethodError }
