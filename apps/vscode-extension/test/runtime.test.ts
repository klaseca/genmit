import assert from 'node:assert/strict'
import { once } from 'node:events'
import { mkdtemp, rm, writeFile } from 'node:fs/promises'
import { createServer } from 'node:http'
import { tmpdir } from 'node:os'
import { basename, join } from 'node:path'
import test from 'node:test'
import { generate as generateRuntime } from '../moonbit-runtime/genmit-js-runtime.js'
import {
  isPathInside,
  runProcess,
  runProcessRequest,
  type ProcessOutput,
  type ProcessRequest,
} from '../src/process.ts'
import { generate, type ProcessRunner, type GenerationEvent } from '../src/runtime.ts'

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
    (error) => error === controller.signal.reason,
  )
  assert.equal(processCalls, 0)
})

test('cancellation from the started listener stops before Git and preserves its reason', async () => {
  const controller = new AbortController()
  const reason = new Error('cancel before collecting changes')
  const events: GenerationEvent[] = []
  let processCalls = 0

  await assert.rejects(
    generate(
      '/repo',
      undefined,
      controller.signal,
      async () => {
        processCalls += 1
        throw new Error('process must not run after cancellation')
      },
      (event) => {
        events.push(event)
        if (event.type === 'started') controller.abort(reason)
      },
    ),
    (error) => error === reason,
  )
  assert.equal(processCalls, 0)
  assert.deepEqual(
    events.map((event) => event.type),
    ['started', 'cancelled'],
  )
})

test('large diffs are summarized without dropping any diff chunk', async () => {
  const events: GenerationEvent[] = []
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
    { config_source: '[providers.codex]\nmax_input_chars = 24000' },
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
    (event) => events.push(event),
  )

  assert.equal(receivedChunks.join(''), diff)
  assert.ok(receivedChunks.length > 1)
  assert.ok(reductionCalls > 0)
  assert.equal(finalSummaries?.length, reductionCalls)
  assert.deepEqual(finalStagedFiles, ['src/main.mbt'])
  assert.equal(output.message, 'feat: summarize every staged change')
  const requests = events.filter((event) => event.type === 'request_started')
  assert.ok(requests.every((event) => event.input_chars <= 24000))
  assert.deepEqual(
    requests.map((event) => event.number),
    requests.map((_, index) => index + 1),
  )
  const summaries = requests.filter((event) => event.phase === 'summarize')
  assert.equal(summaries.length, receivedChunks.length)
  assert.deepEqual(
    summaries.map((event) => event.part),
    summaries.map((_, index) => index + 1),
  )
  assert.ok(summaries.every((event) => event.total === summaries.length))
  assert.equal(requests.filter((event) => event.phase === 'reduce').length, reductionCalls)
  assert.equal(requests.at(-1)?.phase, 'generate_message')
  assert.equal(events.at(-1)?.type, 'completed')
})

test('shared progress arrives while the provider is running and contains only metadata', async () => {
  const events: GenerationEvent[] = []
  const output = await generate(
    '/repo',
    undefined,
    new AbortController().signal,
    gitRunner(() => {
      assert.ok(events.some((event) => event.type === 'request_started'))
      assert.equal(
        events.some((event) => event.type === 'completed'),
        false,
      )
      return result(0, 'feat: generated', 'private diagnostic')
    }),
    (event) => events.push(event),
  )
  assert.equal(output.message, 'feat: generated')
  assert.deepEqual(
    events.map((event) => event.type),
    [
      'started',
      'collecting_changes',
      'changes_collected',
      'request_started',
      'request_completed',
      'completed',
    ],
  )
  const serialized = JSON.stringify(events)
  for (const privateData of ['+feature', 'src/main.mbt', 'private diagnostic', 'feat: generated']) {
    assert.equal(serialized.includes(privateData), false)
  }
})

