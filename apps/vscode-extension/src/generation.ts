import { isPathInside } from './process.ts'

export interface Repository {
  rootUri: { fsPath: string }
  inputBox: { value: string }
}

export function isExpectedCancellation(error: unknown, signal: AbortSignal): boolean {
  if (!signal.aborted) {
    return false
  }

  if (error === signal.reason) {
    return true
  }

  return (
    error instanceof Error &&
    error.name === 'AbortError' &&
    signal.reason instanceof Error &&
    signal.reason.name === 'AbortError'
  )
}

export function repositoryForContext<T extends Repository>(
  repositories: readonly T[],
  context: unknown,
): T | undefined {
  if (context && typeof context === 'object' && 'rootUri' in context) {
    const uri = context.rootUri

    if (uri && typeof uri === 'object' && 'fsPath' in uri && typeof uri.fsPath === 'string') {
      const root = uri.fsPath

      const exact = repositories.find(
        (repo) =>
          isPathInside(repo.rootUri.fsPath, root) && isPathInside(root, repo.rootUri.fsPath),
      )

      if (exact) {
        return exact
      }
    }
  }

  return undefined
}

export class Generations {
  private readonly active = new Map<string, AbortController>()

  hasActive(): boolean {
    return this.active.size > 0
  }

  start(repository: Repository) {
    const key = repository.rootUri.fsPath
    this.active.get(key)?.abort()
    const controller = new AbortController()
    const initial = repository.inputBox.value
    this.active.set(key, controller)

    return {
      controller,
      isCurrent: () => this.active.get(key) === controller && !controller.signal.aborted,
      canApply: () =>
        this.active.get(key) === controller &&
        !controller.signal.aborted &&
        repository.inputBox.value === initial,
      finish: () => {
        if (this.active.get(key) === controller) {
          this.active.delete(key)
        }
      },
    }
  }

  cancelAll() {
    for (const controller of this.active.values()) {
      controller.abort()
    }
  }
}
