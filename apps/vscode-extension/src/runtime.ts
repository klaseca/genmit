import {
  generate as generateWithMoonBit,
  list_providers,
} from '../moonbit-runtime/genmit-js-runtime.js'
import { runProcessRequest, type ProcessOutput, type ProcessRequest } from './process.ts'
import type { GenerationResult } from './types.ts'

interface RuntimeSuccess {
  ok: true
  value: GenerationResult
}

interface RuntimeFailure {
  ok: false
  error: string
  cancelled?: boolean
}

type RuntimeResponse = RuntimeSuccess | RuntimeFailure

// The host supplies only TOML text and an optional named provider selection.
export interface ConfigurationInput {
  config_source?: string
  provider?: string
}

export interface ProviderInfo {
  name: string
  kind: string
  selected: boolean
}

export function listProviders(source?: string): ProviderInfo[] {
  const response = list_providers(JSON.stringify({ config_source: source })) as
    { ok: true; value: ProviderInfo[] } | RuntimeFailure

  if (!response.ok) {
    throw new Error(response.error)
  }

  return response.value
}

export type ProcessRunner = (request: ProcessRequest, signal: AbortSignal) => Promise<ProcessOutput>

export type GenerationEvent = { message: string } & (
  | { type: 'started'; provider: string; model: string | null }
  | { type: 'collecting_changes' }
  | { type: 'changes_collected'; files: number; diff_chars: number }
  | ({ type: 'request_started'; number: number; input_chars: number; stage: string } & (
      | { phase: 'summarize'; part: number; total: number }
      | { phase: 'reduce'; round: number; part: number; total: number }
      | { phase: 'generate_message' }
    ))
  | { type: 'request_completed' | 'request_failed'; number: number; duration_ms: number }
  | { type: 'completed' | 'failed' | 'cancelled'; duration_ms: number }
)

export type ProgressListener = (event: GenerationEvent) => void

type MoonBitGenerate = (
  input: string,
  runner: ProcessRunner,
  signal: AbortSignal,
  onEvent?: ProgressListener,
) => Promise<RuntimeResponse>

const moonBitGenerate = generateWithMoonBit as MoonBitGenerate

export async function generate(
  root: string,
  config: ConfigurationInput | undefined,
  signal: AbortSignal,
  runner: ProcessRunner = runProcessRequest,
  onEvent?: ProgressListener,
): Promise<GenerationResult> {
  signal.throwIfAborted()

  const response = await moonBitGenerate(
    JSON.stringify({
      root,
      ...config,
    }),
    runner,
    signal,
    onEvent,
  )

  if (!response.ok) {
    if (response.cancelled) {
      signal.throwIfAborted()
    }

    throw new Error(response.error)
  }

  if (response.value.protocol_version !== 1) {
    throw new Error(`Unsupported MoonBit runtime protocol ${response.value.protocol_version}`)
  }

  return response.value
}
