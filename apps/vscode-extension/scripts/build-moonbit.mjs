import { copyFile, mkdir } from 'node:fs/promises'
import { spawn } from 'node:child_process'
import { join, resolve } from 'node:path'

const appRoot = resolve(import.meta.dirname, '..')

const repositoryRoot = resolve(appRoot, '..', '..')

const moonbitRuntimeRoot = join(appRoot, 'moonbit-runtime')

const artifactRoot = join(repositoryRoot, '_build', 'js', 'release', 'build', 'js_runtime')

function run(command, args) {
  return new Promise((resolvePromise, reject) => {
    const child = spawn(command, args, {
      cwd: repositoryRoot,
      shell: false,
      stdio: 'inherit',
      windowsHide: true,
    })

    child.once('error', reject)
    child.once('exit', (code) => {
      if (code === 0) {
        resolvePromise()
      } else {
        reject(new Error(`${command} exited with code ${code ?? 'unknown'}`))
      }
    })
  })
}

await run('moon', ['build', 'src/js_runtime', '--target', 'js', '--release'])

await mkdir(moonbitRuntimeRoot, { recursive: true })

await copyFile(
  join(artifactRoot, 'js_runtime.js'),
  join(moonbitRuntimeRoot, 'genmit-js-runtime.js'),
)

await copyFile(
  join(artifactRoot, 'js_runtime.d.ts'),
  join(moonbitRuntimeRoot, 'genmit-js-runtime.d.ts'),
)

await copyFile(join(artifactRoot, 'moonbit.d.ts'), join(moonbitRuntimeRoot, 'moonbit.d.ts'))
