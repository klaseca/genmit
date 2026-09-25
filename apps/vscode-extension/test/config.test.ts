import assert from 'node:assert/strict'
import { join } from 'node:path'
import { mkdtemp, readFile, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import test from 'node:test'
import { externalConfigPath, loadConfigSource, userConfigPath } from '../src/config.ts'

test('GENMIT_HOME selects the user config directory', () => {
  assert.equal(
    userConfigPath(
      {
        GENMIT_HOME: '/custom/genmit',
        HOME: '/home/user',
        XDG_CONFIG_HOME: '/ignored/xdg',
        APPDATA: '/ignored/appdata',
      },
      '/fallback',
    ),
    join('/custom/genmit', 'config.toml'),
  )
})

test('user config defaults to the operating system home directory', () => {
  assert.equal(
    userConfigPath({ HOME: '/ignored/home' }, '/system/home'),
    join('/system/home', '.config', 'genmit', 'config.toml'),
  )
})

test('configPath selects one file; automatic discovery is used only for an empty path', async () => {
  const root = await mkdtemp(join(tmpdir(), 'genmit-config-test-'))
  try {
    const global = join(root, 'user.toml')
    const explicit = join(root, 'selected.toml')
    await writeFile(global, 'language = "en"')
    await writeFile(explicit, 'language = "ru"')
    assert.equal(externalConfigPath(root, 'selected.toml', global), explicit)
    assert.equal(await loadConfigSource(root, '', global), 'language = "en"')
    assert.equal(await loadConfigSource(root, 'selected.toml', global), 'language = "ru"')
    assert.equal(await loadConfigSource(root, explicit, global), 'language = "ru"')
    assert.equal(await readFile(global, 'utf8'), 'language = "en"')
    assert.equal(await loadConfigSource(root, '', join(root, 'missing.toml')), undefined)
    await assert.rejects(loadConfigSource(root, 'missing.toml', global), /does not exist/)
  } finally {
    assert.ok(root.startsWith(join(tmpdir(), 'genmit-config-test-')))
    await rm(root, { recursive: true, force: true })
  }
})
