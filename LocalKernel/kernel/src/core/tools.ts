/**
 * The kernel's built-in tools — what an on-device agent can actually do.
 *
 * A phone has no shell, so the desktop's `shell`/`exec` vocabulary does not
 * appear here. The basic set is deliberately small and everything it touches
 * is sandboxed: file tools see the kernel root and are additionally confined
 * by the permission preset; the network is one fetch tool that raises an
 * approval unless the preset is `danger-full-access`; and one tool asks the
 * operator questions through the interactions broker, which is how an agent
 * on a phone gets unstuck.
 *
 * Path rules, in order:
 *
 *  - Arguments name paths relative to the session's workspace (`workspace/
 *    <sessionId>` under the kernel root). Absolute paths and any `..` that
 *    would leave the allowed root are refused — never silently rewritten.
 *  - `read-only` covers listing and reading; `workspace-write` additionally
 *    covers writes inside the session workspace; `danger-full-access` covers
 *    everything, including writes anywhere in the kernel root.
 *  - An action a preset does not cover raises an approval (`allowed-once`
 *    covers exactly the call that asked).
 */

import { fromCallback, type PlatformHost } from '../host/host.ts'
import type { EngineToolSpec, TurnSignal } from '../engine/types.ts'
import type { InteractionsBroker } from './interactions.ts'
import type { KernelConfig } from './config.ts'
import { presetCovers, type ToolAction } from './permissions.ts'

/** Everything a tool implementation may touch. */
export interface ToolContext {
  readonly host: PlatformHost
  readonly sessionId: string
  /** The session workspace, kernel-relative: `workspace/<sessionId>`. */
  readonly workspacePath: string
  /** The workspace's display path, for messages. */
  readonly workspaceDisplay: string
  readonly preset: string
  readonly broker: InteractionsBroker
  readonly signal: TurnSignal
  readonly config: KernelConfig
}

/** One tool: its engine spec and its implementation. */
export interface ToolDefinition {
  readonly spec: EngineToolSpec
  /**
   * The permission action this tool performs, derived from its arguments.
   *
   * The session workspace is passed in because gating runs before a tool
   * context exists: whether a write stays inside the workspace decides which
   * preset covers it.
   */
  readonly actionOf: (args: Record<string, unknown>, workspacePath: string) => ToolAction
  readonly run: (
    args: Record<string, unknown>,
    ctx: ToolContext,
  ) => Promise<{ output: string } | { failure: { code: string; message: string } }>
}

/** The maximum a `read_file` returns before it is truncated with a note. */
const READ_FILE_CHARS = 200_000
/** The maximum body a `web_fetch` collects. */
const FETCH_CHARS = 64_000
/** How long a `web_fetch` may take. */
const FETCH_TIMEOUT_MS = 30_000

// ---------------------------------------------------------------------------
// Path handling
// ---------------------------------------------------------------------------

/**
 * Resolve a tool-supplied path under a base directory, kernel-relative.
 *
 * Returns the joined path, or `null` when the path is absolute or escapes the
 * base. Refusal — not rewriting — is the point: an agent that asks for
 * `../../secrets` gets an error it can read, not a silently different file.
 */
export function resolveUnder(base: string, requested: unknown): string | null {
  if (typeof requested !== 'string' || requested === '') return null
  if (requested.startsWith('/') || requested.startsWith('\\')) return null
  if (/^[A-Za-z]:/.test(requested)) return null
  const parts = `${base}/${requested}`.split('/')
  const resolved: string[] = []
  for (const part of parts) {
    if (part === '' || part === '.') continue
    if (part === '..') {
      if (resolved.length === 0) return null
      resolved.pop()
      continue
    }
    resolved.push(part)
  }
  return resolved.length > 0 ? resolved.join('/') : null
}

function missingArg(name: string): { failure: { code: string; message: string } } {
  return { failure: { code: 'INVALID_ARGUMENTS', message: `"${name}" is required` } }
}

// ---------------------------------------------------------------------------
// The tools
// ---------------------------------------------------------------------------

const listDir: ToolDefinition = {
  spec: {
    name: 'list_dir',
    description:
      'List a directory inside the workspace. Paths are relative to the workspace; "." lists its root.',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'The directory to list; "." for the workspace root.' },
      },
      required: [],
    },
  },
  actionOf: () => ({ kind: 'list', inWorkspace: true }),
  run: async (args, ctx) => {
    const resolved = resolveUnder(ctx.workspacePath, args['path'] ?? '.')
    if (resolved === null) {
      return { failure: { code: 'PATH_ESCAPES_SANDBOX', message: 'the path must stay inside the workspace' } }
    }
    const entries = await fromCallback<string[] | null>((cb) => ctx.host.fs.listDir(resolved, cb))
    if (entries === null) {
      return { failure: { code: 'NOT_FOUND', message: `no directory at "${args['path'] ?? '.'}"` } }
    }
    return { output: entries.length > 0 ? entries.join('\n') : '(empty directory)' }
  },
}

