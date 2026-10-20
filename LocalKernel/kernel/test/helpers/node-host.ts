/**
 * A Node implementation of the platform host — for tests and local
 * development only. It is deliberately outside `src/`: the kernel bundle must
 * never depend on Node, and this file is the one place `node:` imports are
 * allowed.
 */

import { mkdir, readFile, writeFile, appendFile, rm, readdir } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { dirname, join, resolve } from 'node:path'
import type { Callback, PlatformHost, HostHttpRequest } from '../../src/host/host.ts'

export class NodeHost implements PlatformHost {
  readonly hostName: string
  readonly home: string
  readonly platformVersion = `node-${process.version}`
  readonly root: string

  readonly #kv = new Map<string, string>()
  /** When set, every HTTP request fails with this message. */
  httpFailure: string | null = null
  /** When set, every HTTP request is answered by this scripted handler. */
  httpHandler: ((request: HostHttpRequest, handlers: {
    onChunk(text: string): void
    onDone(status: number): void
    onError(message: string): void
  }) => { abort(): void }) | null = null

  constructor(root: string, hostName = 'test-host') {
    this.root = resolve(root)
    this.hostName = hostName
    this.home = this.root
  }

  #resolve(path: string): string {
    const full = resolve(this.root, path)
    if (full !== this.root && !full.startsWith(this.root + '/')) {
      throw new Error(`path escapes the sandbox: ${path}`)
    }
    return full
  }

  readonly fs = {
    readText: async (path: string, cb: Callback<string | null>): Promise<void> => {
      try {
        cb.ok(await readFile(this.#resolve(path), 'utf8'))
      } catch (error) {
        if (isNotFound(error)) cb.ok(null)
        else cb.fail({ message: String(error) })
      }
    },
    writeText: async (path: string, data: string, cb: Callback<void>): Promise<void> => {
      try {
        const full = this.#resolve(path)
        await mkdir(dirname(full), { recursive: true })
        await writeFile(full, data, 'utf8')
        cb.ok(undefined)
      } catch (error) {
        cb.fail({ message: String(error) })
      }
    },
    appendText: async (path: string, data: string, cb: Callback<void>): Promise<void> => {
      try {
        const full = this.#resolve(path)
        await mkdir(dirname(full), { recursive: true })
        await appendFile(full, data, 'utf8')
        cb.ok(undefined)
      } catch (error) {
        cb.fail({ message: String(error) })
      }
    },
    deletePath: async (path: string, cb: Callback<void>): Promise<void> => {
      try {
        await rm(this.#resolve(path), { force: true })
        cb.ok(undefined)
      } catch (error) {
        cb.fail({ message: String(error) })
      }
    },
    listDir: async (path: string, cb: Callback<string[] | null>): Promise<void> => {
      try {
        cb.ok(await readdir(this.#resolve(path)))
      } catch (error) {
        if (isNotFound(error)) cb.ok(null)
        else cb.fail({ message: String(error) })
      }
    },
    makeDir: async (path: string, cb: Callback<void>): Promise<void> => {
      try {
        await mkdir(this.#resolve(path), { recursive: true })
        cb.ok(undefined)
      } catch (error) {
        cb.fail({ message: String(error) })
      }
    },
  }

  readonly http = {
    request: (
      request: HostHttpRequest,
      handlers: { onChunk(text: string): void; onDone(status: number): void; onError(message: string): void },
    ): { abort(): void } => {
      if (this.httpFailure !== null) {
        handlers.onError(this.httpFailure)
        return { abort: () => {} }
      }
      if (this.httpHandler !== null) {
        return this.httpHandler(request, handlers)
      }
      const controller = new AbortController()
      void (async () => {
        try {
          const response = await fetch(request.url, {
            method: request.method,
            headers: request.headers,
            ...(request.body !== undefined ? { body: request.body } : {}),
            signal: controller.signal,
          })
          if (response.body === null) {
            handlers.onDone(response.status)
            return
          }
          const reader = response.body.getReader()
          const decoder = new TextDecoder()
          for (;;) {
            const { done, value } = await reader.read()
            if (done) break
            handlers.onChunk(decoder.decode(value, { stream: true }))
          }
          handlers.onChunk(decoder.decode())
          handlers.onDone(response.status)
        } catch (error) {
          handlers.onError(error instanceof Error ? error.message : String(error))
        }
      })()
      return {
        abort: () => {
          controller.abort()
        },
      }
    },
  }

  readonly kv = {
    get: async (key: string, cb: Callback<string | null>): Promise<void> => {
      cb.ok(this.#kv.get(key) ?? null)
    },
    set: async (key: string, value: string, cb: Callback<void>): Promise<void> => {
      this.#kv.set(key, value)
      cb.ok(undefined)
    },
    delete: async (key: string, cb: Callback<void>): Promise<void> => {
      this.#kv.delete(key)
      cb.ok(undefined)
    },
  }

  log(level: 'debug' | 'info' | 'warn' | 'error', message: string): void {
    if (process.env['MIZAR_KERNEL_TEST_LOG'] === '1') {
      console.error(`[kernel ${level}] ${message}`)
    }
  }

  uuid(): string {
    return randomUUID()
  }

  now(): number {
    return Date.now()
  }

  setTimeout(fn: () => void, ms: number): unknown {
    return setTimeout(fn, ms)
  }

  clearTimeout(handle: unknown): void {
    clearTimeout(handle as NodeJS.Timeout)
  }

  /** The kv store's contents, for assertions. */
  kvSnapshot(): Map<string, string> {
    return new Map(this.#kv)
  }

  kvPut(key: string, value: string): void {
    this.#kv.set(key, value)
  }
}

function isNotFound(error: unknown): boolean {
  return typeof error === 'object' && error !== null && (error as { code?: string })['code'] === 'ENOENT'
}

export { join }
