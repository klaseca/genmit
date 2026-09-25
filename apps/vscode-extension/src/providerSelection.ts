import type { ProviderInfo } from './runtime.ts'

export function providerSelectionKey(root: string, path: string | undefined): string {
  return `providerSelection:${JSON.stringify([root, path ?? null])}`
}

export function selectedProvider(
  providers: ProviderInfo[],
  saved: string | undefined,
): string | undefined {
  return (
    providers.find((provider) => provider.name === saved)?.name ??
    providers.find((provider) => provider.selected)?.name
  )
}