const readFile: ToolDefinition = {
  spec: {
    name: 'read_file',
    description:
      'Read a UTF-8 text file inside the workspace. Large files are truncated with a note at the end.',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'The file to read, relative to the workspace.' },
      },
      required: ['path'],
    },
  },
  actionOf: () => ({ kind: 'read', inWorkspace: true }),
  run: async (args, ctx) => {
    if (typeof args['path'] !== 'string') return missingArg('path')
    const resolved = resolveUnder(ctx.workspacePath, args['path'])
    if (resolved === null) {
      return { failure: { code: 'PATH_ESCAPES_SANDBOX', message: 'the path must stay inside the workspace' } }
    }
    const text = await fromCallback<string | null>((cb) => ctx.host.fs.readText(resolved, cb))
    if (text === null) {
      return { failure: { code: 'NOT_FOUND', message: `no file at "${args['path']}"` } }
    }
    if (text.length > READ_FILE_CHARS) {
      return { output: `${text.slice(0, READ_FILE_CHARS)}\n… [truncated; the file is ${text.length} characters]` }
    }
    return { output: text.length > 0 ? text : '(empty file)' }
  },
}

const writeFile: ToolDefinition = {
  spec: {
    name: 'write_file',
    description:
      'Write (create or overwrite) a UTF-8 text file inside the workspace, creating parent directories.',
    parameters: {
      type: 'object',
      properties: {
        path: { type: 'string', description: 'The file to write, relative to the workspace.' },
        content: { type: 'string', description: 'The full contents to write.' },
      },
      required: ['path', 'content'],
    },
  },
  actionOf: (args, workspacePath) => ({
    kind: 'write',
    // Whether the write stays in the session workspace decides whether
    // `workspace-write` covers it; anything else is an approval.
    inWorkspace: resolveUnder(workspacePath, args['path']) !== null,
  }),
  run: async (args, ctx) => {
    if (typeof args['path'] !== 'string') return missingArg('path')
    if (typeof args['content'] !== 'string') return missingArg('content')
    const inWorkspace = resolveUnder(ctx.workspacePath, args['path']) !== null
    if (ctx.preset !== 'danger-full-access' && !inWorkspace) {
      return {
        failure: {
          code: 'PATH_ESCAPES_SANDBOX',
          message: 'the path must stay inside the workspace (use a preset upgrade for wider access)',
        },
      }
    }
    const base = ctx.preset === 'danger-full-access' ? '' : ctx.workspacePath
    const resolved = resolveUnder(base, args['path'])
    if (resolved === null) {
      return { failure: { code: 'PATH_ESCAPES_SANDBOX', message: 'the path must stay inside the kernel root' } }
    }
    await fromCallback<void>((cb) => ctx.host.fs.writeText(resolved, args['content'] as string, cb))
    return { output: `wrote ${(args['content'] as string).length} characters to ${resolved}` }
  },
}

const webFetch: ToolDefinition = {
  spec: {
    name: 'web_fetch',
    description:
      'Fetch one http(s) URL and return the response body as text (first 64 KB). Reads only; no scripts run.',
    parameters: {
      type: 'object',
      properties: {
        url: { type: 'string', description: 'The http(s) URL to fetch.' },
      },
      required: ['url'],
    },
  },
  actionOf: () => ({ kind: 'network', inWorkspace: false }),
  run: async (args, ctx) => {
    if (typeof args['url'] !== 'string') return missingArg('url')
    const url = args['url'] as string
    if (!/^https?:\/\//i.test(url)) {
      return { failure: { code: 'UNSUPPORTED_URL', message: 'only http(s) URLs can be fetched' } }
    }
    return await new Promise<{ output: string } | { failure: { code: string; message: string } }>(
      (resolve) => {
        let settled = false
        let body = ''
        // The handle and the timeout reference each other, so both are
        // declared first and assigned after: a synchronous onError from the
        // host must find them initialized.
        let handle: { abort(): void } | null = null
        let timeout: unknown = null
        const finish = (result: { output: string } | { failure: { code: string; message: string } }) => {
          if (settled) return
          settled = true
          if (timeout !== null) ctx.host.clearTimeout(timeout)
          resolve(result)
        }
        timeout = ctx.host.setTimeout(() => {
          handle?.abort()
        }, FETCH_TIMEOUT_MS)
        handle = ctx.host.http.request(
          { url, method: 'GET', headers: { accept: 'text/*, application/json;q=0.9, */*;q=0.1' } },
          {
            onChunk: (chunk) => {
              if (body.length < FETCH_CHARS) body += chunk
            },
            onDone: (status) => {
              if (status !== 200) {
                finish({ failure: { code: 'HTTP_ERROR', message: `the URL answered HTTP ${status}` } })
                return
              }
              const truncated = body.length > FETCH_CHARS
              const text = truncated ? body.slice(0, FETCH_CHARS) : body
              finish({ output: truncated ? `${text}\n… [truncated at 64 KB]` : text === '' ? '(empty body)' : text })
            },
            onError: (message) => {
              finish({ failure: { code: 'FETCH_FAILED', message } })
            },
          },
        )
        ctx.signal.onAbort(() => {
          handle.abort()
          finish({ failure: { code: 'CANCELLED', message: 'the turn was cancelled' } })
        })
      },
    )
  },
}

