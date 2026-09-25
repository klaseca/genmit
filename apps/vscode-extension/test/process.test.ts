import assert from 'node:assert/strict'
import { once } from 'node:events'
import { createConnection, createServer, type Server } from 'node:net'
import test from 'node:test'
import { setTimeout as delay } from 'node:timers/promises'
import { isPathInside, runProcess } from '../src/process.ts'

const node = (code: string, input = '', timeout = 5000, options = {}) =>
  runProcess(process.execPath, ['-e', code], process.cwd(), input, timeout, options)

test('path containment respects directory boundaries', () => {
  assert.equal(isPathInside('/work/repo', '/work/repo/a'), true)
  assert.equal(isPathInside('/work/repo', '/work/repository/a'), false)
})

test('process captures stdout, stderr and Unicode input', async () => {
  const output = await node(
    "process.stdin.pipe(process.stdout); process.stderr.write('diagnostic')",
    'Hello 🌙',
  )
  assert.deepEqual(output, { code: 0, stdout: 'Hello 🌙', stderr: 'diagnostic' })
})

test('early process exit resolves safely instead of emitting an uncaught stdin error', async () => {
  assert.equal((await node('process.exit(7)', 'x'.repeat(8 * 1024 * 1024))).code, 7)
})

test('successful process must consume the complete input', async () => {
  await assert.rejects(
    node(
      "process.stdin.destroy(); process.stdout.write('partial'); setTimeout(() => process.exit(0), 100)",
      'x'.repeat(8 * 1024 * 1024),
    ),
    /failed to write/,
  )
})

test('process spawn errors reject and nonzero exits are returned to MoonBit', async () => {
  await assert.rejects(
    runProcess('genmit-missing-command-09f88', [], process.cwd()),
    /failed to run/,
  )
  assert.deepEqual(await node("process.stderr.write('bad input'); process.exitCode = 2"), {
    code: 2,
    stdout: '',
    stderr: 'bad input',
  })
})

test('process timeout and cancellation stop a waiting child', async () => {
  await assert.rejects(node('setInterval(() => {}, 1000)', '', 100), /timed out/)
  const controller = new AbortController()
  const running = node('setInterval(() => {}, 1000)', '', 5000, { signal: controller.signal })
  controller.abort()
  await assert.rejects(running, { name: 'AbortError' })
})

async function reportedPort(server: Server): Promise<number> {
  const [socket] = await once(server, 'connection', { signal: AbortSignal.timeout(5000) })
  let data = ''
  for await (const chunk of socket) data += chunk.toString()
  return JSON.parse(data).port as number
}

async function connectToDescendant(port: number, shutdown = false): Promise<boolean> {
  return new Promise((resolve, reject) => {
    const socket = createConnection(port, '127.0.0.1')
    socket.once('connect', () => {
      if (shutdown) socket.end('shutdown')
      else socket.destroy()
      resolve(true)
    })
    socket.once('error', (error: NodeJS.ErrnoException) => {
      if (error.code === 'ECONNREFUSED') resolve(false)
      else reject(error)
    })
  })
}

for (const mode of ['cancellation', 'timeout', 'output limit'] as const) {
  test(`process ${mode} stops the harness process tree`, { timeout: 15000 }, async () => {
    const reporter = createServer()
    reporter.listen(0, '127.0.0.1')
    await once(reporter, 'listening')
    const address = reporter.address()
    if (!address || typeof address === 'string') throw new Error('expected reporter port')

    const descendantCode = `
      const net = require('node:net');
      const server = net.createServer(socket => socket.on('data', () => process.exit(0)));
      server.listen(0, '127.0.0.1', () => {
        process.send({ port: server.address().port });
      });
    `
    const parentCode = `
      const child = require('node:child_process').spawn(process.execPath,
        ['-e', ${JSON.stringify(descendantCode)}], { stdio: ['ignore', 'inherit', 'inherit', 'ipc'] });
      child.once('message', message => {
        const report = require('node:net').createConnection(${address.port}, '127.0.0.1', () => {
          report.end(JSON.stringify(message));
        });
        report.once('close', () => {
          if (${mode === 'output limit'}) process.stdout.write('x'.repeat(10000));
        });
      });
      setInterval(() => {}, 1000);
    `
    const portPromise = reportedPort(reporter)
    const controller = new AbortController()
    const running = node(parentCode, '', 5000, {
      signal: controller.signal,
      maxOutputBytes: mode === 'output limit' ? 100 : undefined,
    })
    const rejection = assert.rejects(
      running,
      mode === 'cancellation'
        ? { name: 'AbortError' }
        : mode === 'timeout'
          ? /timed out/
          : /byte limit/,
    )
    let port: number | undefined
    try {
      port = await portPromise
      if (mode === 'cancellation') controller.abort()
      await rejection
      // SIGKILL delivery to the descendant can lag the direct child's close event.
      const deadline = Date.now() + 2000
      while ((await connectToDescendant(port)) && Date.now() < deadline) await delay(20)
      assert.equal(await connectToDescendant(port), false)
    } finally {
      controller.abort()
      await rejection.catch(() => {})
      // A regressed implementation must not leave the test's descendant behind.
      if (port !== undefined) await connectToDescendant(port, true)
      await new Promise<void>((resolve) => reporter.close(() => resolve()))
    }
  })
}

test('stdout and stderr limits reject excessive output', async () => {
  await assert.rejects(
    node("process.stdout.write('x'.repeat(10000))", '', 5000, { maxOutputBytes: 100 }),
    /byte limit/,
  )
  await assert.rejects(node("process.stderr.write('x'.repeat(2 * 1024 * 1024))"), /byte limit/)
})
