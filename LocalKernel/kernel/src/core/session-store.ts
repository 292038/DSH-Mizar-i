/**
 * The session store — the kernel's own durable sessions.
 *
 * A desktop host reads sessions from the DSH engine's projection service; the
 * kernel *is* the engine, so it keeps the sessions itself. One directory per
 * session under the kernel root:
 *
 *     sessions/<sessionId>/meta.json     — identity, title, model, preset, cursors
 *     sessions/<sessionId>/log.jsonl     — the record log, one JSON record per line
 *
 * The log is the write-ahead truth: every record is appended to it before the
 * reader sees it. The store holds the parsed records in memory (phone-scale
 * logs; a session is one conversation), so paging is pure array work and the
 * afterSeq cursor arithmetic is exact.
 *
 * Crash rules:
 *
 *  - A trailing partial line (a crash mid-append) is skipped on boot — a torn
 *    tail must not take the session down.
 *  - `meta.json` records whether a turn was running. A kernel that restarts
 *    under a running turn appends a synthetic `turn/end` with reason kind
 *    `stopped`: the turn genuinely stopped; pretending it still runs would
 *    strand the client's "working" state forever.
 */

import { fromCallback, type PlatformHost } from '../host/host.ts'
import { MethodError } from '../protocol/method-error.ts'
import { eventOf, findRunningTurn, makeRecord, type SessionRecord } from './records.ts'

/** The selected model of a session, as the client sets and stats reports it. */
export interface SelectedModel {
  readonly provider: string
  readonly model: string
  readonly reasoningEffort?: string
}

/** A session row, as `session.list` returns it. */
export interface SessionRow {
  readonly sessionId: string
  readonly updatedAt: number
  readonly running: boolean
  readonly blank: boolean
  readonly agentAvailable: boolean
  readonly cwd: string
  readonly parentSessionId: string | null
  readonly origin: string | null
}

/** A session's persisted identity and cursors. */
export interface SessionMeta {
  readonly sessionId: string
  /** The working directory the session was created with (display string). */
  cwd: string
  title: string | null
  createdAt: number
  updatedAt: number
  archived: boolean
  selectedModel: SelectedModel | null
  permissionPreset: string | null
  agentPreset: string | null
  /** The turn that was running when the kernel last saw this session. */
  runningTurn: number | null
  /** The next turn number the runner will allocate. */
  nextTurn: number
  /** The highest allocated record seq. */
  lastSeq: number
  /** Token usage accumulated across every engine step, when reported. */
  usage: {
    uncachedInputTokens: number
    outputTokens: number
    cacheReadTokens: number
    cacheWriteTokens: number
  } | null
  /** Milliseconds spent in engine calls and in tool execution. */
  llmMs: number
  toolMs: number
}

/** One loaded session: meta plus its in-memory log. */
interface LoadedSession {
  readonly meta: SessionMeta
  readonly records: SessionRecord[]
}

/** The on-disk meta file. `lastSeq` is redundant with the log but read cheaply. */
interface StoredMeta extends SessionMeta {}

const SESSIONS_DIR = 'sessions'

function sessionDir(sessionId: string): string {
  return `${SESSIONS_DIR}/${sessionId}`
}

function isSafeSessionId(sessionId: string): boolean {
  return /^session-[0-9a-f-]{1,80}$/.test(sessionId) || /^[A-Za-z0-9_-]{1,80}$/.test(sessionId)
}

export class SessionStore {
  readonly #host: PlatformHost
  readonly #sessions = new Map<string, LoadedSession>()
  /** The default working directory new sessions get. */
  readonly defaultCwd: string

  constructor(host: PlatformHost, defaultCwd: string) {
    this.#host = host
    this.defaultCwd = defaultCwd
  }

