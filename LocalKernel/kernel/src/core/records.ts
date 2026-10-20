/**
 * Session records — the log the kernel keeps and the shapes it projects.
 *
 * A session's log is a JSONL file of records, each `{type: 'event', event:
 * {type, seq, time, data}}`. `seq` is the session's monotonic cursor: it orders
 * the log, it is the paging cursor, and the client's incremental reads are
 * expressed in it. Records go into the log exactly once and are never
 * rewritten; readers project.
 *
 * The record *vocabulary* is the desktop host's (`dsh-mizar`), so a client that
 * renders a desktop session renders a kernel session unchanged. What the kernel
 * emits per turn:
 *
 *     turn/start      {turn}
 *     step/start      {turn, step}
 *     user/message    {content, source, role, id}
 *     assistant/attempt  {turn, step, attempt, stream: [...]}
 *     assistant/message   {turn, step, message}
 *     tool/call       {turn, step, callId, name, arguments}
 *     tool/result     {turn, step, callId, name, output | error}
 *     turn/end        {turn, reason}
 *
 * Two projections read this log — the summary page (`session.messages`) and the
 * running-turn feed (`session.activity`) — and both are ported line-for-line
 * from the desktop bridge, because their semantics *are* the contract: which
 * records survive, the 256 KiB budgets, the 240-character one-liners, the
 * running-turn rule. `dsh-mizar src/bridge/sessions.ts` is the reference.
 */

import { utf8ByteLength } from '../host/host.ts'

/** The log record: one event with its position. */
export interface SessionRecord {
  readonly type: 'event'
  readonly event: {
    readonly type: string
    readonly seq: number
    readonly time: number
    readonly data: unknown
  }
}

/** Build one record. The only place a `seq` is ever allocated. */
export function makeRecord(seq: number, time: number, type: string, data: unknown): SessionRecord {
  return { type: 'event', event: { type, seq, time, data } }
}

/** The unwrapped event of a record, tolerating a bare (unwrapped) shape. */
export function eventOf(record: unknown): Record<string, unknown> | null {
  if (typeof record !== 'object' || record === null) return null
  const outer = record as Record<string, unknown>
  if (outer['type'] === 'event' && typeof outer['event'] === 'object' && outer['event'] !== null) {
    return outer['event'] as Record<string, unknown>
  }
  // The log's own unwritten cousin — a bare event. The desktop readers read
  // through both shapes; the kernel writes only the wrapped one but reads both.
  if (typeof outer['type'] === 'string' && outer['type'] !== 'event' && 'data' in outer) {
    return outer
  }
  return null
}

/** A record's log position, when it names one. */
export function recordSeq(record: unknown): number | null {
  const event = eventOf(record)
  if (event === null) return null
  const seq = event['seq']
  return typeof seq === 'number' && Number.isFinite(seq) ? seq : null
}

/** The turn an event belongs to, when it names one. */
export function turnOf(event: Record<string, unknown>): number | null {
  const data = event['data']
  if (typeof data !== 'object' || data === null) return null
  const turn = (data as Record<string, unknown>)['turn']
  return typeof turn === 'number' && Number.isFinite(turn) ? turn : null
}

// ---------------------------------------------------------------------------
// The summary page (`session.messages`)
// ---------------------------------------------------------------------------

/** The byte budget one page of records may occupy. Desktop: MAX_PAGE_BYTES. */
export const MAX_PAGE_BYTES = 256 * 1024

/**
 * The summary allowlist: the records a history page keeps.
 *
 * A history page is a summary, not a transcript. What survives being read
 * rather than scrolled: the turn brackets, the step markers, the user's words,
 * and — per turn that ended inside the page — the last assistant message that
 * has readable text. Narration, tool calls and unfinished turns stay in the
 * log; the running-turn feed is where process detail belongs.
 */
