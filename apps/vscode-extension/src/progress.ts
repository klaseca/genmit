import type { GenerationEvent, ProgressListener } from './runtime.ts'
import type { LogOutputChannel, StatusBarItem } from 'vscode'

type Status = Pick<StatusBarItem, 'text' | 'tooltip' | 'show' | 'hide'>

type Output = Pick<LogOutputChannel, 'info' | 'warn' | 'error'>

type LogLevel = keyof Output

export type GenerationOutcome = 'applied' | 'opened_in_editor' | 'failed' | 'cancelled'

interface ActiveProgress {
  root: string
  label: string
  started: number
  startedAt: string
  lastEventAt: string
  terminal?: 'completed' | 'failed' | 'cancelled'
}

/** Frontend presentation only; the shared runtime supplies all workflow stages. */
export class GenerationProgress {
  private readonly active = new Map<number, ActiveProgress>()
  private nextId = 0
  private readonly status: Status
  private readonly output: Output
  private readonly now: () => number

  constructor(status: Status, output: Output, now: () => number = () => performance.now()) {
    this.status = status
    this.output = output
    this.now = now
  }

  start(root: string) {
    const id = ++this.nextId
    const started = this.now()
    const startedAt = new Date().toLocaleTimeString()
    const state: ActiveProgress = {
      root,
      label: 'Preparing generation',
      started,
      startedAt,
      lastEventAt: startedAt,
    }
    this.active.set(id, state)
    try {
      this.log(id, state, state.label)
      this.render()
      this.status.show()
    } catch (error) {
      this.active.delete(id)
      this.render()
      throw error
    }

    const onEvent: ProgressListener = (event: GenerationEvent) => {
      if (!this.active.has(id) || state.terminal) {
        return
      }

      state.lastEventAt = new Date().toLocaleTimeString()

      if (event.type === 'collecting_changes' || event.type === 'request_started') {
        state.label = event.type === 'request_started' ? event.stage : event.message
      }

      if (event.type === 'completed' || event.type === 'failed' || event.type === 'cancelled') {
        state.terminal = event.type
      }

      if (event.type === 'completed') {
        state.label = 'Applying generated message'
      }

      const level =
        event.type === 'failed' ? 'error' : event.type === 'request_failed' ? 'warn' : 'info'
      this.log(id, state, event.message, level)
      this.render()
    }

    return {
      onEvent,
      finish: (outcome: GenerationOutcome) => {
        if (!this.active.has(id)) {
          return
        }
        this.active.delete(id)
        try {
          // Config failures and cancellation before entering the runtime also get
          // a terminal log entry. Runtime terminal events are never duplicated.
          if (!state.terminal) {
            const terminal =
              outcome === 'applied' || outcome === 'opened_in_editor' ? 'completed' : outcome
            this.log(
              id,
              state,
              `Generation ${terminal} after ${this.seconds(state.started)} s`,
              outcome === 'failed' ? 'error' : 'info',
            )
          } else if (state.terminal === 'completed') {
            const message = {
              applied: 'Generated message applied',
              opened_in_editor: 'Generated message opened in editor',
              failed: 'Failed to apply generated message',
              cancelled: 'Generated message discarded after cancellation',
            }[outcome]
            this.log(id, state, message, outcome === 'failed' ? 'error' : 'info')
          }
        } finally {
          this.render()
        }
      },
    }
  }

  private seconds(since: number): number {
    return Math.floor(Math.max(0, this.now() - since) / 1000)
  }

  private log(id: number, state: ActiveProgress, message: string, level: LogLevel = 'info'): void {
    const singleLine = (value: string) => value.replace(/[\r\n]/g, ' ')
    this.output[level](`[#${id} ${singleLine(state.root)}] ${singleLine(message)}`)
  }

  private render(): void {
    const state = Array.from(this.active.values()).at(-1)

    if (!state) {
      this.status.hide()
      this.status.text = ''
      this.status.tooltip = undefined
      return
    }

    const text = `$(sync~spin) ${state.label}`

    if (this.status.text !== text) {
      this.status.text = text
    }

    const tooltip = [
      state.root,
      `Stage: ${state.label}`,
      `Started: ${state.startedAt}`,
      `Last event: ${state.lastEventAt}`,
      ...(this.active.size > 1 ? [`Active generations: ${this.active.size}`] : []),
      'Click to cancel all active generations. Logs: Output → genmit.',
    ].join('\n')

    // Reassigning a tooltip can dismiss an open hover, even if it is unchanged.
    if (this.status.tooltip !== tooltip) {
      this.status.tooltip = tooltip
    }
  }

  dispose(): void {
    this.active.clear()
    this.render()
  }
}
