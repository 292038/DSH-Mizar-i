/**
 * The `session.stats` frame — what the kernel can honestly report.
 *
 * The desktop reads its stats from DSH projections; the kernel folds its own.
 * The protocol's first rule applies with full force here: **a missing field is
 * not a zero**. The kernel reports what it measured and omits what it did not,
 * so the client renders "—" instead of a lie:
 *
 *  - `tokenUsage` — present once the engine has reported usage for at least
 *    one step; otherwise absent.
 *  - `cacheHit` — computed from `tokenUsage` when present. `displayPercent`
 *    is **truncated**, never rounded: an incomplete cache-hit rate must not
 *    be able to present itself as 100%.
 *  - `context` — omitted. The kernel does not measure context pressure yet;
 *    a fabricated window pressure would be worse than no field.
 *  - `stats` — turn/step counts from the log; timings from the runner;
 *    `ttftMs` and `decodeTokensPerSecond` are `null` (not measured yet).
 *  - `model`, `permissionPreset`, `title` — session state; `title` is absent
 *    until the session is named.
 */

import type { SessionStore } from './session-store.ts'
import { eventOf } from './records.ts'
import type { KernelConfig } from './config.ts'

export function buildStatsFrame(
  store: SessionStore,
  sessionId: string,
  config: KernelConfig,
): { sessionId: string; asOfSeq: number; stats: Record<string, unknown> } | null {
  const meta = store.get(sessionId)
  if (meta === null) return null

  const records = store.records(sessionId)
  const stats: Record<string, unknown> = {}

  if (meta.usage !== null) {
    stats['tokenUsage'] = {
      uncachedInputTokens: meta.usage.uncachedInputTokens,
      outputTokens: meta.usage.outputTokens,
      cacheReadTokens: meta.usage.cacheReadTokens,
      cacheWriteTokens: meta.usage.cacheWriteTokens,
      billedInputTokens:
        meta.usage.uncachedInputTokens + meta.usage.cacheReadTokens + meta.usage.cacheWriteTokens,
    }
    const billed = stats['tokenUsage'] as { billedInputTokens: number }
    stats['cacheHit'] = {
      ratio: null,
      displayPercent: displayCacheHit(meta.usage.cacheReadTokens, billed.billedInputTokens),
    }
  }

  let turns = 0
  let steps = 0
  for (const record of records) {
    const event = eventOf(record)
    if (event?.['type'] === 'turn/start') turns += 1
    if (event?.['type'] === 'step/start') steps += 1
  }
  stats['stats'] = {
    turns,
    steps,
    llmMs: meta.llmMs,
    toolMs: meta.toolMs,
    ttftMs: null,
    decodeTokensPerSecond: null,
  }

  const selected = meta.selectedModel ?? config.defaultModel
  stats['model'] = { lastUsed: selected, next: selected }

  if (meta.permissionPreset !== null) stats['permissionPreset'] = meta.permissionPreset
  if (meta.title !== null) stats['title'] = meta.title

  return { sessionId, asOfSeq: meta.lastSeq, stats }
}

/** The cache-hit percentage, truncated so it can never round up to 100. */
function displayCacheHit(cacheReadTokens: number, billedInputTokens: number): string | null {
  if (billedInputTokens <= 0) return null
  const percent = Math.floor((cacheReadTokens / billedInputTokens) * 100)
  return `${percent}%`
}