export function summaryRecords(records: readonly unknown[]): unknown[] {
  /** Assistant messages that are their turn's last word, and have one. */
  const summaries = new Set<unknown>()
  const ended = new Set<number>()
  const lastPerTurn = new Map<number, unknown>()
  for (const record of records) {
    const event = eventOf(record)
    if (event === null) continue
    if (event['type'] === 'turn/end') {
      const turn = turnOf(event)
      if (turn !== null) ended.add(turn)
    } else if (event['type'] === 'assistant/message') {
      const turn = turnOf(event)
      if (turn !== null && assistantText(event) !== null) lastPerTurn.set(turn, record)
    }
  }
  for (const [turn, last] of lastPerTurn) {
    if (ended.has(turn)) summaries.add(last)
  }

  return records.filter((record) => {
    const event = eventOf(record)
    switch (event?.['type']) {
      case 'turn/start':
      case 'turn/end':
      case 'step/start':
        return true
      case 'user/message':
        return true
      case 'assistant/message':
        return summaries.has(record)
      default:
        return false
    }
  })
}

/** The readable text of an assistant message record, or `null` when it has none. */
function assistantText(event: Record<string, unknown>): string | null {
  const data = event['data']
  if (typeof data !== 'object' || data === null) return null
  const message = (data as Record<string, unknown>)['message']
  if (typeof message !== 'object' || message === null) return null
  const content = (message as Record<string, unknown>)['content']
  if (!Array.isArray(content)) return null
  const parts: string[] = []
  for (const part of content) {
    if (typeof part !== 'object' || part === null) continue
    const fields = part as Record<string, unknown>
    if (fields['type'] === 'text' && typeof fields['text'] === 'string' && fields['text'].trim() !== '') {
      parts.push(fields['text'])
    }
  }
  return parts.length > 0 ? parts.join('') : null
}

/**
 * Trim a page to the byte budget, keeping the newest.
 *
 * The budget is about the JSON array the client reads, so the brackets and
 * separators count too — a slight over-estimate, which is the safe direction.
 * A single record larger than the budget still travels: an empty page is worse
 * than one slightly over. Ported from the desktop's `withinBudget`.
 */
export function withinPageBudget(records: readonly unknown[]): unknown[] {
  const kept: unknown[] = []
  let total = 2
  for (let index = records.length - 1; index >= 0; index -= 1) {
    const record = records[index] as unknown
    const size = utf8ByteLength(JSON.stringify(record)) + 1
    if (total + size > MAX_PAGE_BYTES && kept.length > 0) break
    total += size
    kept.unshift(record)
  }
  return kept
}

// ---------------------------------------------------------------------------
// The running-turn feed (`session.activity`)
// ---------------------------------------------------------------------------

export const ACTIVITY_MAX_ENTRIES = 300
export const ACTIVITY_DEFAULT_ENTRIES = 200
export const ACTIVITY_MAX_BYTES = 256 * 1024
export const ACTIVITY_TEXT_CHARS = 240
export const ACTIVITY_TITLE_CHARS = 120

/** One compact process detail row. */
export interface ActivityEntry {
  readonly id: string
  readonly seq: number | null
  readonly at: number
  readonly kind: 'thinking' | 'command' | 'output' | 'tool'
  readonly title: string
  readonly text: string
}

/** One flattened, bounded line — every whitespace run collapses to one space. */
function oneLine(value: unknown, limit: number): string {
  if (typeof value !== 'string') return ''
  const flattened = value.replace(/\s+/gu, ' ').trim()
  return flattened.length > limit ? flattened.slice(0, limit) : flattened
}

/** The first line of a block of text. */
function firstLine(value: string): string {
  const end = value.search(/[\r\n]/u)
  return (end === -1 ? value : value.slice(0, end)).trim()
}

/** JSON text for an unknown value, never throwing. */
function compactJson(value: unknown): string {
  if (typeof value === 'string') return value
  try {
    return JSON.stringify(value) ?? ''
  } catch {
    return ''
  }
}

/** Tool names that mean "this runs a shell command", for the command row kind. */
const COMMAND_TOOL_NAME =
  /(?:^|[._:/-])(?:bash|sh|shell|zsh|exec|execute|command|run|terminal|powershell|cmd)(?:$|[._:/-])/iu

