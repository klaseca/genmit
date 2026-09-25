import assert from 'node:assert/strict'
import { once } from 'node:events'
import { createServer } from 'node:http'
import test from 'node:test'
import { providerSelectionKey, selectedProvider } from '../src/providerSelection.ts'
import { generate, listProviders, type ProcessRunner } from '../src/runtime.ts'

const runner: ProcessRunner = async (request) => {
  if (request.command !== 'git') return { code: 0, stdout: 'feat: configured', stderr: '' }
  const operation = request.args.join(' ')
  const stdout =
    operation === 'rev-parse --show-toplevel'
      ? '/repo\n'
      : operation.includes('--name-only')
        ? 'src/main.ts\0'
        : operation === 'branch --show-current'
          ? 'main\n'
          : operation.includes('--unified=3')
            ? '+change\n'
            : ''
  return { code: 0, stdout, stderr: '' }
}

test('arbitrary provider names use their configured kind, not a name-based mapping', async () => {
  const source = `provider = "work.codex"
[providers."work.codex"]
kind = "codex"
[providers."work.codex".config]
model = "work-model"
[providers.codex]
kind = "openai-responses"
[providers.codex.config]
endpoint = "http://localhost/responses"
model = "api-model"`
  const providers = listProviders(source)
  assert.ok(
    providers.some((provider) => provider.name === 'codex' && provider.kind === 'openai-responses'),
  )
  assert.equal(selectedProvider(providers, undefined), 'work.codex')
  let args: string[] | undefined
  const output = await generate(
    '/repo',
    { config_source: source },
    new AbortController().signal,
    async (request, signal) => {
      if (request.command === 'codex') args = request.args
      return runner(request, signal)
    },
  )
  assert.equal(output.provider, 'work.codex')
  assert.ok(args?.includes('work-model'))
})

test('custom harnesses and their providers are defined entirely in TOML', async () => {
  const source = `provider = "local"
[harnesses.pi]
executable = "pi"
args = ["--print"]
[harnesses.pi.parameters.model]
required = true
args = ["--model", "\${value}"]
[providers.local]
kind = "pi"
[providers.local.config]
model = "local-model"`
  assert.ok(
    listProviders(source).some(
      (provider) => provider.name === 'local' && provider.kind === 'pi' && provider.selected,
    ),
  )
  let args: string[] | undefined
  const output = await generate(
    '/repo',
    { config_source: source },
    new AbortController().signal,
    async (request, signal) => {
      if (request.command === 'pi') args = request.args
      return runner(request, signal)
    },
  )
  assert.equal(output.provider, 'local')
  assert.deepEqual(args, ['--print', '--model', 'local-model'])
})

test('a saved provider overrides the default and an unavailable provider falls back', async () => {
  const source = `provider = "codex"
[providers.work]
kind = "codex"
[providers.work.config]
model = "work-model"`
  const providers = listProviders(source)
  const provider = selectedProvider(providers, 'work')
  const output = await generate(
    '/repo',
    { config_source: source, provider },
    new AbortController().signal,
    runner,
  )
  assert.equal(output.provider, 'work')
  assert.equal(selectedProvider(providers, 'removed'), 'codex')
})

test('selections are independent per repository and config path', () => {
  assert.notEqual(
    providerSelectionKey('/repo', '/a.toml'),
    providerSelectionKey('/repo', '/b.toml'),
  )
  assert.notEqual(
    providerSelectionKey('/repo-a', '/a.toml'),
    providerSelectionKey('/repo-b', '/a.toml'),
  )
  assert.notEqual(
    providerSelectionKey('/repo', undefined),
    providerSelectionKey('/repo', '/a.toml'),
  )
})

test('provider lists reflect freshly loaded TOML and share core validation', () => {
  const source = `[providers.work]
kind = "codex"
[providers.work.config]
model = "work-model"`
  assert.ok(listProviders(source).some((provider) => provider.name === 'work'))
  assert.ok(!listProviders('').some((provider) => provider.name === 'work'))
  assert.throws(() => listProviders('provider = "missing"'), /has no matching/)
  assert.throws(() => listProviders('[invalid'), /invalid TOML/)
  assert.throws(
    () =>
      listProviders(`[providers.local]
kind = "openai-compatible"
[providers.local.config]
model = "local-model"`),
    /endpoint must not be empty/,
  )
})

test('an API provider named codex executes HTTP using only its TOML settings', async () => {
  let body: Record<string, unknown> = {}
  const server = createServer((request, response) => {
    let input = ''
    request.setEncoding('utf8')
    request.on('data', (chunk) => {
      input += chunk
    })
    request.on('end', () => {
      body = JSON.parse(input)
      response.setHeader('content-type', 'application/json')
      response.end(
        JSON.stringify({
          status: 'completed',
          output: [
            { type: 'message', content: [{ type: 'output_text', text: 'feat: named API' }] },
          ],
        }),
      )
    })
  })
  server.listen(0, '127.0.0.1')
  await once(server, 'listening')
  const address = server.address()
  assert.ok(address && typeof address !== 'string')
  try {
    const source = `[providers.codex]
kind = "openai-responses"
[providers.codex.config]
endpoint = "http://127.0.0.1:${address.port}"
model = "api-model"`
    assert.equal(
      listProviders(source).find((provider) => provider.name === 'codex')?.kind,
      'openai-responses',
    )
    const output = await generate(
      '/repo',
      { config_source: source },
      new AbortController().signal,
      async (request, signal) => {
        assert.equal(request.command, 'git', 'API provider must not spawn a harness')
        return runner(request, signal)
      },
    )
    assert.equal(output.message, 'feat: named API')
    assert.equal(body.model, 'api-model')
    assert.equal('reasoning' in body, false)
  } finally {
    server.closeAllConnections()
    await new Promise<void>((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    )
  }
})
