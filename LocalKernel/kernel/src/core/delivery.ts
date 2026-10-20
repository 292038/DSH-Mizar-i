/**
 * The delivery ledger — what has actually reached a client.
 *
 * Ported from `dsh-mizar` `src/bridge/delivery.ts`. When a client reads
 * `session.messages` without an `afterSeq`, the host answers from "what this
 * device has not seen yet" — and *seen* means delivered: an `ok` frame counts
 * only once it has been written to a still-open connection. A page the client
 * never got (socket died mid-write, answer refused as too large) is offered
 * again on the next read.
 *
 * The ledger is in-memory, like the desktop's: it exists to de-duplicate
 * polling within one process lifetime, and a client reconnecting after a
 * kernel restart declares its own position with `afterSeq`.
 */

/** How many entries the ledger keeps at most. Desktop: MAX_ENTRIES. */
const MAX_ENTRIES = 4096

export class DeliveryLedger {
  /** `deviceId|sessionId` → the highest seq known delivered. */
  #delivered = new Map<string, number>()

  #key(deviceId: string, sessionId: string): string {
    return `${deviceId}|${sessionId}`
  }

  /** The position this device+session has been delivered through. */
  deliveredThrough(deviceId: string, sessionId: string): number | null {
    return this.#delivered.get(this.#key(deviceId, sessionId)) ?? null
  }

  /**
   * Record the result of one page write.
   *
   * Only a page that actually went out moves the cursor, and it moves it to the
   * largest seq the page carried — records without a seq prove nothing about
   * delivery position.
   */
  recordResult(deviceId: string, sessionId: string, records: readonly unknown[]): void {
    let largest: number | null = null
    for (const record of records) {
      const seq = recordSeqOf(record)
      if (seq !== null && (largest === null || seq > largest)) largest = seq
    }
    if (largest === null) return
    const key = this.#key(deviceId, sessionId)
    const current = this.#delivered.get(key)
    if (current === undefined || largest > current) this.#delivered.set(key, largest)
    if (this.#delivered.size > MAX_ENTRIES) {
      // Evict the oldest inserted key. Order is insertion order for Maps, and
      // the ledger's job is recency, so this is the right thing to forget.
      const first = this.#delivered.keys().next()
      if (!first.done) this.#delivered.delete(first.value)
    }
  }

  /** Forget one session entirely — used when a session is archived. */
  forgetSession(sessionId: string): void {
    for (const key of [...this.#delivered.keys()]) {
      if (key.endsWith(`|${sessionId}`)) this.#delivered.delete(key)
    }
  }
}

function recordSeqOf(record: unknown): number | null {
  if (typeof record !== 'object' || record === null) return null
  const outer = record as Record<string, unknown>
  const event =
    typeof outer['event'] === 'object' && outer['event'] !== null
      ? (outer['event'] as Record<string, unknown>)
      : outer
  const seq = event['seq']
  return typeof seq === 'number' && Number.isFinite(seq) ? seq : null
}
