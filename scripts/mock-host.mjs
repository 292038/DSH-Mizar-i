/**
 * A stand-in host, for verifying UI that needs state the real host cannot be
 * asked to produce on demand.
 *
 * A pending approval only exists while an agent is blocked on a tool call, so
 * the only ways to see one are to catch it live or to fake it. Catching it live
 * depends on a model deciding to call a tool, which makes it useless as a test.
 * This serves the real protocol -- the same frames, the same shapes, taken from
 * the recorded fixtures -- so the app renders actual decoded responses rather
 * than a special-cased path.
 *
 * It is a test fixture, not a host: it authenticates nothing and stores nothing.
 *
 * Usage: node scripts/mock-host.mjs [port]
 */
import { createServer } from 'node:http'
import ws from '../node_modules/ws/index.js'

const { WebSocketServer } = ws

const port = Number(process.argv[2] ?? 19395)
const CODE = 'MOCK-CODE'

/**
 * Which machine this instance is pretending to be.
 *
 * A phone that is paired with two Macs draws one Mac's state under another's
 * name unless every read is tagged with the machine it came from, and one mock
 * on one port cannot tell that apart from a working app: both hosts would answer
 * with the same host id, the same sessions and the same providers. Running a
 * second instance on another port is what makes "this belongs to that Mac"
 * observable, so the identity is derived from the port rather than fixed.
 *
 * 19395 stays exactly what it was -- every existing test measures *that* Mac.
 */
const SECOND_IDENTITY = port === 19396

/** This machine's id, as it reports at pairing and in `welcome`. */
const HOST_ID = SECOND_IDENTITY
  ? 'mock-host-1111-4000-8000-000000000000'
  : 'mock-host-0000-4000-8000-000000000000'
/** This machine's own name, which is the only label on screen that differs. */
const HOST_NAME = SECOND_IDENTITY ? 'Mock Mac (second)' : 'Mock Mac (fixture)'
/** The device id this machine issues at pairing. */
const DEVICE_ID = SECOND_IDENTITY
  ? 'mock-device-1111-4000-8000-000000000000'
  : 'mock-device-0000-4000-8000-000000000000'
// A real host rarely has pending requests and a conversation at the same time;
// the flag lets each be seen on its own.
/**
 * Whether a pending approval and question are on offer.
 *
 * A launch flag, and switchable at runtime by `/reset`. The two cards take most
 * of a phone screen, which is right -- an agent blocked on a decision is the
 * most urgent thing there is -- but it leaves a test about the conversation
 * measuring a screenful of card. A test says which it wants.
 */
let withPending = process.env['MIZAR_MOCK_PENDING'] !== '0'

/**
 * How long to stall every answer, in milliseconds.
 *
 * For the two screens that exist to say how long something is taking, and which
 * are therefore impossible to observe against a mock that answers instantly: a
 * progress bar that appears and vanishes inside one runloop turn is a progress
 * bar no test can see. Set by `/reset?slow=NNN`, and zero otherwise so the rest
 * of the suite is not slowed down for it.
 */
let answerDelayMs = 0

/**
 * Whether the mock should refuse every connection.
 *
 * A Mac that is asleep, or on a network that has gone away. Switchable at
 * runtime by `/offline?on=1` so a test can take the host away *after* the phone
 * has synced from it -- which is the only way to check that an unreachable Mac
 * does not take away what the phone already stored.
 */
let offline = false

/**
 * A method whose answers should fail from now on, until `/reset`.
 *
 * For the screens that read the same thing more than once. `session.stats` is
 * re-read every time a session screen reloads, and a failure used to erase the
 * model and context figures that an earlier read had already put on screen --
 * "刚点进去一个会话，然后该会话的标题、正在使用的模型、上下文用量显示全部消失".
 * Arming this after the first read has landed is what makes that reproducible:
 * `/fail?method=session.stats`.
 */
let failMethod = null

/**
 * Whether `session.stats` should answer like a session whose agent is cold.
 *
 * Each field of that frame comes from its own projection on the host, and a
 * projection answers with what it has right now: a cold session has a token
 * meter and nothing else -- no title, no model selection, no context pressure.
 * So this is not a broken answer, it is an *ordinary* one, and a screen that
 * replaces what it has with it loses three figures it was already showing.
 * `/stats?variant=cold` and back with `/stats?variant=full`.
 */
let statsVariant = 'full'

/**
 * A clock offset, in milliseconds, applied to every record the mock sends.
 *
 * The host's clock and the phone's are two clocks, and the app does arithmetic
 * across them: a running turn's start comes off the host, `now` off the phone.
 * A Mac whose clock is ahead is the case that produced a negative duration on
 * screen, and it cannot be reproduced by a fixture whose times are all the
 * phone's. Set by `/reset?skew=NNN`.
 */
let clockSkewMs = 0

/**
 * The largest `maxMessages` the mock will answer, when a test sets one.
 *
 * The host refuses an answer it cannot deliver with `RESPONSE_TOO_LARGE` rather
 * than sending it and closing the socket, and the client's answer to that is to
 * ask for less. `Infinity` unless `/reset?pageLimit=NNN` says otherwise.
 */
let pageLimit = Infinity

/**
 * Whether the mock's main session reports itself as running.
 *
 * The Live Activity has two states, and the finished one -- a check, and the
 * words "every session has finished" -- is only ever reached by *updating* an
 * activity that was started while something was running. Flipping this at
 * runtime is the only way to get there without waiting for an agent to stop.
 */
