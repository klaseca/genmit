import { access, readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join, resolve } from 'node:path'

async function exists(path: string): Promise<boolean> {
  try {
    await access(path)

    return true
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code === 'ENOENT') {
      return false
    }

    throw error
  }
}

export function userConfigPath(
  environment: NodeJS.ProcessEnv,
  fallbackHome = homedir(),
): string | undefined {
  if (environment.GENMIT_HOME) {
    return join(environment.GENMIT_HOME, 'config.toml')
  }

  return fallbackHome ? join(fallbackHome, '.config', 'genmit', 'config.toml') : undefined
}

export async function loadConfigSource(
  repositoryRoot: string,
  explicitPath: string,
  globalPath = userConfigPath(process.env),
): Promise<string | undefined> {
  const path = externalConfigPath(repositoryRoot, explicitPath, globalPath)

  if (!path) {
    return undefined
  }

  if (!(await exists(path))) {
    if (explicitPath) {
      throw new Error(`config file '${path}' does not exist`)
    }

    return undefined
  }

  return readFile(path, 'utf8')
}

export function externalConfigPath(
  repositoryRoot: string,
  explicitPath: string,
  globalPath = userConfigPath(process.env),
): string | undefined {
  return explicitPath ? resolve(repositoryRoot, explicitPath) : globalPath
}
