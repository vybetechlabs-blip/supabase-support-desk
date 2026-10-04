// Shared helpers for the lab scripts. Local stack only.
import { readFileSync } from 'node:fs'
import { createClient } from '@supabase/supabase-js'
import postgres from 'postgres'

export const DB_URL = process.env.DATABASE_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres'
export const DEMO_PASSWORD = 'desk-demo-pass' // local seed value, see supabase/seed.sql

function readEnv() {
  return Object.fromEntries(
    readFileSync('.env.local', 'utf8')
      .split(/\r?\n/)
      .filter((l) => l.includes('=') && !l.startsWith('#'))
      .map((l) => [l.slice(0, l.indexOf('=')), l.slice(l.indexOf('=') + 1).replace(/^"|"$/g, '')]),
  )
}

// A browser-equivalent client: publishable key, signed in as a seeded user.
export async function clientAs(email) {
  const env = readEnv()
  const client = createClient(env.VITE_SUPABASE_URL, env.VITE_SUPABASE_PUBLISHABLE_KEY, {
    auth: { persistSession: false },
  })
  const { error } = await client.auth.signInWithPassword({ email, password: DEMO_PASSWORD })
  if (error) throw new Error(`sign-in as ${email} failed: ${error.message}`)
  return client
}

// Direct database connection as the table owner (what the dashboard SQL editor uses).
export function db() {
  return postgres(DB_URL, { max: 1, onnotice: () => {} })
}

export function heading(text) {
  console.log(`\n=== ${text} ===`)
}

export function median(values) {
  const s = [...values].sort((a, b) => a - b)
  const m = Math.floor(s.length / 2)
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2
}

// "Execution Time: 12.345 ms" from a text plan.
export function executionMs(planText) {
  const m = /Execution Time: ([\d.]+) ms/.exec(planText)
  return m ? Number(m[1]) : NaN
}