let sessionRunning = true

/**
 * How many WebSocket connections the mock has accepted since the last reset.
 *
 * A reconnect is invisible from the app's screen -- the data looks the same
 * afterwards -- so the only way to assert that a failure did *not* cost a fresh
 * socket is to count them from the host's side.
 */
let connections = 0

/**
 * How many frames the mock has answered, by method, since the last reset.
 *
 * A second load on one socket is invisible from the app's side -- every request
 * is answered, and the screen settles on the same content -- so "one load was in
 * flight, not two" can only be asserted by counting what the host was actually
 * asked. `session.messages` is the read that two overlapping loads both make.
 */
const methodCounts = {}

/**
 * One method whose answers are stalled, while the rest answer immediately.
 *
 * `/slow` stalls *every* method, which also stalls the launch, the send and the
 * reads that carry the screen the assertion is about -- so a test that wants two
 * loads to overlap ends up measuring a stalled app instead. Naming the method
 * makes the overlap reachable: the reload being observed is slow, and everything
 * the test needs in order to start a second load is not.
 */
let slowMethod = null

/**
 * How many `session.messages` reads are being answered at once, and the most
 * that ever were.
 *
 * Two loads overlapping on one socket is the failure this counts, and neither
 * the screens nor the answers can show it: both requests are answered correctly
 * and the conversation that settles on screen is the same one. In flight at the
 * same time is the whole of the defect, so the count is read at the host, where
 * it is a fact.
 */
let messagesInFlight = 0
let messagesPeak = 0

/**
 * Whether `session.messages` answers are being held, and what is waiting.
 *
 * A stall is a race: a delay long enough to be measured on a loaded machine is a
 * delay long enough for the thing being overlapped to have finished first. Held,
 * the answer waits for the test to release it, so "the reload is still in
 * flight" is a fact rather than a hope -- which is what makes the assertion
 * about a *second* load landing on top of it deterministic.
 */
let holdingMessages = false
let heldMessages = []

/** Every `session.model.set` the mock was asked to make, in order. */
const modelSets = []
/** How many times each method was refused, by method. */
const refusedCounts = {}

// Declared before the two interaction fixtures, which carry its session id.
const SESSION = {
  sessionId: SECOND_IDENTITY ? 'session-mock-second' : 'session-mock-0001',
  cwd: '/Users/you/projects/demo',
  // Epoch milliseconds, which is what the host reports.
  updatedAt: Date.now() - 120_000,
  running: true,
  blank: false,
  agentAvailable: true,
  parentSessionId: null,
  origin: null,
}

/** A pending approval, shaped like the one the bridge builds. */
const APPROVAL = {
  requestId: 'a1b2c3d4-0000-4000-8000-000000000001',
  sessionId: SESSION.sessionId,
  toolName: 'write_file',
  callId: 'call-1',
  reason: 'Writing to a path outside the workspace',
  displayReason: {
    en: 'Writing to a path outside the workspace',
    zh: '正在写入工作区之外的路径',
  },
  requestedAt: Date.now() / 1000,
}

/** A question batch, including a plan review, which is the interesting shape. */
const QUESTION = {
  callId: 'call-2',
  sessionId: SESSION.sessionId,
  requestedAt: Date.now() / 1000,
  questions: [
    {
      id: 'q1',
      header: 'Approach',
      question: 'How should I handle the schema change?',
      detail: 'The migration is not reversible without a backup.',
      multiSelect: false,
      options: [
        { label: 'Migrate in place', description: 'Fast, and needs a backup first.' },
        { label: 'Add a new column', description: 'Slower, and reversible.' },
      ],
    },
    {
      id: 'q2',
      header: 'Plan',
      question: 'Proceed with this plan?',
      intent: { kind: 'plan-review', approve: 'Approve plan' },
      multiSelect: false,
      options: [{ label: 'Approve plan', description: 'Start implementing.' }],
    },
  ],
}

/** A session whose working directory the host has no workspace for.
 *
 * The shape of the bug: deleting a workspace removes the host's registry entry
 * and leaves the session log on disk, so `session.list` keeps returning it. A
 * phone that grouped sessions by working directory drew a row for a workspace
 * that had been deleted.
 */
const ORPHANED_SESSION = {
  sessionId: SECOND_IDENTITY ? 'session-mock-second-orphan' : 'session-mock-orphan',
  cwd: '/Users/you/projects/deleted-workspace',
  updatedAt: Date.now() - 900_000,
  running: false,
  blank: false,
  agentAvailable: false,
  parentSessionId: null,
  origin: null,
}

/**
 * The second session's conversation, which says different things.
 *
 * One view draws every session, so every value it holds has to belong to the
 * session it was filled from -- and a fixture where both sessions answer with
 * the same page cannot tell "the tag works" from "the tag is ignored", because
 * the screen looks right either way. This one is deliberately *unlike* the
 * other: its own prompt and answer, and `hasMore: true` on the newest page so
 * that "can older history still be asked for" is state that differs between the
 * two sessions too.
 *
 * - Parameter beforeSeq: the position the client is paging back from, or `null`
 *   for the newest page.
 * - Returns: one page, in the shape `session.messages` answers with.
 */