  /** Load every session's meta and log from disk. Called once at boot. */
  async load(): Promise<void> {
    const entries = await fromCallback<string[] | null>((cb) => this.#host.fs.listDir(SESSIONS_DIR, cb))
    if (entries === null) return
    for (const name of [...entries].sort()) {
      if (!isSafeSessionId(name)) continue
      const metaText = await fromCallback<string | null>((cb) =>
        this.#host.fs.readText(`${sessionDir(name)}/meta.json`, cb),
      )
      if (metaText === null) continue
      let meta: StoredMeta
      try {
        meta = JSON.parse(metaText) as StoredMeta
      } catch {
        this.#host.log('warn', `sessions/${name}: meta.json is not valid JSON; skipping`)
        continue
      }
      if (meta.sessionId !== name) {
        this.#host.log('warn', `sessions/${name}: meta names ${meta.sessionId}; skipping`)
        continue
      }
      const records = await this.#loadLog(name)
      const session: LoadedSession = { meta, records }
      // Into the map first: the restart closure below appends through the
      // normal path, which requires the session to be open.
      this.#sessions.set(name, session)
      const running = findRunningTurn(records)
      if (running !== null) {
        // The kernel restarted under a running turn. Close it honestly.
        const record = this.#appendInMemory(name, 'turn/end', {
          turn: running,
          reason: { kind: 'stopped' },
        })
        await this.#persistRecord(name, record)
        meta.runningTurn = null
        meta.updatedAt = record.event.time
        await this.#persistMeta(name, meta)
        this.#host.log('info', `sessions/${name}: closed turn ${running} left running by a restart`)
      }
    }
  }

  async #loadLog(sessionId: string): Promise<SessionRecord[]> {
    const text = await fromCallback<string | null>((cb) =>
      this.#host.fs.readText(`${sessionDir(sessionId)}/log.jsonl`, cb),
    )
    const records: SessionRecord[] = []
    if (text === null || text === '') return records
    for (const line of text.split('\n')) {
      const trimmed = line.trim()
      if (trimmed === '') continue
      try {
        const parsed = JSON.parse(trimmed) as unknown
        if (eventOf(parsed) !== null) records.push(parsed as SessionRecord)
      } catch {
        // A torn tail from a crash mid-append. Everything before it stands.
        this.#host.log('warn', `sessions/${sessionId}: skipping a torn log line`)
      }
    }
    return records
  }

  /** Every non-archived session, newest activity first. */
  list(): SessionRow[] {
    const rows: SessionRow[] = []
    for (const session of this.#sessions.values()) {
      if (session.meta.archived) continue
      rows.push(this.#row(session))
    }
    rows.sort((a, b) => b.updatedAt - a.updatedAt)
    return rows
  }

  /** One session's row, or `null` when it does not exist (archived counts as existing). */
  rowOf(sessionId: string): SessionRow | null {
    const session = this.#sessions.get(sessionId)
    return session === undefined ? null : this.#row(session)
  }

  #row(session: LoadedSession): SessionRow {
    const meta = session.meta
    const running = meta.runningTurn !== null
    const blank = session.records.length === 0
    return {
      sessionId: meta.sessionId,
      updatedAt: meta.updatedAt,
      running,
      blank,
      agentAvailable: session.records.length > 0,
      cwd: meta.cwd,
      parentSessionId: null,
      origin: null,
    }
  }

  /**
   * Create a session, or re-open an existing one by id.
   *
   * The `sessionId` form is recovery: the kernel adopts the id and the session
   * starts blank unless the log already exists on disk.
   */
  async create(input: { cwd?: string; sessionId?: string; agentPreset?: string }): Promise<SessionMeta> {
    const sessionId = input.sessionId ?? `session-${this.#host.uuid()}`
    if (!isSafeSessionId(sessionId)) {
      throw new MethodError('MALFORMED_FRAME', `session.create: payload."sessionId" is not a session id`)
    }
    if (this.#sessions.has(sessionId)) {
      throw new MethodError('REMOTE_ERROR', `session.create: session "${sessionId}" already exists`)
    }
    const now = this.#host.now()
    const meta: SessionMeta = {
      sessionId,
      cwd: input.cwd ?? this.defaultCwd,
      title: null,
      createdAt: now,
      updatedAt: now,
      archived: false,
      selectedModel: null,
      permissionPreset: null,
      agentPreset: input.agentPreset ?? null,
      runningTurn: null,
      nextTurn: 1,
      lastSeq: 0,
      usage: null,
      llmMs: 0,
      toolMs: 0,
    }
    await fromCallback<void>((cb) => this.#host.fs.makeDir(sessionDir(sessionId), cb))
    // The session workspace exists from birth: a tool that lists it on the
    // first step sees an empty directory, not a missing one.
    await fromCallback<void>((cb) => this.#host.fs.makeDir(`workspace/${sessionId}`, cb))
    await this.#persistMeta(sessionId, meta)
    this.#sessions.set(sessionId, { meta, records: [] })
    return meta
  }

  get(sessionId: string): SessionMeta | null {
    return this.#sessions.get(sessionId)?.meta ?? null
  }

  records(sessionId: string): readonly SessionRecord[] {
    return this.#sessions.get(sessionId)?.records ?? []
  }

  /** Append one record: allocate seq+time, extend the log, persist. */
  async append(sessionId: string, type: string, data: unknown): Promise<SessionRecord> {
    const session = this.#sessions.get(sessionId)
    if (session === undefined) {
      throw new MethodError('REMOTE_ERROR', `session "${sessionId}" is not open`)
    }
    const record = this.#appendInMemory(sessionId, type, data)
    await this.#persistRecord(sessionId, record)
    return record
  }

  #appendInMemory(sessionId: string, type: string, data: unknown): SessionRecord {
    const session = this.#sessions.get(sessionId)
    if (session === undefined) throw new MethodError('REMOTE_ERROR', `session "${sessionId}" is not open`)
    session.meta.lastSeq += 1
    session.meta.updatedAt = this.#host.now()
    const record = makeRecord(session.meta.lastSeq, session.meta.updatedAt, type, data)
    session.records.push(record)
    return record
  }

  async #persistRecord(sessionId: string, record: SessionRecord): Promise<void> {
    await fromCallback<void>((cb) =>
      this.#host.fs.appendText(`${sessionDir(sessionId)}/log.jsonl`, `${JSON.stringify(record)}\n`, cb),
    )
    const session = this.#sessions.get(sessionId)
    if (session !== undefined) await this.#persistMeta(sessionId, session.meta)
  }

  async #persistMeta(sessionId: string, meta: SessionMeta): Promise<void> {
    await fromCallback<void>((cb) =>
      this.#host.fs.writeText(`${sessionDir(sessionId)}/meta.json`, JSON.stringify(meta, null, 2), cb),
    )
  }

  /** Persist one session's current meta (usage and timing accumulate in place). */
  async flushMeta(sessionId: string): Promise<void> {
    const session = this.#sessions.get(sessionId)
    if (session === undefined) return
    await this.#persistMeta(sessionId, session.meta)
  }

  async rename(sessionId: string, title: string): Promise<void> {
    const session = this.#sessions.get(sessionId)
    if (session === undefined) {
      throw new MethodError('REMOTE_ERROR', `session.rename: no session "${sessionId}"`)
    }
    session.meta.title = title
    session.meta.updatedAt = this.#host.now()
    await this.#persistMeta(sessionId, session.meta)
  }

  async setModel(sessionId: string, model: SelectedModel | null): Promise<void> {
    const session = this.#sessions.get(sessionId)
    if (session === undefined) {
      throw new MethodError('REMOTE_ERROR', `session.model.set: no session "${sessionId}"`)
    }
    session.meta.selectedModel = model
    session.meta.updatedAt = this.#host.now()
    await this.#persistMeta(sessionId, session.meta)
  }

  async setPermission(sessionId: string, preset: string | null): Promise<void> {
    const session = this.#sessions.get(sessionId)
    if (session === undefined) {
      throw new MethodError('REMOTE_ERROR', `session.permission.set: no session "${sessionId}"`)
    }
    session.meta.permissionPreset = preset
    session.meta.updatedAt = this.#host.now()
    await this.#persistMeta(sessionId, session.meta)
  }

  /** Mark a session's running turn (the turn runner brackets its work with this). */
  async beginTurn(sessionId: string, turn: number): Promise<void> {
    const session = this.#sessions.get(sessionId)
    if (session === undefined) return
    session.meta.runningTurn = turn
    if (turn >= session.meta.nextTurn) session.meta.nextTurn = turn + 1
    await this.#persistMeta(sessionId, session.meta)
  }

  async endTurn(sessionId: string, turn: number): Promise<void> {
    const session = this.#sessions.get(sessionId)
    if (session === undefined) return
    if (session.meta.runningTurn === turn) session.meta.runningTurn = null
    if (turn + 1 >= session.meta.nextTurn) session.meta.nextTurn = turn + 1
    await this.#persistMeta(sessionId, session.meta)
  }

  /** Allocate the next turn number for a session. */
  allocateTurn(sessionId: string): number {
    const session = this.#sessions.get(sessionId)
    if (session === undefined) {
      throw new MethodError('REMOTE_ERROR', `session "${sessionId}" is not open`)
    }
    const turn = session.meta.nextTurn
    session.meta.nextTurn = turn + 1
    return turn
  }

  /** Mark a session archived. Non-destructive: the log stays on disk. */
  async archive(sessionId: string): Promise<void> {
    const session = this.#sessions.get(sessionId)
    if (session === undefined) {
      throw new MethodError('REMOTE_ERROR', `session.archive: no session "${sessionId}"`)
    }
    session.meta.archived = true
    session.meta.updatedAt = this.#host.now()
    await this.#persistMeta(sessionId, session.meta)
  }
}
