import assert from 'node:assert/strict'
import test from 'node:test'
import { GenerationProgress } from '../src/progress.ts'

test('finishing one run preserves another and ignores late events and repeated cleanup', () => {
  let visible = false
  let logEntries = 0
  const record = () => logEntries++
  const progress = new GenerationProgress(
    {
      text: '',
      tooltip: undefined,
      show: () => {
        visible = true
      },
      hide: () => {
        visible = false
      },
    },
    { info: record, warn: record, error: record },
  )

  try {
    const old = progress.start('/repo')
    const current = progress.start('/repo')
    old.finish('cancelled')
    assert.equal(visible, true)

    const count = logEntries
    old.onEvent({ type: 'completed', duration_ms: 0, message: '' })
    old.finish('applied')
    assert.equal(logEntries, count)

    current.finish('applied')
    assert.equal(visible, false)
  } finally {
    progress.dispose()
  }
})

test('logging failures do not leave an active progress display', () => {
  for (const failOnStart of [true, false]) {
    let visible = false
    let fail = failOnStart
    const failure = new Error('output failed')
    const record = () => {
      if (fail) throw failure
    }
    const progress = new GenerationProgress(
      {
        text: '',
        tooltip: undefined,
        show: () => {
          visible = true
        },
        hide: () => {
          visible = false
        },
      },
      { info: record, warn: record, error: record },
    )
    try {
      if (failOnStart) {
        assert.throws(
          () => progress.start('/repo'),
          (error) => error === failure,
        )
      } else {
        const display = progress.start('/repo')
        fail = true
        assert.throws(
          () => display.finish('failed'),
          (error) => error === failure,
        )
        display.finish('failed')
      }
      assert.equal(visible, false)
      fail = false
      const next = progress.start('/repo')
      next.finish('applied')
      assert.equal(visible, false)
    } finally {
      progress.dispose()
    }
  }
})
