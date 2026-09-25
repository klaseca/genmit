import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import test from 'node:test'
import {
  isPathInside,
  runProcess,
  runProcessRequest,
  type ProcessOutput,
  type ProcessRequest,
} from '../src/process.ts'
import { generate, type ProcessRunner } from '../src/runtime.ts'

function result(code = 0, stdout = '', stderr = ''): ProcessOutput {
  return { code, stdout, stderr }
}

function gitRunner(
  onProvider: (
    request: ProcessRequest,
    signal: AbortSignal,
  ) => ProcessOutput | Promise<ProcessOutput>,
  diff = '+feature\n',
): ProcessRunner {
  return async (request, signal) => {
    if (request.command !== 'git') return onProvider(request, signal)
    const operation = request.args.join(' ')
    if (operation === 'rev-parse --show-toplevel') return result(0, '/repo\n')
    if (operation.includes('--name-only')) return result(0, 'src/main.mbt\0')
    if (operation === 'branch --show-current') return result(0, 'main\n')
    if (operation.includes('--unified=3')) return result(0, diff)
    if (operation === 'log --ignore-missing -5 --pretty=format:%s HEAD') {
      return result(0, 'chore: start\n')
    }
    throw new Error(`unexpected Git process request: ${operation}`)
  }
}

test('MoonBit owns Git collection, prompt construction, provider execution, and normalization', async () => {
  let providerRequest: ProcessRequest | undefined
  const output = await generate(
    '/repo',
    undefined,
    new AbortController().signal,
    gitRunner((request) => {
      providerRequest = request
      return result(0, '```text\r\nfeat: generated\r\n```\r\n')
    }),
  )

  assert.equal(providerRequest?.command, 'codex')
  assert.equal(providerRequest?.cwd, '/repo')
  const promptData = JSON.parse(providerRequest?.input.split('\n').at(-1) ?? '') as {
    staged_diff: string
  }
  assert.equal(promptData.staged_diff, '+feature\n')
  assert.deepEqual(output, {
    protocol_version: 1,
    message: 'feat: generated',
    provider: 'codex',
    files: ['src/main.mbt'],
  })
})

test('generation stops before invoking MoonBit when its signal is already aborted', async () => {
  const controller = new AbortController()
  controller.abort(new DOMException('cancelled', 'AbortError'))
  let processCalls = 0

  await assert.rejects(
    generate('/repo', undefined, controller.signal, async () => {
      processCalls += 1
      throw new Error('process must not run after cancellation')
    }),
    (error: unknown) => error === controller.signal.reason,
  )
  assert.equal(processCalls, 0)
})

test('large diffs are summarized without dropping any diff chunk', async () => {
  const diff =
    `diff --git a/first b/first\n${'+first change\n'.repeat(10_000)}` +
    `diff --git a/second b/second\n${'+second change\n'.repeat(10_000)}`
  const receivedChunks: string[] = []
  let finalSummaries: string[] | undefined
  let finalStagedFiles: string[] | undefined
  let summaryNumber = 0
  let reductionCalls = 0

  const output = await generate(
    '/repo',
    undefined,
    new AbortController().signal,
    gitRunner((request) => {
      const serialized = request.input as string
      const data = JSON.parse(serialized.split('\n').at(-1) ?? '') as {
        staged_diff_chunk?: string
        staged_change_summaries?: string[]
        staged_files?: string[]
      }
      if (data.staged_diff_chunk !== undefined) {
        receivedChunks.push(data.staged_diff_chunk)
        summaryNumber += 1
        return result(0, `Chunk ${summaryNumber}: ${'distinct staged detail '.repeat(90)}`)
      }
      if (serialized.startsWith('Combine all supplied staged-change summaries')) {
        reductionCalls += 1
        return result(0, `Reduced summary group ${reductionCalls}.`)
      }
      finalSummaries = data.staged_change_summaries
      finalStagedFiles = data.staged_files
      return result(0, 'feat: summarize every staged change')
    }, diff),
  )

  assert.equal(receivedChunks.join(''), diff)
  assert.ok(receivedChunks.length > 1)
  assert.ok(reductionCalls > 0)
  assert.equal(finalSummaries?.length, reductionCalls)
  assert.deepEqual(finalStagedFiles, ['src/main.mbt'])
  assert.equal(output.message, 'feat: summarize every staged change')
})

test('serialized provider request size triggers lossless chunking', async () => {
  const diff = `diff --git a/data b/data\n--- a/data\n+++ b/data\n@@ -1 +1 @@\n+${'\\'.repeat(20_000)}\n`
  const receivedChunks: string[] = []

  const output = await generate(
    '/repo',
    undefined,
    new AbortController().signal,
    gitRunner((request) => {
      const serialized = request.input as string
      const data = JSON.parse(serialized.split('\n').at(-1) ?? '') as {
        staged_diff_chunk?: string
      }
      if (data.staged_diff_chunk !== undefined) {
        receivedChunks.push(data.staged_diff_chunk)
        return result(0, 'Escaped data changed.')
      }
      return result(0, 'fix: preserve escaped staged data')
    }, diff),
  )

  assert.ok(receivedChunks.length > 1)
  assert.equal(receivedChunks.join(''), diff)
  assert.equal(output.message, 'fix: preserve escaped staged data')
})

