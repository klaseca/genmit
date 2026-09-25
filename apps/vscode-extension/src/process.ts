import { execFile, spawn, type ChildProcess } from 'node:child_process'
import { isAbsolute, join, relative, sep } from 'node:path'
import { promisify } from 'node:util'

const execFileAsync = promisify(execFile)

async function terminateProcessTree(child: ChildProcess): Promise<void> {
  if (child.pid === undefined) {
    return
  }

  try {
    if (process.platform === 'win32') {
      const systemRoot = process.env.SystemRoot

      if (!systemRoot) {
        throw new Error('Windows SystemRoot is unavailable')
      }

      await execFileAsync(
        join(systemRoot, 'System32', 'taskkill.exe'),
        ['/PID', String(child.pid), '/T', '/F'],
        { windowsHide: true, timeout: 5000 },
      )
    } else {
      // Each spawned command owns a process group, including its descendants.
      process.kill(-child.pid, 'SIGKILL')
    }
  } catch (error) {
    if (
      (error as NodeJS.ErrnoException).code === 'ESRCH' ||
      child.exitCode !== null ||
      child.signalCode !== null
    ) {
      return
    }

    // Still stop the direct child if tree termination fails, but report the failure.
    child.kill('SIGKILL')
    throw error
  }
}

export interface ProcessOutput {
  code: number
  stdout: string
  stderr: string
}

export interface ProcessOptions {
  signal?: AbortSignal
  maxOutputBytes?: number
}

export async function runProcess(
  command: string,
  args: string[],
  cwd: string,
  input = '',
  timeoutMs = 180_000,
  options: ProcessOptions = {},
): Promise<ProcessOutput> {
  options.signal?.throwIfAborted()

  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {
      cwd,
      shell: false,
      stdio: ['pipe', 'pipe', 'pipe'],
      windowsHide: true,
      detached: process.platform !== 'win32',
    })

    const stdout: Buffer[] = []

    const stderr: Buffer[] = []

    let outputBytes = 0

    let errorBytes = 0

    let settled = false

    let failure: Error | undefined

    let inputError: Error | undefined

    let termination: Promise<void> | undefined

    const cleanup = () => {
      clearTimeout(timer)
      options.signal?.removeEventListener('abort', abort)
    }

    const fail = (error: Error) => {
      if (settled || failure) {
        return
      }

      failure = error
      cleanup()

      termination = terminateProcessTree(child)
        .catch((cause: Error) => {
          failure = new Error(
            `${error.message}; failed to terminate '${command}' process tree: ${cause.message}`,
            { cause },
          )
        })
        .finally(() => {
          child.stdin.destroy()
          child.stdout.destroy()
          child.stderr.destroy()
        })
    }

    const abort = () => fail(options.signal?.reason ?? new Error('Generation cancelled'))

    const timer = setTimeout(() => fail(new Error(`command '${command}' timed out`)), timeoutMs)

    options.signal?.addEventListener('abort', abort, { once: true })

    child.stdout.on('data', (chunk: Buffer) => {
      if (failure) {
        return
      }

      outputBytes += chunk.length

      if (outputBytes > (options.maxOutputBytes ?? 16 * 1024 * 1024)) {
        fail(new Error(`command '${command}' output exceeds the byte limit`))
      } else if (!settled) {
        stdout.push(chunk)
      }
    })

    child.stderr.on('data', (chunk: Buffer) => {
      if (failure) {
        return
      }

      errorBytes += chunk.length

      if (errorBytes > 1024 * 1024) {
        fail(new Error(`command '${command}' stderr exceeds the byte limit`))
      } else if (!settled) {
        stderr.push(chunk)
      }
    })

    child.stdin.on('error', (error: NodeJS.ErrnoException) => {
      if (error.code === 'EPIPE' || error.code === 'EOF') {
        inputError = new Error(`failed to write to '${command}': ${error.message}`)
      } else {
        fail(new Error(`failed to write to '${command}': ${error.message}`))
      }
    })

    child.stdout.on('error', fail)

    child.stderr.on('error', fail)

    child.once('error', (error) =>
      fail(new Error(`failed to run command '${command}': ${error.message}`)),
    )

    child.once('close', async (code) => {
      if (settled) {
        return
      }

      settled = true
      cleanup()
      await termination

      if (failure) {
        reject(failure)
        return
      }

      if (inputError && code === 0) {
        reject(inputError)
        return
      }

      resolve({
        code: code ?? -1,
        stdout: Buffer.concat(stdout).toString('utf8'),
        stderr: Buffer.concat(stderr).toString('utf8'),
      })
    })

    if (options.signal?.aborted) {
      abort()
    } else {
      child.stdin.end(input)
    }
  })
}

export interface ProcessRequest {
  command: string
  args: string[]
  cwd: string
  input: string
  timeoutMs: number
  maximumOutputBytes: number
}

export function runProcessRequest(
  request: ProcessRequest,
  signal: AbortSignal,
): Promise<ProcessOutput> {
  return runProcess(request.command, request.args, request.cwd, request.input, request.timeoutMs, {
    signal,
    maxOutputBytes: request.maximumOutputBytes,
  })
}

export function isPathInside(root: string, candidate: string): boolean {
  const path = relative(root, candidate)

  return path === '' || (!path.startsWith(`..${sep}`) && path !== '..' && !isAbsolute(path))
}