const askUserQuestion: ToolDefinition = {
  spec: {
    name: 'ask_user_question',
    description:
      'Ask the operator one or more questions and wait for the answers. Use when a decision is the operator’s to make.',
    parameters: {
      type: 'object',
      properties: {
        questions: {
          type: 'array',
          description: 'The questions to ask, each with short options.',
          items: {
            type: 'object',
            properties: {
              question: { type: 'string' },
              detail: { type: 'string' },
              header: { type: 'string' },
              multiSelect: { type: 'boolean' },
              options: {
                type: 'array',
                items: {
                  type: 'object',
                  properties: {
                    label: { type: 'string' },
                    description: { type: 'string' },
                  },
                  required: ['label'],
                },
              },
            },
            required: ['question'],
          },
        },
      },
      required: ['questions'],
    },
  },
  actionOf: () => ({ kind: 'list', inWorkspace: true }),
  run: async (args, ctx) => {
    const raw = args['questions']
    if (!Array.isArray(raw) || raw.length === 0 || raw.length > 4) {
      return { failure: { code: 'INVALID_ARGUMENTS', message: 'questions must be a non-empty array of at most 4' } }
    }
    const questions = []
    for (const [index, item] of raw.entries()) {
      if (typeof item !== 'object' || item === null) {
        return { failure: { code: 'INVALID_ARGUMENTS', message: `questions[${index}] is not an object` } }
      }
      const fields = item as Record<string, unknown>
      if (typeof fields['question'] !== 'string' || (fields['question'] as string).trim() === '') {
        return { failure: { code: 'INVALID_ARGUMENTS', message: `questions[${index}].question is required` } }
      }
      const options: { label: string; description?: string }[] = []
      if (Array.isArray(fields['options'])) {
        for (const option of fields['options'] as unknown[]) {
          if (typeof option !== 'object' || option === null) continue
          const optionFields = option as Record<string, unknown>
          if (typeof optionFields['label'] !== 'string') continue
          options.push(
            typeof optionFields['description'] === 'string'
              ? { label: optionFields['label'] as string, description: optionFields['description'] as string }
              : { label: optionFields['label'] as string },
          )
        }
      }
      questions.push({
        id: `q${index + 1}`,
        question: fields['question'] as string,
        ...(typeof fields['detail'] === 'string' ? { detail: fields['detail'] as string } : {}),
        ...(typeof fields['header'] === 'string' ? { header: fields['header'] as string } : {}),
        options,
        multiSelect: fields['multiSelect'] === true,
        intent: null,
      })
    }

    const handle = ctx.broker.beginQuestions(
      { callId: ctx.host.uuid(), sessionId: ctx.sessionId, questions },
      ctx.signal,
    )
    const answers = await handle.answers
    if (answers.length === 0) {
      return { failure: { code: 'UNANSWERED', message: 'the operator did not answer' } }
    }
    return { output: JSON.stringify({ answers }) }
  },
}

/** The built-in tools, in the order they are offered to the engine. */
export function builtinTools(): readonly ToolDefinition[] {
  return [listDir, readFile, writeFile, webFetch, askUserQuestion]
}

/**
 * Run one tool with permission gating.
 *
 * The approval covers exactly this call (`allowed-once`); `rejected`,
 * `cancelled` and `unavailable` all refuse. The gate happens *before* the
 * `tool/call` record: a call that was never permitted is not logged as if it
 * ran — the denial travels as the tool's result instead.
 */
export async function gatedRun(
  definition: ToolDefinition,
  args: Record<string, unknown>,
  ctx: ToolContext & { callId: string },
): Promise<{ output: string } | { failure: { code: string; message: string } }> {
  const action = definition.actionOf(args, ctx.workspacePath)
  if (!presetCovers(ctx.preset, action)) {
    const handle = ctx.broker.beginApproval(
      {
        sessionId: ctx.sessionId,
        toolName: definition.spec.name,
        callId: ctx.callId,
        reason: approvalReason(definition, action, ctx),
      },
      ctx.signal,
    )
    const outcome = await handle.outcome
    if (outcome !== 'allowed-once') {
      return {
        failure: {
          code: outcome === 'rejected' ? 'PERMISSION_DENIED' : 'PERMISSION_UNAVAILABLE',
          message: `the ${definition.spec.name} call was not approved (${outcome})`,
        },
      }
    }
  }
  return await definition.run(args, ctx)
}

function approvalReason(
  definition: ToolDefinition,
  action: ToolAction,
  ctx: ToolContext,
): string {
  if (action.kind === 'network') return 'the current permission preset does not cover network access'
  if (action.kind === 'write' && !action.inWorkspace) {
    return `the write is outside the session workspace (${ctx.workspaceDisplay})`
  }
  return `the current permission preset (${ctx.preset}) does not cover ${definition.spec.name}`
}
