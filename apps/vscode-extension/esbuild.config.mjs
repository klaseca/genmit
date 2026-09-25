import { resolve } from 'node:path'
import { build } from 'esbuild'

await build({
  entryPoints: [resolve(import.meta.dirname, 'src', 'extension.ts')],
  bundle: true,
  minify: true,
  external: ['vscode'],
  format: 'esm',
  outfile: resolve(import.meta.dirname, 'dist', 'extension.js'),
  platform: 'node',
  target: 'node22',
})