test('failed requests report a single failed outcome and no successful completion', async () => {
  const events: GenerationEvent[] = []
  await assert.rejects(
    generate(
      '/repo',
      undefined,
      new AbortController().signal,
      gitRunner(() => result(1, '', 'private failure')),
      (event) => events.push(event),
    ),
    /private failure/,
  )
  assert.deepEqual(
    events.slice(-2).map((event) => event.type),
    ['request_failed', 'failed'],
  )
  assert.equal(
    events.some((event) => event.type === 'completed'),
    false,
  )
  assert.equal(JSON.stringify(events).includes('private failure'), false)
})

test('direct runtime subscriber failures stop generation and preserve the original error', async () => {
  for (const stage of ['started', 'completed', 'cancelled']) {
    const controller = new AbortController()
    const failure = new Error('observer failed')
    let providerCalls = 0
    await assert.rejects(
      generateRuntime(
        JSON.stringify({ root: '/repo' }),
        gitRunner((_request, signal) => {
          providerCalls += 1
          if (stage === 'cancelled') {
            controller.abort()
            signal.throwIfAborted()
          }
          return result(0, 'feat: generated')
        }),
        controller.signal,
        (event: GenerationEvent) => {
          if (event.type === stage) throw failure
        },
      ),
      (error) => error === failure,
    )
    assert.equal(providerCalls, stage === 'started' ? 0 : 1)
  }
})

test('a subscriber failure while reporting a provider failure preserves both errors', async () => {
  const observerFailure = new Error('observer failed')
  await assert.rejects(
    generate(
      '/repo',
      undefined,
      new AbortController().signal,
      gitRunner(() => result(1, '', 'provider failed')),
      (event) => {
        if (event.type === 'failed') throw observerFailure
      },
    ),
    (error) => {
      assert.ok(error instanceof AggregateError)
      assert.ok(error.errors.includes(observerFailure))
      assert.ok(error.errors.some((cause) => String(cause).includes('provider failed')))
      return true
    },
  )
})

test('cancellation preserves reason identity and does not hide cleanup failures', async () => {
  for (const reason of [
    undefined,
    new Error('same text'),
    new DOMException('custom deadline', 'TimeoutError'),
  ]) {
    for (const cleanupFails of [false, true]) {
      const controller = new AbortController()
      const events: GenerationEvent[] = []
      const failure = new Error(reason?.message ?? 'cleanup failed')
      failure.name = reason?.name ?? 'AbortError'
      await assert.rejects(
        generate(
          '/repo',
          undefined,
          controller.signal,
          gitRunner(
            (_request, signal) =>
              new Promise<ProcessOutput>((_resolve, reject) => {
                signal.addEventListener(
                  'abort',
                  () => reject(cleanupFails ? failure : signal.reason),
                  { once: true },
                )
                controller.abort(reason)
              }),
          ),
          (event) => events.push(event),
        ),
        (error) => {
          if (cleanupFails) {
            assert.notEqual(error, controller.signal.reason)
            assert.ok(String(error).includes(failure.message))
          } else {
            assert.equal(error, controller.signal.reason)
          }
          return true
        },
      )
      assert.deepEqual(
        events
          .filter((event) => ['failed', 'cancelled', 'completed'].includes(event.type))
          .map((event) => event.type),
        [cleanupFails ? 'failed' : 'cancelled'],
      )
    }
  }
})

test('whole-generation timeout preserves process shutdown failures', async () => {
  const events: GenerationEvent[] = []
  await assert.rejects(
    generate(
      '/repo',
      {
        config_source: '[generation]\ntimeout_ms = 20',
      },
      new AbortController().signal,
      gitRunner(
        (_request, signal) =>
          new Promise<ProcessOutput>((_resolve, reject) => {
            const abort = () =>
              setTimeout(() => reject(new Error('failed to terminate process tree')), 10)
            if (signal.aborted) abort()
            else signal.addEventListener('abort', abort, { once: true })
          }),
      ),
      (event) => events.push(event),
    ),
    /timed out after 20 ms; process failed during shutdown: .*failed to terminate process tree/,
  )
  assert.deepEqual(
    events.slice(-2).map((event) => event.type),
    ['request_failed', 'failed'],
  )
  assert.equal(events.filter((event) => event.type === 'failed').length, 1)
})