test('large diff fan-out is rejected before the first provider call', async () => {
  const diff = `diff --git a/large b/large\n${'+change\n'.repeat(6_000)}`
  let providerCalls = 0

  await assert.rejects(
    generate(
      '/repo',
      { config_source: '[generation]\nmax_provider_calls = 2' },
      new AbortController().signal,
      gitRunner((request) => {
        providerCalls += 1
        throw new Error(`unexpected provider request: ${request.command}`)
      }, diff),
    ),
    /requires at least .* provider calls.*max_provider_calls is 2/,
  )
  assert.equal(providerCalls, 0)
})

test('oversized staged-file metadata fails before any provider call', async () => {
  const files = Array.from(
    { length: 1_000 },
    (_, index) => `very/long/generated/path/number-${index}/source.mbt`,
  )
  let providerCalls = 0
  const baseRunner = gitRunner(() => {
    providerCalls += 1
    throw new Error('provider must not run with oversized metadata')
  })
  const runner: ProcessRunner = (request, signal) => {
    if (request.command === 'git' && request.args.includes('--name-only')) {
      return Promise.resolve(result(0, `${files.join('\0')}\0`))
    }
    return baseRunner(request, signal)
  }

  await assert.rejects(
    generate('/repo', undefined, new AbortController().signal, runner),
    /final request metadata exceeds the provider request limit/,
  )
  assert.equal(providerCalls, 0)
})

test('empty and oversized diff summaries are rejected before the final request', async () => {
  const diff = `diff --git a/large b/large\n${'+change\n'.repeat(6_000)}`

  for (const [summary, expected] of [
    ['   ', /empty staged-change summary/],
    ['x'.repeat(8_001), /summary longer than 8000 characters/],
  ] as const) {
    let providerCalls = 0
    await assert.rejects(
      generate(
        '/repo',
        undefined,
        new AbortController().signal,
        gitRunner(() => {
          providerCalls += 1
          return result(0, summary)
        }, diff),
      ),
      expected,
    )
    assert.equal(providerCalls, 1)
  }
})

test('summary and reduction calls cannot exceed the generation budget', async () => {
  const diff = `diff --git a/large b/large\n${'+change\n'.repeat(9_000)}`
  let providerCalls = 0

  await assert.rejects(
    generate(
      '/repo',
      { config_source: '[generation]\nmax_provider_calls = 8' },
      new AbortController().signal,
      gitRunner(() => {
        providerCalls += 1
        return result(0, 'summary '.repeat(900))
      }, diff),
    ),
    /exceeded generation\.max_provider_calls \(8\)/,
  )
  assert.equal(providerCalls, 8)
})

test('whole-generation timeout includes provider execution', async () => {
  await assert.rejects(
    generate(
      '/repo',
      { config_source: '[generation]\ntimeout_ms = 10' },
      new AbortController().signal,
      gitRunner(
        (_request, signal) =>
          new Promise<ProcessOutput>((_resolve, reject) => {
            const abort = () => reject(signal.reason)
            if (signal.aborted) abort()
            else signal.addEventListener('abort', abort, { once: true })
          }),
      ),
    ),
    /generation timed out after 10 ms/,
  )
})

test('MoonBit reports configuration and provider failures across the async boundary', async () => {
  const runner = gitRunner(() => result(9, '', 'provider failed'))
  await assert.rejects(
    generate(
      '/repo',
      { config_source: 'provider = "missing"' },
      new AbortController().signal,
      runner,
    ),
    /provider 'missing' has no matching/,
  )
  await assert.rejects(
    generate('/repo', undefined, new AbortController().signal, runner),
    /provider failed/,
  )
})

test('MoonBit surfaces Git metadata failures instead of inventing fallbacks', async () => {
  const runner: ProcessRunner = async (request) => {
    const operation = request.args.join(' ')
    if (operation === 'rev-parse --show-toplevel') return result(0, '/repo\n')
    if (operation.includes('--name-only')) return result(0, 'src/main.mbt\0')
    if (operation === 'branch --show-current') return result(128, '', 'branch lookup failed')
    throw new Error(`unexpected process request: ${request.command} ${operation}`)
  }

  await assert.rejects(
    generate('/repo', undefined, new AbortController().signal, runner),
    /git branch --show-current failed: branch lookup failed/,
  )
})