function orphanMessages(beforeSeq) {
  const now = Date.now()
  // Positions descend as the pages get older, so the client's `oldestSeq`
  // arithmetic -- and its decision to stop -- sees what a real log looks like.
  let counter = beforeSeq === null ? 900 : 780
  const record = (type, data) => {
    counter += 1
    return {
      type: 'event',
      event: { type, seq: counter, time: now + clockSkewMs - (950 - counter) * 1000, data },
    }
  }
  if (beforeSeq !== null) {
    // The page before the one the phone already has. One finished turn, and
    // nothing older behind it.
    return {
      sessionId: ORPHANED_SESSION.sessionId,
      asOfSeq: 790,
      hasMore: false,
      records: [
        record('turn/start', { turn: 1 }),
        record('step/start', { turn: 1, step: 1 }),
        record('user/message', {
          content: [{ type: 'text', text: 'Older history from the other session.' }],
          source: { kind: 'user' },
          role: 'user',
          id: 'orphan-m1',
        }),
        record('assistant/message', {
          turn: 1,
          step: 1,
          message: {
            role: 'assistant',
            content: [{ type: 'text', text: 'Answered a long time ago.' }],
          },
        }),
        record('turn/end', { turn: 1, reason: { kind: 'completed' } }),
      ],
    }
  }
  return {
    sessionId: ORPHANED_SESSION.sessionId,
    asOfSeq: 910,
    hasMore: true,
    records: [
      record('turn/start', { turn: 2 }),
      record('step/start', { turn: 2, step: 1 }),
      record('user/message', {
        content: [{ type: 'text', text: 'A prompt from the other session.' }],
        source: { kind: 'user' },
        role: 'user',
        id: 'orphan-m2',
      }),
      record('assistant/message', {
        turn: 2,
        step: 1,
        message: {
          role: 'assistant',
          content: [{ type: 'text', text: 'A different session, a different answer.' }],
        },
      }),
      record('turn/end', { turn: 2, reason: { kind: 'completed' } }),
    ],
  }
}

/**
 * The main conversation's prompt and answer on this machine.
 *
 * Deliberately different on the second instance. A test that switches Macs has
 * to be able to say *whose* conversation is on screen, and two hosts serving the
 * same text cannot answer that -- the screen looks the same whichever machine's
 * page was drawn under it.
 */
const MAIN_PROMPT = SECOND_IDENTITY
  ? 'The second Mac’s own prompt, and nothing else.'
  : 'Refactor the parser and run the tests.'
const MAIN_ANSWER = SECOND_IDENTITY
  ? 'The second Mac answered this one.'
  : 'The parser is now two files.'

/**
 * Prompts the client has sent, in order.
 *
 * The mock used to answer every prompt with `accepted` and then return a fixed
 * log, so a sent message never appeared in the conversation -- which made the
 * send path untestable and, worse, would have let a real defect through: the app
 * did not refresh the conversation after sending, so a message did not show up
 * until the operator pulled to refresh.
 */
const sentPrompts = []
/**
 * Sessions the phone started with `session.create`, and what was said in each.
 *
 * Kept apart from the fixture's own session so a test that starts one sees a
 * conversation of its own -- its first prompt and nothing else -- and so
 * `/reset` can put the list back as it was.
 */
const createdSessions = []