test('serialized provider request size triggers lossless chunking', async () => {
  const diff = `diff --git a/data b/data\n--- a/data\n+++ b/data\n@@ -1 +1 @@\n+${'\\'.repeat(20_000)}\n`
  const receivedChunks: string[] = []

  const output = await generate(
    '/repo',
    { config_source: '[providers.codex]\nmax_input_chars = 32000' },
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
      {
        config_source:
          '[generation]\nmax_provider_calls = 2\n[providers.codex]\nmax_input_chars = 32000',
      },
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
    generate(
      '/repo',
      { config_source: '[providers.codex]\nmax_input_chars = 32000' },
      new AbortController().signal,
      runner,
    ),
    /final request metadata exceeds providers\.codex\.max_input_chars/,
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
        { config_source: '[providers.codex]\nmax_input_chars = 32000' },
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

test('reduction reserves a provider call for the final result', async () => {
  const diff = `diff --git a/large b/large\n${'+change\n'.repeat(22_000)}`
  let providerCalls = 0

  await assert.rejects(
    generate(
      '/repo',
      {
        config_source:
          '[generation]\nmax_provider_calls = 8\n[providers.codex]\nmax_input_chars = 32000',
      },
      new AbortController().signal,
      gitRunner(() => {
        providerCalls += 1
        return result(0, 'summary '.repeat(900))
      }, diff),
    ),
    /requires at least .* provider calls.*max_provider_calls is 8/,
  )
  assert.ok(providerCalls > 0 && providerCalls < 8)
})

test('whole-generation timeout includes provider execution', async () => {
  const events: GenerationEvent[] = []
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
      (event) => events.push(event),
    ),
    /generation timed out after 10 ms/,
  )
  assert.equal(events.at(-1)?.type, 'failed')
  assert.equal(events.filter((event) => event.type === 'failed').length, 1)
  assert.equal(
    events.some((event) => event.type === 'completed'),
    false,
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
  const events: GenerationEvent[] = []
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
      (event) => events.push(event),
    )
    assert.equal(output.message, 'feat: over HTTP')
    assert.equal(events.at(-1)?.type, 'completed')
    assert.ok(events[0].type === 'started' && events[0].model === 'test-model')
    assert.equal(events.filter((event) => event.type === 'request_started').length, 1)
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

test('HTTP cancellation preserves its reason and emits one terminal event', async () => {
  for (const timeout of [false, true]) {
    const controller = new AbortController()
    const reason = new Error('cancel HTTP generation')
    const events: GenerationEvent[] = []
    const server = createServer((request) => {
      request.resume()
      if (!timeout) controller.abort(reason)
    })
    server.listen(0, '127.0.0.1')
    await once(server, 'listening')
    const address = server.address()
    if (!address || typeof address === 'string') throw new Error('expected server port')
    try {
      const config = `provider = "test"
[generation]
timeout_ms = ${timeout ? 100 : 1000}
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
          controller.signal,
          gitRunner(() => {
            throw new Error('unexpected process')
          }),
          (event) => events.push(event),
        ),
        (error) => (timeout ? /timed out after 100 ms/.test(String(error)) : error === reason),
      )
      assert.deepEqual(
        events
          .filter((event) => ['completed', 'failed', 'cancelled'].includes(event.type))
          .map((event) => event.type),
        [timeout ? 'failed' : 'cancelled'],
      )
    } finally {
      server.closeAllConnections()
      await new Promise<void>((resolve, reject) =>
        server.close((error) => (error ? reject(error) : resolve())),
      )
    }
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
