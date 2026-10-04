// Shared SQL helpers for scripts/sql.mjs and the lab: split a file into statements
// and run them one at a time on a single connection, like psql does.

// Splits on top-level semicolons. Understands quotes, dollar quotes and comments,
// which is enough for the SQL files in this repo.
export function splitStatements(text) {
  const out = []
  let cur = ''
  let i = 0
  let dollarTag = null
  while (i < text.length) {
    const ch = text[i]
    const rest = text.slice(i)
    if (dollarTag) {
      if (rest.startsWith(dollarTag)) {
        cur += dollarTag
        i += dollarTag.length
        dollarTag = null
      } else {
        cur += ch
        i++
      }
      continue
    }
    if (rest.startsWith('--')) {
      const end = text.indexOf('\n', i)
      const stop = end === -1 ? text.length : end
      cur += text.slice(i, stop)
      i = stop
      continue
    }
    if (rest.startsWith('/*')) {
      const end = text.indexOf('*/', i + 2)
      const stop = end === -1 ? text.length : end + 2
      cur += text.slice(i, stop)
      i = stop
      continue
    }
    if (ch === "'" || ch === '"') {
      let j = i + 1
      while (j < text.length) {
        if (text[j] === ch && text[j + 1] === ch) j += 2
        else if (text[j] === ch) break
        else j++
      }
      cur += text.slice(i, j + 1)
      i = j + 1
      continue
    }
    const tag = /^\$[A-Za-z_]*\$/.exec(rest)
    if (tag) {
      dollarTag = tag[0]
      cur += dollarTag
      i += dollarTag.length
      continue
    }
    if (ch === ';') {
      if (stripComments(cur).trim()) out.push(cur.trim())
      cur = ''
      i++
      continue
    }
    cur += ch
    i++
  }
  if (stripComments(cur).trim()) out.push(cur.trim())
  return out
}

function stripComments(s) {
  return s.replace(/--[^\n]*/g, '').replace(/\/\*[\s\S]*?\*\//g, '')
}

// Runs each statement in order. Errors are reported and execution continues
// (inside an aborted transaction Postgres rejects the rest until rollback, as in psql).
export async function runStatements(sql, text, onResult) {
  let errors = 0
  for (const statement of splitStatements(text)) {
    try {
      const rows = await sql.unsafe(statement)
      onResult({ statement, rows })
    } catch (err) {
      errors++
      onResult({ statement, error: err })
    }
  }
  return errors
}

export function planText(rows) {
  return rows.map((r) => r['QUERY PLAN']).join('\n')
}
