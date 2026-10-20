/**
 * The interactions broker — approvals and questions, between the agent and the
 * operator.
 *
 * Ported from `dsh-mizar` `src/bridge/interactions.ts`. The wire shapes, the
 * id format, the resolve-before-acknowledge ordering and the fail-closed rule
 * are the desktop's, because the client's behavior is written against them:
 *
 *  - `approval.answer` accepts exactly `allowed-once` | `rejected`; anything
 *    else is a client bug and answers `MALFORMED_FRAME`.
 *  - A double tap cannot settle twice: the map entry is deleted before the
 *    outcome is delivered.
 *  - When the last client disconnects, every pending approval settles
 *    `unavailable` and every question settles empty. A refused tool action is
 *    recoverable; an agent hung forever on a card nobody can see is not.
 *
 * Notifications are best-effort: a frame that cannot be delivered never fails
 * the state change that produced it.
 */

/** What a client may answer an approval with. */
export type ClientApprovalOutcome = 'allowed-once' | 'rejected'

/** Internal outcomes a handle can settle with when nobody answered. */
export type ApprovalOutcome = ClientApprovalOutcome | 'cancelled' | 'unavailable'

/** One question inside a question batch. */
export interface QuestionItem {
  readonly id: string
  readonly question?: string
  readonly detail?: string
  readonly header?: string
  readonly options: readonly { label: string; description?: string }[]
  readonly multiSelect: boolean
  /** Set when the question is a plan awaiting approval. */
  readonly intent: { kind: 'plan-review'; approve: string } | null
}

/** A pending approval, as shown to the client. */
export interface PendingApprovalView {
  readonly requestId: string
  readonly sessionId: string | null
  readonly toolName: string
  readonly callId: string | null
  readonly reason: string | null
  /** Localized presentation text, when the requesting tool supplied one. */
  readonly displayReason: Record<string, string> | null
  /** Epoch milliseconds the kernel first asked. */
  readonly requestedAt: number
}

/** A pending question batch, as shown to the client. */
export interface PendingQuestionView {
  readonly callId: string
  readonly sessionId: string | null
  readonly questions: readonly QuestionItem[]
  readonly requestedAt: number
}

/** The answer to one question item. */
export interface QuestionAnswerItem {
  readonly id: string
  readonly selected: readonly string[]
  readonly custom?: string
}

/** A handle on one outstanding approval. */
export interface ApprovalHandle {
  readonly requestId: string
  readonly outcome: Promise<ApprovalOutcome>
}

/** A handle on one outstanding question batch. */
export interface QuestionHandle {
  readonly callId: string
  readonly answers: Promise<readonly QuestionAnswerItem[]>
}

/** The counts-only change notification. */
export interface InteractionsCounts {
  readonly approvals: number
  readonly questions: number
}

type Emit = (event: string, data: unknown) => void

interface PendingApproval {
  readonly view: PendingApprovalView
  readonly settle: (outcome: ApprovalOutcome) => void
}

interface PendingQuestion {
  readonly view: PendingQuestionView
  readonly settle: (answers: readonly QuestionAnswerItem[]) => void
}

export class InteractionsBroker {
  readonly #approvals = new Map<string, PendingApproval>()
  readonly #questions = new Map<string, PendingQuestion>()
  readonly #emit: Emit
  #nextApprovalId = 0

  constructor(emit: Emit) {
    this.#emit = emit
  }

  /** The counts the `interactions.changed` frame carries — and nothing else. */
  counts(): InteractionsCounts {
    return { approvals: this.#approvals.size, questions: this.#questions.size }
  }

  #announce(): void {
    // The frame carries only counts, so the notification cannot go stale: a
    // client that reconnects re-reads `interactions.pending` for the detail.
    this.#emit('interactions.changed', this.counts())
  }