/** Answer one client frame. */
function answer(frame) {
  const { id, type } = frame
  if (type === failMethod) {
    // Counted before the refusal, not after it. A refused method is the one a
    // test is most likely to be counting -- "did the app ask at all" -- and a
    // count that skipped it answered zero for a request that did arrive.
    refusedCounts[type] = (refusedCounts[type] ?? 0) + 1
    console.log('mock: refused ->', type)
    return { v: 1, type: 'error', code: 'INTERNAL', message: 'failed on purpose', id }
  }
  switch (type) {
    case 'hello':
      return {
        v: 1,
        type: 'welcome',
        id,
        hostId: HOST_ID,
        hostName: HOST_NAME,
        protocolVersion: 1,
        home: '/Users/you',
        deviceId: DEVICE_ID,
      }
    case 'workspace.list':
      // The host's own workspace registry, which is not the session list: a
      // session outlives the workspace it was created in, so a phone that
      // grouped on the working directory drew rows for workspaces that had been
      // deleted. `deleted-workspace` deliberately has a session and no
      // workspace, so a test can tell "filtered by the host's list" from
      // "grouped by cwd" -- on the session list *and* in the new-session picker.
      //
      // `fresh` deliberately holds no sessions: it is on the Mac's sidebar, so
      // it has to be on the phone's list and in the count the refresh sheet
      // reports. `complete` is the host saying so -- without it the phone may
      // only add, which is what kept deleted workspaces on screen.
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          items: [
            {
              workspaceId: 'ws-demo',
              path: SESSION.cwd,
              title: 'demo',
              sessionIds: [
                SESSION.sessionId,
                ...createdSessions.filter((c) => c.cwd === SESSION.cwd).map((c) => c.sessionId),
              ],
            },
            { workspaceId: 'ws-fresh', path: '/Users/you/projects/fresh', title: 'fresh', sessionIds: [] },
          ],
          complete: true,
        },
      }
    case 'session.list':
      // Two sessions, one of them in a directory `workspace.list` does not
      // mention, so a test can tell "filtered by the host's workspace list"
      // apart from "grouped by working directory".
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          items: [
            ...createdSessions.map(({ prompts, ...row }) => row),
            { ...SESSION, running: sessionRunning },
            ORPHANED_SESSION,
          ],
        },
      }
    case 'interactions.pending':
      return {
        v: 1,
        type: 'ok',
        id,
        result: withPending ? { approvals: [APPROVAL], questions: [QUESTION] } : { approvals: [], questions: [] },
      }
    case 'session.stats':
      // A frame per session, because the app draws one session at a time out of
      // one view: a title that is the same for both cannot show whether the
      // figures on screen belong to the session they were read for.
      // A session the phone started has no figures yet: a frame with nothing
      // in it, which is what a real host answers for a session that has not run.
      if (createdSessions.some((c) => c.sessionId === frame.payload?.sessionId)) {
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId: frame.payload.sessionId,
            asOfSeq: 1,
            stats: {
              title: 'Started from the phone',
              tokenUsage: null,
              cacheHit: null,
              context: null,
              stats: null,
              model: null,
              permissionPreset: null,
            },
          },
        }
      }
      if (frame.payload?.sessionId === ORPHANED_SESSION.sessionId) {
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId: ORPHANED_SESSION.sessionId,
            asOfSeq: 910,
            stats: {
              title: 'Orphan session',
              tokenUsage: null,
              cacheHit: null,
              context: null,
              stats: null,
              model: null,
              permissionPreset: null,
            },
          },
        }
      }
      // The cold shape: the same frame with every projection that needs a warm
      // agent left empty. See `statsVariant`.
      if (statsVariant === 'cold') {
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId: SESSION.sessionId,
            asOfSeq: 17,
            stats: {
              title: null,
              tokenUsage: {
                uncachedInputTokens: 12_480,
                outputTokens: 3_712,
                cacheReadTokens: 180_320,
                cacheWriteTokens: 4_096,
                billedInputTokens: 196_896,
              },
              cacheHit: null,
              context: null,
              stats: null,
              model: null,
              permissionPreset: null,
            },
          },
        }
      }
      // Field names and nesting copied from the fixture recorded off a live
      // host. The first version of this used plausible-looking names that the
      // client could not decode, so the usage screen silently rendered "no
      // usage yet" and the UI test for it failed -- which is how the mistake
      // was found rather than shipped.
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          sessionId: SESSION.sessionId,
          asOfSeq: 17,
          stats: {
            title: 'Mock session',
            tokenUsage: {
              uncachedInputTokens: 12_480,
              outputTokens: 3_712,
              cacheReadTokens: 180_320,
              cacheWriteTokens: 4_096,
              billedInputTokens: 196_896,
            },
            // A bare number, no percent sign: the host formats it that way and the
            // app appends the symbol. Returning '92%' here made the app render
            // '92%%', which the test caught.
            cacheHit: { ratio: 0.92, displayPercent: '92' },
            context: {
              window: 128_000,
              pressureTokens: 41_000,
              projectedTokens: 44_500,
              percent: 35,
              breakdown: { systemTokens: 1_455, toolsTokens: 5_157, messageTokens: 34_388 },
            },
            stats: {
              turns: 6,
              steps: 14,
              llmMs: 48_200,
              toolMs: 6_100,
              ttftMs: 640,
              decodeTokensPerSecond: 58,
            },
            model: {
              lastUsed: {
                provider: 'deepseek-official',
                model: 'deepseek-flash',
                reasoningEffort: 'high',
              },
              next: null,
            },
            permissionPreset: 'workspace-write',
          },
        },
      }
    case 'model.catalog':
      // Copied from the real catalog. The first version invented `low/medium/high`
      // efforts; the host offers `off/low/high/max`, so the picker was being
      // tested against options that do not exist.
      //
      // The second instance offers a provider the first one has never heard of,
      // and no DeepSeek at all. A catalogue is read once per connection and kept
      // in the app, so a phone that switches Macs without forgetting the first
      // one's catalogue draws models this machine does not have -- which is only
      // visible if the two machines disagree about what they offer.
      return {
        v: 1,
        type: 'ok',
        id,
        result: SECOND_IDENTITY
          ? {
              default: { provider: 'moonshot', model: 'kimi-k2', reasoningEffort: 'high' },
              providers: [
                {
                  id: 'moonshot',
                  name: 'Moonshot',
                  models: [
                    {
                      id: 'kimi-k2',
                      name: 'Kimi-K2',
                      defaultEffort: 'high',
                      efforts: [
                        { id: 'off', name: 'Off', description: 'Use for simple tasks.' },
                        { id: 'high', name: 'High', description: 'The default balance.' },
                      ],
                    },
                  ],
                },
              ],
              failures: [],
            }
          : {
              default: { provider: 'deepseek-official', model: 'deepseek-flash', reasoningEffort: 'high' },
              providers: [
                {
                  id: 'deepseek-official',
                  name: 'DeepSeek',
                  models: [
                    {
                      id: 'deepseek-flash',
                      name: 'DeepSeek-V41-Flash',
                      defaultEffort: 'high',
                      efforts: [
                        { id: 'off', name: 'Off', description: 'Use for simple tasks that do not need reasoning.' },
                        { id: 'low', name: 'Low', description: 'Prefer for routine or latency-sensitive tasks.' },
                        { id: 'high', name: 'High', description: 'The default balance for most tasks.' },
                        { id: 'max', name: 'Max', description: 'Reserve for the hardest quality-first tasks.' },
                      ],
                    },
                    {
                      id: 'deepseek-v4-pro',
                      name: 'DeepSeek-V4-Pro',
                      description: 'Stronger agentic coding at higher cost.',
                      defaultEffort: 'high',
                      efforts: [
                        { id: 'off', name: 'Off', description: 'Use for simple tasks.' },
                        { id: 'high', name: 'High', description: 'The default balance.' },
                      ],
                    },
                  ],
                },
              ],
              failures: [{ id: 'openrouter', name: 'OpenRouter', message: 'not signed in' }],
            },
      }
    case 'permissions.catalog':
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          defaultPreset: 'workspace-write',
          defaults: [],
          options: [
            { value: 'read-only', name: 'Read only', description: 'Can look, cannot touch.' },
            { value: 'workspace-write', name: 'Workspace write', description: 'Writes inside the workspace.' },
            { value: 'danger-full-access', name: 'Full access', description: 'Unrestricted access to this machine.' },
          ],
        },
      }
    case 'session.model.set': {
      // The host's real answer, which the mock did not send at all until a test
      // needed to tell a switch that worked from one that did not. `?fail=` is
      // how a refusal is produced; this is what agreement looks like, and its
      // absence is why every model switch on this fixture used to fail to decode
      // with nobody noticing.
      const selected = {
        provider: frame.payload?.provider ?? 'deepseek-official',
        model: frame.payload?.model ?? 'deepseek-flash',
        reasoningEffort: frame.payload?.reasoningEffort ?? null,
      }
      modelSets.push(selected)
      console.log('mock: model set ->', JSON.stringify(selected))
      return {
        v: 1,
        type: 'ok',
        id,
        result: { sessionId: frame.payload?.sessionId ?? SESSION.sessionId, selected },
      }
    }
    case 'session.create': {
      const cwd = typeof frame.payload?.cwd === 'string' ? frame.payload.cwd : SESSION.cwd
      const created = {
        ...SESSION,
        sessionId: `session-mock-created-${createdSessions.length + 1}`,
        cwd,
        updatedAt: Date.now(),
        running: false,
        prompts: [],
      }
      createdSessions.push(created)
      console.log('mock: session created ->', created.sessionId, cwd)
      return { v: 1, type: 'ok', id, result: { sessionId: created.sessionId } }
    }
    case 'session.prompt': {
      const text = typeof frame.payload?.text === 'string' ? frame.payload.text : ''
      const created = createdSessions.find((s) => s.sessionId === frame.payload?.sessionId)
      if (created !== undefined) {
        if (text !== '') created.prompts.push(text)
        created.updatedAt = Date.now()
        console.log('mock: prompt for', created.sessionId, '->', JSON.stringify(text))
        return {
          v: 1,
          type: 'ok',
          id,
          result: { accepted: true, requestId: frame.payload?.requestId ?? 'mock-request' },
        }
      }
      if (text !== '') sentPrompts.push(text)
      console.log('mock: prompt received ->', JSON.stringify(text), '| log now', sentPrompts.length)
      return {
        v: 1,
        type: 'ok',
        id,
        result: { accepted: true, requestId: frame.payload?.requestId ?? 'mock-request' },
      }
    }
    case 'session.messages':
      // A requested page the transport cannot carry. The host's own answer to
      // this is `RESPONSE_TOO_LARGE` rather than a truncated page or a closed
      // socket, and the client's answer is to ask for less -- so a page limit
      // is what makes that reachable in a test.
      if (typeof frame.payload?.maxMessages === 'number' && frame.payload.maxMessages > pageLimit) {
        return {
          v: 1,
          type: 'error',
          code: 'RESPONSE_TOO_LARGE',
          message: `the answer to ${id} is 1400KB, too large to deliver`,
          retryable: false,
          id,
        }
      }
      const created = createdSessions.find((s) => s.sessionId === frame.payload?.sessionId)
      if (created !== undefined) {
        console.log('mock: messages for', created.sessionId, JSON.stringify(frame.payload))
        let seq = 0
        const now = Date.now()
        const record = (type, data) => {
          seq += 1
          return { type: 'event', event: { type, seq, time: now - (100 - seq) * 1000, data } }
        }
        return {
          v: 1,
          type: 'ok',
          id,
          result: {
            sessionId: created.sessionId,
            asOfSeq: created.prompts.length * 3,
            hasMore: false,
            records: created.prompts.flatMap((text, index) => [
              record('turn/start', { turn: index + 1 }),
              record('step/start', { turn: index + 1, step: 1 }),
              record('user/message', {
                content: [{ type: 'text', text }],
                source: { kind: 'user' },
                role: 'user',
                id: `${created.sessionId}-m${index + 1}`,
              }),
            ]),
          },
        }
      }
      if (frame.payload?.sessionId === ORPHANED_SESSION.sessionId) {
        return {
          v: 1,
          type: 'ok',
          id,
          result: orphanMessages(frame.payload?.beforeSeq ?? null),
        }
      }
      // Record shapes copied from a real session log, in the shape the host now
      // sends: **summary-only history**. For each finished turn, the operator's
      // prompt, the turn's `turn/start`, its `turn/end`, one `step/start` per
      // step, and only the **last** `assistant/message` of the turn -- the
      // model's summary of it. The per-step narration, the tool calls, the
      // streaming attempts and the partial answer of a running turn are not sent
      // at all; the change was bandwidth-driven, because the full history was
      // too heavy through the relay.
      //
      // The *order* the records are written in is the host's, which is not the
      // order a reader assumes: inside a turn it is `turn/start`, then
      // `step/start`, then the operator's `user/message`. See the note on turn 1
      // below, which is where the measurement is written down.
      //
      // This fixture used to carry the old full-fidelity log -- streamed deltas,
      // a message per step, tool activity -- and that made the suite a test of a
      // transport the app no longer talks to. It is the app's fixture, so it
      // serves what the app will really see.
      //
      // Four turns, chosen for what they pin:
      //
      //   turn 1   finished, three steps, one summary at the end of them. The
      //            step count comes from the markers, not from the messages: had
      //            it been counted from messages it would read "1 steps".
      //   turn 2   ended `error` with nothing to show for it. That is the shape
      //            a turn takes on a host with no provider credential, and the
      //            one where a bare "未完成" row would leave the operator to
      //            guess what happened.
      //   turn 3   asked for, ended badly, and it *did* answer: the row keeps
      //            its warning and the answer stays.
      //   turn 4   **no `turn/end`**, and two steps with no answer after them.
      //            The running shape, and the one reported broken: the reader
      //            used to invent an end time from the last record it held, so a
      //            live turn was drawn as "已完成，用时 10 秒" with the seconds
      //            measuring the age of the newest message.
      const now = Date.now()
      // Numbered as they are built, so a record's `seq` and its position agree.
      // The client orders a conversation by `seq` where two records share a
      // millisecond, and hand-written numbers that drifted from the array would
      // be a fixture that tests something the host never sends.
      let counter = -1
      const record = (type, data) => {
        counter += 1
        return {
          type: 'event',
          event: {
            type,
            seq: counter,
            time: now + clockSkewMs - (20 - counter) * 1000,
            data,
          },
        }
      }
      return {
        v: 1,
        type: 'ok',
        id,
        result: {
          sessionId: SESSION.sessionId,
          asOfSeq: 27 + sentPrompts.length,
          hasMore: false,
          records: [
            record('permission/preset', { preset: 'workspace-write' }),

            // **The order inside a turn is the host's, and it is not the obvious
            // one.** Read off the durable log of a real session and confirmed on
            // the live wire: `turn/start` first, then `step/start`, and the
            // operator's `user/message` *after* both -- carrying no `data.turn`
            // of its own:
            //
            //     seq=92 turn/start {"turn":11}
            //     seq=94 step/start {"turn":11,"step":1}
            //     seq=95 user/message {…"source":{"kind":"user"}}
            //
            // This fixture used to write the prompt *before* its `turn/start`,
            // which is the order a reader assumes and not the one the host
            // sends. The suite passed while the app lost the newest turn: a
            // prompt written after its own `turn/start` cannot be paired by a
            // rule that only looks for a *later* turn, so a running turn -- for
            // which the host sends no `assistant/message` to claim the prompt
            // with -- held no prompt at all, and the row drawn over a working
            // agent read "已完成". The prompt is therefore written where the
            // host writes it, in every turn below, including the finished ones.

            // Turn 1: asked for, finished in three steps. The count comes from
            // the three markers, not from the messages -- the turn carries
            // **one** message, its summary, and a count taken from messages
            // would read "1 steps".
            record('turn/start', { turn: 1 }),
            record('step/start', { turn: 1, step: 1 }),
            record('step/end', { turn: 1, step: 1 }),
            record('step/start', { turn: 1, step: 2 }),
            record('step/end', { turn: 1, step: 2 }),
            record('step/start', { turn: 1, step: 3 }),
            record('user/message', {
              content: [{ type: 'text', text: MAIN_PROMPT }],
              source: { kind: 'user', rpcId: 'r1' },
              role: 'user',
              id: 'm1',
            }),
            // The model's *last* message of the turn, and the only one sent:
            // the three steps above are three markers and nothing else.
            record('assistant/message', {
              turn: 1,
              step: 3,
              message: {
                role: 'assistant',
                content: [{ type: 'text', text: MAIN_ANSWER }],
              },
            }),
            record('turn/end', { turn: 1, reason: { kind: 'completed' } }),

            // Turn 2: **ended badly with nothing to show for it**. That is the
            // shape a turn takes on a host with no provider credential -- the
            // model never ran -- and the shape that has to be drawn as a failure
            // rather than as an empty screen. It carries one marker and no
            // answer at all: the summary-only transport sends no streaming
            // attempt, so the reason on `turn/end` is the only thing left to
            // report it with.
            record('turn/start', { turn: 2 }),
            record('step/start', { turn: 2, step: 1 }),
            record('user/message', {
              content: [{ type: 'text', text: 'Now add a case for trailing commas.' }],
              // `source.kind` is not decoration: the reader shows a
              // `user/message` only when it says a person wrote it, because DSH
              // sends its own injected context through the same event. A fixture
              // without it is a prompt that never appears -- and, worse, a turn
              // with no prompt, which is what the reader folds into the turn above
              // it. Omitting it here made one turn out of three.
              source: { kind: 'user' },
              role: 'user',
              id: 'm2',
            }),
            record('turn/end', { turn: 2, reason: { kind: 'error' } }),

            // Turn 3: asked for, ended badly, and it *did* answer. The row keeps
            // its warning and the answer stays -- a failure card belongs to a
            // turn that produced nothing, not to one that produced something and
            // then stopped.
            record('turn/start', { turn: 3 }),
            record('step/start', { turn: 3, step: 1 }),
            record('step/start', { turn: 3, step: 2 }),
            record('user/message', {
              content: [{ type: 'text', text: 'And check the tokenizer.' }],
              source: { kind: 'user' },
              role: 'user',
              id: 'm3',
            }),
            record('assistant/message', {
              turn: 3,
              step: 2,
              message: {
                role: 'assistant',
                content: [{ type: 'text', text: 'Two files changed, and it still fails.' }],
              },
            }),
            record('turn/end', { turn: 3, reason: { kind: 'error' } }),

            // Turn 4: the running one. No `turn/end`, and no
            // `assistant/message` either -- a turn still going gets no summary,
            // because a half-written answer is not one. Its two markers are all
            // the reader has of it, which is why the count matters here more
            // than anywhere else.
            //
            // The prompt is written inside the turn, after the markers, exactly
            // as the host writes it -- and this is the turn where getting that
            // wrong cost the screen its running row: with the prompt held for a
            // turn that never came, this turn held no prompt, the group holding
            // it sorted after this one, and the fold absorbed the turn into that
            // group and lost both the number and the start the "深度求索中，用时"
            // row is drawn from.
            record('turn/start', { turn: 4 }),
            record('step/start', { turn: 4, step: 1 }),
            record('step/start', { turn: 4, step: 2 }),
            record('user/message', {
              content: [{ type: 'text', text: 'And run the whole suite.' }],
              source: { kind: 'user' },
              role: 'user',
              id: 'm4',
            }),

            // The end of turn 4, but only while the session has stopped and
            // nothing has been sent since. The fixture has to be consistent
            // about what "running" means: the session list says whether a turn
            // is executing, and a page that still showed turn 4 open after the
            // session reported it stopped would make "the running row goes
            // away" untestable -- the host would be telling the app two
            // different things. Flipped at runtime by `/session?running=0`,
            // which is the endpoint the report's own reproduction uses: the turn
            // finishes under the open conversation and the phone has to notice
            // without a tap. A prompt sent afterwards supersedes turn 4, so it
            // ends even while the fixture keeps the session running.
            ...(sessionRunning && sentPrompts.length === 0
              ? []
              : [record('turn/end', { turn: 4, reason: { kind: 'completed' } })]),

            // Anything the client has sent since, appended the way a host would:
            // each prompt opens a turn of its own, in the host's own record
            // order -- `turn/start`, then its marker, then the operator's
            // message. The newest of those turns is the one the session's
            // `running` flag is about, so stopping the fixture ends exactly the
            // turn the operator is watching. A prompt with no turn after it
            // would be the state every message is in for a moment, and would
            // leave a test that sends a prompt with nothing running to watch.
            ...sentPrompts.flatMap((text, index) => {
              const turn = 5 + index
              return [
                record('turn/start', { turn }),
                record('step/start', { turn, step: 1 }),
                record('user/message', {
                  content: [{ type: 'text', text }],
                  source: { kind: 'user' },
                  role: 'user',
                  id: `sent-${index}`,
                }),
                // Every earlier prompt ended when the next one was sent; the
                // newest follows the session's flag.
                ...(index < sentPrompts.length - 1 || !sessionRunning
                  ? [record('turn/end', { turn, reason: { kind: 'completed' } })]
                  : []),
              ]
            }),
          ],
        },
      }
    case 'ping':
      return { v: 1, type: 'ok', id }
    case 'approval.answer':
    case 'question.answer':
      return { v: 1, type: 'ok', id, result: { accepted: true } }
    default:
      return { v: 1, type: 'ok', id, result: {} }
  }
}