function isCommandTool(name: string): boolean {
  return COMMAND_TOOL_NAME.test(name)
}

/**
 * The readable narration carried by one `assistant/attempt` stream.
 *
 * The kernel writes the durable compact runs (`text-chunks` / `reasoning-chunks`
 * carrying `texts`); the reader also accepts raw delta chunks, matching the
 * desktop reader, so a log edited by hand still reads.
 */
function attemptText(data: Record<string, unknown>): string {
  const stream = data['stream']
  if (!Array.isArray(stream)) return ''
  const deltas: string[] = []
  const blocks: string[] = []
  for (const record of stream) {
    if (typeof record !== 'object' || record === null) continue
    const item = record as Record<string, unknown>
    const type = item['type']
    if (type === 'text-chunks' || type === 'reasoning-chunks') {
      const texts = item['texts']
      if (Array.isArray(texts)) {
        for (const text of texts) if (typeof text === 'string') deltas.push(text)
      }
      continue
    }
    const chunk = item['chunk']
    if (typeof chunk !== 'object' || chunk === null) continue
    const chunkRecord = chunk as Record<string, unknown>
    const chunkType = chunkRecord['type']
    if (chunkType === 'text-delta' || chunkType === 'reasoning-delta') {
      const text = chunkRecord['text']
      if (typeof text === 'string') deltas.push(text)
      continue
    }
    if (chunkType === 'block-end') {
      const block = chunkRecord['block']
      if (typeof block !== 'object' || block === null) continue
      const blockRecord = block as Record<string, unknown>
      const blockType = blockRecord['type']
      const text = blockRecord['text']
      if ((blockType === 'text' || blockType === 'reasoning') && typeof text === 'string') {
        blocks.push(text)
      }
    }
  }
  return deltas.length > 0 ? deltas.join('') : blocks.join('')
}

/** The one-line detail for a tool call's arguments (a JSON string in the log). */
function toolCallText(raw: unknown, limit: number): string {
  if (typeof raw !== 'string') return oneLine(compactJson(raw), limit)
  const text = raw.trim()
  if (text === '') return ''
  let parsed: unknown
  try {
    parsed = JSON.parse(text)
  } catch {
    return oneLine(text, limit)
  }
  if (typeof parsed === 'object' && parsed !== null && !Array.isArray(parsed)) {
    const fields = parsed as Record<string, unknown>
    for (const key of ['command', 'description', 'path']) {
      const value = fields[key]
      if (typeof value === 'string' && value.trim() !== '') {
        return oneLine(value, limit)
      }
    }
  }
  return oneLine(text, limit)
}

/** The one-line detail for a tool result. */
function toolResultText(data: Record<string, unknown>, limit: number): string {
  for (const key of ['output', 'result', 'content']) {
    const value = data[key]
    if (typeof value === 'string') {
      const line = firstLine(value)
      if (line !== '') return line
    } else if (typeof value === 'object' && value !== null) {
      const line = firstLine(compactJson(value))
      if (line !== '') return line
    }
  }
  const error = data['error']
  if (typeof error === 'object' && error !== null) {
    const fields = error as Record<string, unknown>
    for (const key of ['reason', 'name', 'code', 'message']) {
      const value = fields[key]
      if (typeof value === 'string') {
        const line = firstLine(value)
        if (line !== '') return line
      }
    }
  }
  return ''
}

/** A stable row id: the log position, or the timestamp when it names none. */
function activityId(seq: number | null, at: number, kind: string): string {
  return seq === null ? `at-${at}-${kind}` : `seq-${seq}`
}

/**
 * Narrow one running-turn record into a detail row.
 *
 * Only three event types are mapped, and everything else is skipped rather
 * than dumped. Ported from the desktop's `activityEntryOf`.
 */