test('MoonBit performs HTTP provider requests in the JavaScript runtime', async () => {
  let body = ''
  const server = createServer((request, response) => {
    request.setEncoding('utf8')
    request.on('data', (chunk) => {
      body += chunk
    })
    request.on('end', () => {
      response.setHeader('content-type', 'application/json')
      response.end(
        JSON.stringify({
          status: 'completed',
          output: [
            {
              type: 'message',
              content: [{ type: 'output_text', text: 'feat: over HTTP' }],
            },
          ],
        }),
      )
    })
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('expected server port')
  try {
    const config = `provider = "test"
[providers.test]
kind = "openai-responses"
[providers.test.config]
endpoint = "http://127.0.0.1:${address.port}"
model = "test-model"
api_key_env = ""
max_tokens = 2048`
    const output = await generate(
      '/repo',
      { config_source: config },
      new AbortController().signal,
      gitRunner(() => {
        throw new Error('HTTP providers must not invoke the process host')
      }),
    )
    assert.equal(output.message, 'feat: over HTTP')
    const requestBody = JSON.parse(body) as Record<string, unknown>
    assert.equal(requestBody.model, 'test-model')
    assert.equal(requestBody.store, false)
    assert.equal(requestBody.max_output_tokens, 2048)
    assert.match(requestBody.instructions as string, /only staged changes/)
    assert.equal(JSON.parse(requestBody.input as string).staged_diff, '+feature\n')
  } finally {
    server.closeAllConnections()
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    )
  }
})

test('MoonBit normalizes HTTP transport failures', async () => {
  const server = createServer((request) => request.socket.destroy())
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const address = server.address()
  if (!address || typeof address === 'string') throw new Error('expected server port')
  try {
    const config = `provider = "test"
[providers.test]
kind = "openai-responses"
[providers.test.config]
endpoint = "http://127.0.0.1:${address.port}"
model = "test-model"
api_key_env = ""`
    await assert.rejects(
      generate(
        '/repo',
        { config_source: config },
        new AbortController().signal,
        gitRunner(() => {
          throw new Error('HTTP providers must not invoke the process host')
        }),
      ),
      /provider request failed/,
    )
  } finally {
    server.closeAllConnections()
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    )
  }
})

test('MoonBit normalizes process host failures', async () => {
  await assert.rejects(
    generate(
      '/repo',
      undefined,
      new AbortController().signal,
      gitRunner(() => {
        throw new Error('spawn failed')
      }),
    ),
    /failed to run command 'codex': .*spawn failed/,
  )
})

test('real Git is reached only through the process capability supplied to MoonBit', async () => {
  const root = await mkdtemp(join(tmpdir(), 'genmit-runtime-test-'))
  try {
    await runProcess('git', ['init', '--quiet', '--initial-branch=main'], root)
    const name = 'space 🌙.txt'
    await writeFile(join(root, name), 'staged-content\n')
    await runProcess('git', ['add', '--', name], root)
    const runner: ProcessRunner = async (request, signal) => {
      return request.command === 'git'
        ? runProcessRequest(request, signal)
        : result(0, 'feat: staged file')
    }
    const output = await generate(root, undefined, new AbortController().signal, runner)
    assert.deepEqual(output.files, [name])
    assert.equal(output.message, 'feat: staged file')
  } finally {
    assert.ok(isPathInside(tmpdir(), root) && basename(root).startsWith('genmit-runtime-test-'))
    await rm(root, { recursive: true, force: true })
  }
})

test('recent commit subjects come from HEAD, not unrelated branches', async () => {
  const root = await mkdtemp(join(tmpdir(), 'genmit-runtime-test-'))
  const git = async (...args: string[]) => {
    const output = await runProcess('git', args, root)
    assert.equal(output.code, 0, output.stderr)
  }
  const commit = async (message: string) => {
    await git(
      '-c',
      'user.name=Test',
      '-c',
      'user.email=test@example.com',
      'commit',
      '--quiet',
      '-m',
      message,
    )
  }

  try {
    await git('init', '--quiet', '--initial-branch=main')
    await writeFile(join(root, 'change.txt'), 'initial\n')
    await git('add', '--', 'change.txt')
    await commit('main history')
    await git('switch', '--quiet', '-c', 'unrelated')
    await writeFile(join(root, 'change.txt'), 'unrelated change\n')
    await git('add', '--', 'change.txt')
    await commit('unrelated history')
    await git('switch', '--quiet', 'main')
    await writeFile(join(root, 'change.txt'), 'staged change\n')
    await git('add', '--', 'change.txt')

    let recentSubjects: string | undefined
    await generate(root, undefined, new AbortController().signal, (request, signal) => {
      if (request.command === 'git') return runProcessRequest(request, signal)
      const data = JSON.parse(request.input.split('\n').at(-1) ?? '') as {
        recent_commit_subjects: string
      }
      recentSubjects = data.recent_commit_subjects
      return Promise.resolve(result(0, 'feat: staged change'))
    })
    assert.equal(recentSubjects, 'main history')
  } finally {
    assert.ok(isPathInside(tmpdir(), root) && basename(root).startsWith('genmit-runtime-test-'))
    await rm(root, { recursive: true, force: true })
  }
})