const server = createServer((request, response) => {
  if (request.url?.startsWith('/connections')) {
    // How many sockets have been opened since the last reset. A reconnect is
    // invisible from the app's side -- the data looks the same afterwards -- so
    // this is the only way a test can say that a failure did *not* cost one.
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ connections }))
    return
  }
  if (request.url?.startsWith('/hold')) {
    // `?messages=1` holds every `session.messages` answer; `?messages=0`
    // releases what is waiting. The count is reported so a test can say it
    // released something rather than assuming it did.
    const previous = heldMessages.length
    holdingMessages = (request.url ?? '').includes('messages=1')
    if (!holdingMessages) {
      for (const waiting of heldMessages) waiting()
      heldMessages = []
    }
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, holding: holdingMessages, released: previous }))
    return
  }
  if (request.url?.startsWith('/loads')) {
    // How many `session.messages` reads the app asked for at the same time, and
    // the most that ever were. See `messagesInFlight`.
    const answer = {
      inFlight: messagesInFlight,
      peak: messagesPeak,
      methods: { ...methodCounts },
      refusedMethods: { ...refusedCounts },
      modelSets: modelSets.slice(),
    }
    if ((request.url ?? '').includes('reset=1')) {
      messagesInFlight = 0
      messagesPeak = 0
      for (const key of Object.keys(methodCounts)) delete methodCounts[key]
    }
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify(answer))
    return
  }
  if (request.url?.startsWith('/session')) {
    // Whether the session in the fixture is running, from now on. See
    // `sessionRunning`.
    sessionRunning = !(request.url ?? '').includes('running=0')
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, sessionRunning }))
    return
  }
  if (request.url?.startsWith('/offline')) {
    offline = (request.url ?? '').includes('on=1')
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, offline }))
    return
  }
  if (request.url?.startsWith('/stats')) {
    statsVariant = /variant=(\w+)/.exec(request.url ?? '')?.[1] ?? 'full'
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, statsVariant }))
    return
  }
  if (request.url?.startsWith('/fail')) {
    failMethod = /method=([A-Za-z.]+)/.exec(request.url ?? '')?.[1] ?? null
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, failMethod }))
    return
  }
  if (request.url?.startsWith('/slow')) {
    // Set the stall *after* the app is up, so a test can make one screen slow
    // without also making the launch that leads to it slow.
    //
    // `?method=session.messages` narrows it to one method, which is what lets a
    // test hold a reload open without also holding back the send that has to
    // land while it is open. Absent, every answer is stalled, as before.
    const match = /ms=(\d+)/.exec(request.url ?? '')
    answerDelayMs = match === null ? 0 : Math.min(5000, Number(match[1]))
    slowMethod = /method=([A-Za-z.]+)/.exec(request.url ?? '')?.[1] ?? null
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true, delayMs: answerDelayMs, slowMethod }))
    return
  }
  if (request.url?.startsWith('/reset')) {
    // Between UI tests, so each one starts from the same fixture.
    //
    // `sentPrompts` is deliberate -- the conversation has to grow when something
    // is sent, or the send path is untestable -- but it grew for the life of the
    // process, which is the whole suite. Every test after the first send
    // therefore ran against a longer conversation than the one before it, and a
    // test that scrolled to find a message found a different amount of content
    // depending on which tests had run first. That is a suite whose failures
    // depend on test order, which is a suite nobody can trust.
    sentPrompts.length = 0
    createdSessions.length = 0
    failMethod = null
    statsVariant = 'full'
    // `?skew=NNN` moves the host's clock ahead of the phone's, which is what a
    // running turn's negative duration came from. `?pageLimit=NNN` makes the
    // host refuse a page it cannot carry.
    const skew = /skew=(\d+)/.exec(request.url ?? '')
    clockSkewMs = skew === null ? 0 : Number(skew[1])
    const limit = /pageLimit=(\d+)/.exec(request.url ?? '')
    pageLimit = limit === null ? Infinity : Number(limit[1])
    connections = 0
    // `?running=0` reports the fixture's session as stopped, which is how a test
    // avoids posting a Live Activity at all -- the widget extension is a separate
    // process, and a suite that has to draw one is a suite that fails for reasons
    // that have nothing to do with what it is testing.
    sessionRunning = !(request.url ?? '').includes('running=0')
    // `?pending=0` takes the two interaction cards off the screen, for a test
    // that is about what is underneath them. The default is to offer them.
    withPending = !(request.url ?? '').includes('pending=0')
    const slow = /slow=(\d+)/.exec(request.url ?? '')
    answerDelayMs = slow === null ? 0 : Math.min(5000, Number(slow[1]))
    slowMethod = null
    messagesInFlight = 0
    messagesPeak = 0
    holdingMessages = false
    heldMessages = []
    for (const key of Object.keys(methodCounts)) delete methodCounts[key]
    for (const key of Object.keys(refusedCounts)) delete refusedCounts[key]
    modelSets.length = 0
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({ ok: true }))
    return
  }
  if (request.url?.startsWith('/mizar/v1/hello')) {
    response.writeHead(200, { 'content-type': 'application/json' })
    response.end(JSON.stringify({
      protocolVersion: 1,
      hostId: HOST_ID,
      hostName: HOST_NAME,
      paired: false,
      pairingOpen: true,
    }))
    return
  }
  if (request.url?.startsWith('/mizar/v1/pair')) {
    let body = ''
    request.on('data', (chunk) => { body += chunk })
    request.on('end', () => {
      let parsed = {}
      try { parsed = JSON.parse(body) } catch { /* refuse below */ }
      if (parsed.code !== CODE) {
        response.writeHead(403, { 'content-type': 'application/json' })
        response.end(JSON.stringify({ code: 'BAD_CODE', message: 'wrong code' }))
        return
      }
      response.writeHead(200, { 'content-type': 'application/json' })
      response.end(JSON.stringify({
        deviceToken: 'mz_mock_token',
        deviceId: DEVICE_ID,
        hostId: HOST_ID,
        hostName: HOST_NAME,
        authority: `127.0.0.1:${port}`,
        protocolVersion: 1,
      }))
    })
    return
  }
  response.writeHead(404).end()
})