  /** Every approval still awaiting an answer. */
  listApprovals(): PendingApprovalView[] {
    return [...this.#approvals.values()].map((entry) => entry.view)
  }

  /** Every question batch still awaiting an answer. */
  listQuestions(): PendingQuestionView[] {
    return [...this.#questions.values()].map((entry) => entry.view)
  }

  /**
   * Ask the operator for an approval decision.
   *
   * The returned promise settles with the outcome — or `'cancelled'` when the
   * caller's own signal gave up first, or `'unavailable'` when the last client
   * went away before answering.
   */
  beginApproval(
    input: {
      sessionId: string | null
      toolName: string
      callId?: string
      reason?: string
      displayReason?: Record<string, string>
    },
    signal?: { aborted: boolean; onAbort(cb: () => void): void },
  ): ApprovalHandle {
    const requestId = `ap-${Date.now().toString(36)}-${(this.#nextApprovalId += 1).toString(36)}`

    let settle: (outcome: ApprovalOutcome) => void = () => {}
    const promise = new Promise<ApprovalOutcome>((resolve) => {
      settle = resolve
    })

    if (signal?.aborted === true) {
      return { requestId, outcome: Promise.resolve('cancelled') }
    }

    const view: PendingApprovalView = {
      requestId,
      sessionId: input.sessionId,
      toolName: input.toolName,
      callId: input.callId ?? null,
      reason: input.reason ?? null,
      displayReason: input.displayReason ?? null,
      requestedAt: Date.now(),
    }
    this.#approvals.set(requestId, { view, settle })
    this.#emit('approval.request', view)
    this.#announce()

    if (signal) {
      signal.onAbort(() => {
        this.#resolve(requestId, 'cancelled')
      })
    }

    return { requestId, outcome: promise }
  }

  /**
   * Ask the operator a batch of questions.
   *
   * The batch is keyed by the caller's `callId` (the tool call that asked).
   * There is no local timeout: withdrawal is driven by the caller's signal,
   * and a withdrawn batch settles empty — the host records unanswered.
   */
  beginQuestions(
    input: { callId: string; sessionId: string | null; questions: readonly QuestionItem[] },
    signal?: { aborted: boolean; onAbort(cb: () => void): void },
  ): QuestionHandle {
    let settle: (answers: readonly QuestionAnswerItem[]) => void = () => {}
    const promise = new Promise<readonly QuestionAnswerItem[]>((resolve) => {
      settle = resolve
    })

    if (signal?.aborted === true) {
      return { callId: input.callId, answers: Promise.resolve([]) }
    }

    const view: PendingQuestionView = {
      callId: input.callId,
      sessionId: input.sessionId,
      questions: input.questions,
      requestedAt: Date.now(),
    }
    this.#questions.set(input.callId, { view, settle })
    this.#emit('question.request', view)
    this.#announce()

    if (signal) {
      signal.onAbort(() => {
        this.#withdrawQuestions(input.callId)
      })
    }

    return { callId: input.callId, answers: promise }
  }

  /**
   * Answer one pending approval.
   *
   * Returns whether the approval was still pending: a second answer to the
   * same request is a no-op, not an error — the first tap already settled it.
   */
  answerApproval(requestId: string, outcome: ClientApprovalOutcome, by?: string): boolean {
    const entry = this.#approvals.get(requestId)
    if (entry === undefined) return false
    // Delete first: a double tap must not settle twice.
    this.#approvals.delete(requestId)
    this.#emit('approval.resolved', by === undefined ? { requestId, outcome } : { requestId, outcome, by })
    entry.settle(outcome)
    this.#announce()
    return true
  }

  /**
   * Answer one pending question batch. Each question is named exactly once —
   * the caller validated that before this broker saw the answers.
   */
  answerQuestion(callId: string, answers: readonly QuestionAnswerItem[]): boolean {
    const entry = this.#questions.get(callId)
    if (entry === undefined) return false
    this.#questions.delete(callId)
    this.#emit('question.resolved', { callId })
    entry.settle(answers)
    this.#announce()
    return true
  }

  #resolve(requestId: string, outcome: ApprovalOutcome, by?: string): void {
    const entry = this.#approvals.get(requestId)
    if (entry === undefined) return
    this.#approvals.delete(requestId)
    this.#emit(
      'approval.resolved',
      by === undefined ? { requestId, outcome } : { requestId, outcome, by },
    )
    entry.settle(outcome)
    this.#announce()
  }

  #withdrawQuestions(callId: string): void {
    const entry = this.#questions.get(callId)
    if (entry === undefined) return
    this.#questions.delete(callId)
    this.#emit('question.resolved', { callId })
    entry.settle([])
    this.#announce()
  }

  /**
   * Fail closed: the last client is gone, so nothing pending can be answered.
   *
   * Pending approvals settle `unavailable` — the same outcome the desktop uses
   * when there is no answerer — and pending questions settle empty. This can
   * preempt a client that is still showing the card. That is the deliberate
   * trade: a refused tool action is recoverable, a hung agent is not.
   */
  setClientCount(count: number): void {
    if (Math.max(0, count) > 0) return
    for (const [requestId, entry] of [...this.#approvals]) {
      this.#approvals.delete(requestId)
      this.#emit('approval.resolved', { requestId, outcome: 'unavailable' })
      entry.settle('unavailable')
    }
    for (const [callId, entry] of [...this.#questions]) {
      this.#questions.delete(callId)
      this.#emit('question.resolved', { callId })
      entry.settle([])
    }
    this.#announce()
  }

  /** Release everything still pending, for kernel shutdown. */
  dispose(): void {
    for (const [requestId, entry] of [...this.#approvals]) {
      this.#approvals.delete(requestId)
      entry.settle('cancelled')
    }
    for (const [callId, entry] of [...this.#questions]) {
      this.#questions.delete(callId)
      entry.settle([])
    }
  }
}
