// Unit tests for classifyTicket's failure handling, with fake clients (no network,
// no key). Run: npm run test:unit   (Node's built-in test runner; Node 22.18+ runs
// TypeScript files directly by stripping types)
import { test } from 'node:test'
import assert from 'node:assert/strict'
import { classifyTicket, SYSTEM_PROMPT, type MessagesClient } from './classify.ts'

const reply = (text: string, stop_reason = 'end_turn'): MessagesClient => ({
  messages: { create: async () => ({ stop_reason, content: [{ type: 'text', text }] }) },
})
const failing = (err: unknown): MessagesClient => ({
  messages: {
    create: async () => {
      throw err
    },
  },
})

// classifyTicket logs failures to console.error; keep test output clean.
const quiet = async <T>(fn: () => Promise<T>): Promise<T> => {
  const original = console.error
  console.error = () => {}
  try {
    return await fn()
  } finally {
    console.error = original
  }
}

test('no client (no key): stub result, fields left empty', async () => {
  assert.deepEqual(await classifyTicket(null, 's', 'b'), {
    classifier: 'stub', category: null, priority: null, note: 'ANTHROPIC_API_KEY is not set',
  })
})

test('API error (e.g. 401 invalid key): error result with the status, no throw', async () => {
  const err = Object.assign(new Error('invalid x-api-key'), { status: 401 })
  assert.deepEqual(await quiet(() => classifyTicket(failing(err), 's', 'b')), {
    classifier: 'error', category: null, priority: null, note: 'Anthropic API 401',
  })
})

test('network error (no status): error result, no throw', async () => {
  const err = Object.assign(new Error('connect ECONNREFUSED'), { code: 'ECONNREFUSED' })
  assert.deepEqual(await quiet(() => classifyTicket(failing(err), 's', 'b')), {
    classifier: 'error', category: null, priority: null, note: 'classification failed',
  })
})

test('model refusal: error result', async () => {
  assert.deepEqual(await classifyTicket(reply('', 'refusal'), 's', 'b'), {
    classifier: 'error', category: null, priority: null, note: 'model refused',
  })
})

test('unparseable model output: error result, no throw', async () => {
  const result = await quiet(() => classifyTicket(reply('not json'), 's', 'b'))
  assert.equal(result.classifier, 'error')
  assert.equal(result.category, null)
  assert.equal(result.priority, null)
})

test('values outside the allowed lists are dropped', async () => {
  assert.deepEqual(await classifyTicket(reply('{"category":"sales","priority":"high"}'), 's', 'b'), {
    classifier: 'claude-haiku-4-5', category: null, priority: 'high',
  })
})

test('success: category and priority returned', async () => {
  assert.deepEqual(await classifyTicket(reply('{"category":"billing","priority":"urgent"}'), 's', 'b'), {
    classifier: 'claude-haiku-4-5', category: 'billing', priority: 'urgent',
  })
})

test('prompt names the invented product, not a real one', () => {
  assert.match(SYSTEM_PROMPT, /\bBrannoway\b/)
  assert.doesNotMatch(SYSTEM_PROMPT, /tallybook/i)
})