const wss = new WebSocketServer({ server, path: '/mizar/v1/ws' })
wss.on('connection', (socket) => {
  connections += 1
  if (offline) {
    // Closed immediately rather than left hanging: a socket that opens and then
    // says nothing is what a network failure looks like from the app's side, and
    // that is the case being reproduced.
    socket.close(1011, 'mock offline')
    return
  }
  socket.on('message', (raw) => {
    let frame
    try { frame = JSON.parse(String(raw)) } catch { return }
    methodCounts[frame.type] = (methodCounts[frame.type] ?? 0) + 1
    // Counted around the whole answer, not around the delay: a read that is
    // still being answered when the next one arrives is the overlap being
    // measured, and whether it was slow is beside the point.
    const isLogRead = frame.type === 'session.messages'
    if (isLogRead) {
      messagesInFlight += 1
      messagesPeak = Math.max(messagesPeak, messagesInFlight)
    }
    const finish = () => {
      if (isLogRead) messagesInFlight -= 1
      socket.send(JSON.stringify(answer(frame)))
    }
    const delay = slowMethod === null || slowMethod === frame.type ? answerDelayMs : 0
    if (isLogRead && holdingMessages) {
      // Counted as in flight for as long as it is held: from the host's side
      // this request has not been answered, which is exactly what a second one
      // arriving alongside it means.
      heldMessages.push(finish)
      return
    }
    if (delay === 0) finish()
    else setTimeout(finish, delay)
  })
})

server.listen(port, '127.0.0.1', () => {
  console.log(`mock host on 127.0.0.1:${port}, code ${CODE}`)
  console.log(`mizar://pair?h=127.0.0.1%3A${port}&c=${CODE}&n=Mock%20Mac&v=1`)
})
