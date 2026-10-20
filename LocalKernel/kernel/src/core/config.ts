/**
 * Kernel configuration — the engine's providers, models and limits.
 *
 * Defaults are compiled in so a fresh kernel works; a `config.json` in the
 * kernel root overrides individual fields, and the `kernel.config.set` method
 * writes it. API keys never live here — they go to the platform's key-value
 * store via `kernel.apiKey.set`, and are referenced by provider id only.
 *
 * A provider entry is OpenAI-compatible by contract: the adapter POSTs
 * `<baseUrl>/chat/completions` (or an explicitly configured full `path`) with
 * the standard streaming shape. Model ids pass through to the API unchanged;
 * `reasoningEffort` is sent as `reasoning_effort` when a model declares efforts
 * and the selection is not `"off"` — providers that do not understand the
 * field must be configured with an empty `efforts` list.
 */

/** One model inside a provider's catalog entry. */
export interface ModelSpec {
  readonly id: string
  readonly name: string
  readonly description?: string
  readonly efforts?: readonly { readonly id: string; readonly name: string; readonly description?: string }[]
  readonly defaultEffort?: string
}

/** One provider: where the engine calls and what it can call. */
export interface ProviderSpec {
  readonly id: string
  readonly name: string
  /** Base URL of an OpenAI-compatible deployment. */
  readonly baseUrl: string
  /** Path appended to the base URL. Defaults to `/chat/completions`. */
  readonly path?: string
  readonly models: readonly ModelSpec[]
  /**
   * Whether the provider reports usage on streamed completions. When true the
   * adapter asks for usage (OpenAI `stream_options.include_usage`) and the
   * session stats get real token counts.
   */
  readonly usage?: boolean
}

/** The whole kernel configuration. */
export interface KernelConfig {
  readonly providers: readonly ProviderSpec[]
  /** The model a new session uses until it sets its own. */
  readonly defaultModel: { readonly provider: string; readonly model: string; readonly reasoningEffort?: string }
  /** The context window reported in `session.stats`. */
  readonly contextWindow: number
  /** Extra text appended to the kernel's system prompt. */
  readonly systemPromptAddendum: string
  /** The permission preset a new session uses until it sets its own. */
  readonly defaultPreset: string
}

export const DEFAULT_CONFIG: KernelConfig = {
  providers: [
    {
      id: 'deepseek-official',
      name: 'DeepSeek',
      baseUrl: 'https://api.deepseek.com',
      path: '/chat/completions',
      usage: true,
      models: [
        {
          id: 'deepseek-chat',
          name: 'DeepSeek Chat',
          efforts: [{ id: 'off', name: 'Off', description: 'No reasoning phase.' }],
          defaultEffort: 'off',
        },
        {
          id: 'deepseek-reasoner',
          name: 'DeepSeek Reasoner',
          description: 'Reasoning-first model for hard problems.',
          efforts: [{ id: 'off', name: 'Off', description: 'The reasoner reasons by default.' }],
          defaultEffort: 'off',
        },
      ],
    },
  ],
  defaultModel: { provider: 'deepseek-official', model: 'deepseek-chat', reasoningEffort: 'off' },
  contextWindow: 128_000,
  systemPromptAddendum: '',
  defaultPreset: 'workspace-write',
}

/**
 * Merge a partial config from disk over the defaults.
 *
 * Arrays replace (a partial provider list means "these are my providers");
 * scalars replace when present. Unknown keys are dropped rather than carried:
 * a config file from a newer kernel must not smuggle fields into this one.
 */
export function mergeConfig(base: KernelConfig, patch: Record<string, unknown>): KernelConfig {
  const merged: { -readonly [K in keyof KernelConfig]: KernelConfig[K] } = { ...base }
  if (isProviderList(patch['providers'])) merged['providers'] = patch['providers']
  if (isModelRef(patch['defaultModel'])) merged['defaultModel'] = patch['defaultModel']
  if (typeof patch['contextWindow'] === 'number' && Number.isFinite(patch['contextWindow'])) {
    merged['contextWindow'] = patch['contextWindow']
  }
  if (typeof patch['systemPromptAddendum'] === 'string') {
    merged['systemPromptAddendum'] = patch['systemPromptAddendum']
  }
  if (typeof patch['defaultPreset'] === 'string') merged['defaultPreset'] = patch['defaultPreset']
  return merged
}

function isProviderList(value: unknown): value is readonly ProviderSpec[] {
  if (!Array.isArray(value)) return false
  return value.every(
    (item) =>
      typeof item === 'object' &&
      item !== null &&
      typeof (item as Record<string, unknown>)['id'] === 'string' &&
      typeof (item as Record<string, unknown>)['baseUrl'] === 'string' &&
      Array.isArray((item as Record<string, unknown>)['models']),
  )
}

function isModelRef(value: unknown): value is KernelConfig['defaultModel'] {
  if (typeof value !== 'object' || value === null) return false
  const fields = value as Record<string, unknown>
  return typeof fields['provider'] === 'string' && typeof fields['model'] === 'string'
}

/** Find one provider spec, or `null`. */
export function providerOf(config: KernelConfig, providerId: string): ProviderSpec | null {
  return config.providers.find((provider) => provider.id === providerId) ?? null
}

/** Find one model spec inside a provider, or `null`. */
export function modelOf(
  config: KernelConfig,
  providerId: string,
  modelId: string,
): ModelSpec | null {
  return providerOf(config, providerId)?.models.find((model) => model.id === modelId) ?? null
}