export function activityEntryOf(
  record: unknown,
  callNames: ReadonlyMap<string, string>,
): ActivityEntry | null {
  const event = eventOf(record)
  if (event === null) return null
  const data = event['data']
  if (typeof data !== 'object' || data === null) return null
  const fields = data as Record<string, unknown>
  const seq = recordSeq(record)
  const time = event['time']
  const at = typeof time === 'number' && Number.isFinite(time) ? time : 0
  const callId = typeof fields['callId'] === 'string' ? fields['callId'] : null

  switch (event['type']) {
    case 'assistant/attempt': {
      const text = oneLine(attemptText(fields), ACTIVITY_TEXT_CHARS)
      if (text === '') return null
      const kind = 'thinking' as const
      return { id: activityId(seq, at, kind), seq, at, kind, title: '', text }
    }
    case 'tool/call': {
      const name = typeof fields['name'] === 'string' && fields['name'] !== '' ? fields['name'] : 'tool'
      const kind = isCommandTool(name) ? 'command' : 'tool'
      return {
        id: activityId(seq, at, kind),
        seq,
        at,
        kind,
        title: oneLine(name, ACTIVITY_TITLE_CHARS),
        text: toolCallText(fields['arguments'], ACTIVITY_TEXT_CHARS),
      }
    }
    case 'tool/result': {
      const text = oneLine(toolResultText(fields, ACTIVITY_TEXT_CHARS), ACTIVITY_TEXT_CHARS)
      if (text === '') return null
      const kind = 'output' as const
      const title = callId === null ? '' : oneLine(callNames.get(callId) ?? '', ACTIVITY_TITLE_CHARS)
      return { id: activityId(seq, at, kind), seq, at, kind, title, text }
    }
    default:
      return null
  }
}

/**
 * The turn the feed is about: the highest-numbered turn with activity in the
 * page and no `turn/end` for it. A page window can start inside a running
 * turn, so a missing `turn/start` is not evidence that nothing runs —
 * `turn/end` is the only record that ends a turn.
 */
export function findRunningTurn(records: readonly unknown[]): number | null {
  const active = new Set<number>()
  const ended = new Set<number>()
  for (const record of records) {
    const event = eventOf(record)
    if (event === null) continue
    const turn = turnOf(event)
    if (turn === null) continue
    if (event['type'] === 'turn/end') {
      ended.add(turn)
      continue
    }
    active.add(turn)
  }
  let running: number | null = null
  for (const turn of active) {
    if (ended.has(turn)) continue
    if (running === null || turn > running) running = turn
  }
  return running
}

/** Tool names by call id, for titling output rows. */
export function collectToolNames(records: readonly unknown[]): Map<string, string> {
  const names = new Map<string, string>()
  for (const record of records) {
    const event = eventOf(record)
    if (event?.['type'] !== 'tool/call') continue
    const data = event['data']
    if (typeof data !== 'object' || data === null) continue
    const fields = data as Record<string, unknown>
    const callId = fields['callId']
    const name = fields['name']
    if (typeof callId === 'string' && typeof name === 'string' && name !== '') {
      names.set(callId, name)
    }
  }
  return names
}

/**
 * Trim the running turn's rows to the byte budget, keeping the newest.
 * A single row larger than the budget still travels.
 */
export function withinActivityBudget(entries: readonly ActivityEntry[]): ActivityEntry[] {
  const kept: ActivityEntry[] = []
  let total = 2
  for (let index = entries.length - 1; index >= 0; index -= 1) {
    const entry = entries[index] as ActivityEntry
    const size = utf8ByteLength(JSON.stringify(entry)) + 1
    if (total + size > ACTIVITY_MAX_BYTES && kept.length > 0) break
    total += size
    kept.unshift(entry)
  }
  return kept
}

/** The smallest log position in one page — the cursor backward paging continues from. */
export function oldestPageSeq(records: readonly unknown[]): number | null {
  let oldest: number | null = null
  for (const record of records) {
    const seq = recordSeq(record)
    if (seq === null) continue
    if (oldest === null || seq < oldest) oldest = seq
  }
  return oldest
}
