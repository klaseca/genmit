import assert from 'node:assert/strict'
import test from 'node:test'
import { Generations, isExpectedCancellation, repositoryForContext } from '../src/generation.ts'
const repo = (path: string) => ({ rootUri: { fsPath: path }, inputBox: { value: '' } })

test('SCM context selects its repository; commands without context require a choice', () => {
  const parent = repo('/work/repo'),
    nested = repo('/work/repo/nested'),
    other = repo('/work/other')
  const repos = [parent, nested, other]
  assert.equal(repositoryForContext(repos, other), other)
  assert.equal(repositoryForContext(repos, nested), nested)
  assert.equal(repositoryForContext(repos, undefined), undefined)
  assert.equal(repositoryForContext(repos, repo('/work/repository')), undefined)
})

test('only the latest generation may apply its result', () => {
  const generations = new Generations(),
    repository = repo('/repo')
  assert.equal(generations.hasActive(), false)
  const old = generations.start(repository),
    current = generations.start(repository)
  assert.equal(generations.hasActive(), true)
  assert.equal(old.controller.signal.aborted, true)
  assert.equal(old.canApply(), false)
  old.finish()
  assert.equal(current.canApply(), true)
  repository.inputBox.value = 'user text'
  assert.equal(current.canApply(), false)
  assert.equal(current.isCurrent(), true)
  current.finish()
  assert.equal(current.isCurrent(), false)
  assert.equal(generations.hasActive(), false)
})

test('repositories generate independently; cancellation prevents applying', () => {
  const generations = new Generations()
  const a = generations.start(repo('/a')),
    b = generations.start(repo('/b'))
  assert.equal(a.canApply(), true)
  assert.equal(b.canApply(), true)
  generations.cancelAll()
  assert.equal(a.canApply(), false)
  assert.equal(b.canApply(), false)
  assert.equal(generations.hasActive(), true)
  a.finish()
  assert.equal(generations.hasActive(), true)
  b.finish()
  assert.equal(generations.hasActive(), false)
})

test('a new generation can start while a cancelled one finishes', () => {
  const generations = new Generations()
  const repository = repo('/repo')
  const cancelled = generations.start(repository)
  generations.cancelAll()
  const current = generations.start(repository)
  cancelled.finish()
  assert.equal(current.canApply(), true)
  assert.equal(generations.hasActive(), true)
  current.finish()
  assert.equal(generations.hasActive(), false)
})

test('cancellation hides only the cancellation reason, not cleanup failures', () => {
  const controller = new AbortController()
  controller.abort()

  assert.equal(isExpectedCancellation(controller.signal.reason, controller.signal), true)
  assert.equal(
    isExpectedCancellation(new Error('failed to terminate process tree'), controller.signal),
    false,
  )
  assert.equal(
    isExpectedCancellation(controller.signal.reason, new AbortController().signal),
    false,
  )
})
