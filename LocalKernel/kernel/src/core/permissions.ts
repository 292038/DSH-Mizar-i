/**
 * Permission presets — how much of the workspace a turn may touch.
 *
 * The catalog values are the desktop host's, so the client's settings screen
 * reads them unchanged: `read-only`, `workspace-write`, `danger-full-access`.
 *
 * The kernel's own rule for what each preset *covers*:
 *
 *  - `read-only` — listing and reading the workspace. Mutating tools and the
 *    network are not covered: each such call raises an approval.
 *  - `workspace-write` — plus writing files inside the session's workspace.
 *    The network still raises an approval: preset names say *workspace*.
 *  - `danger-full-access` — everything the kernel can do, including the
 *    network and writes anywhere inside the kernel root.
 *
 * An action a preset does not cover raises an `approval.request` and waits.
 * The outcome is `allowed-once`: it covers exactly the call that asked. There
 * is deliberately no `always-allow` — a permission that outlives its request
 * is a permission change, and permission changes go through
 * `session.permission.set`, where they are visible and revocable.
 */

export const PRESET_IDS = ['read-only', 'workspace-write', 'danger-full-access'] as const

export type PresetId = (typeof PRESET_IDS)[number]

export interface ToolAction {
  readonly kind: 'list' | 'read' | 'write' | 'network'
  /** Whether the action stays inside the session's workspace directory. */
  readonly inWorkspace: boolean
}

/** Whether a preset covers an action outright (no approval needed). */
export function presetCovers(preset: string, action: ToolAction): boolean {
  switch (preset) {
    case 'read-only':
      return action.kind === 'list' || action.kind === 'read'
    case 'workspace-write':
      return action.kind === 'list' || action.kind === 'read' || (action.kind === 'write' && action.inWorkspace)
    case 'danger-full-access':
      return true
    default:
      // An unknown preset covers nothing — fail closed.
      return false
  }
}

/** The catalog the client's settings screen renders. */
export function permissionCatalog(): {
  options: { value: string; name: string }[]
  defaults: { value: string; name: string }[]
  defaultPreset: string
} {
  const options = PRESET_IDS.map((id) => ({ value: id, name: id }))
  return { options, defaults: options, defaultPreset: 'workspace-write' }
}
