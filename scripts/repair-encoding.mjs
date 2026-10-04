// REPAIRS a mixed-encoding source file and REFUSES to write unless every check below holds.
//
// WHY A BLANKET latin1 -> utf8 PASS IS WRONG HERE: the damage was a WINDOWS-1252 re-encode, and
// cp1252 maps bytes 0x80-0x9F to typographic characters (0x93 -> U+201C, 0x80 -> U+20AC, ...). So
// "INVESTIGACIÃ“N" is C3 93 where 93 became U+201C, NOT latin1. Reading it as latin1 therefore
// leaves U+201C behind, and the repair silently fails on exactly the most visible strings.
//
// The algorithm therefore maps every character BACK to the byte it came from using a cp1252 reverse
// table, groups consecutive mappable characters into a byte run, and accepts a run only when those
// bytes decode as clean UTF-8 containing at least one MULTI-byte sequence. A character that does not
// map, or a run that is already valid ASCII/latin1, is left untouched — which is what makes a
// partially-damaged file safe to repair.
//
// SAFETY CHECKS (the last one is decisive):
//   1. the file currently contains mojibake markers;
//   2. the result contains none;
//   3. the result has no U+FFFD replacement characters;
//   4. the result is a real change;
//   5. STRIPPING every non-ASCII byte yields the SAME text before and after — proving that no code,
//      identifier, string boundary, line or operator changed, only the encoding of the characters.

import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const file = process.argv[2]
const apply = process.argv.includes('--apply')
const scanMode = process.argv.includes('--scan')

// cp1252: byte -> unicode, for the 0x80-0x9F range that latin1 does not cover
const CP1252 = {
  0x80: 0x20ac, 0x82: 0x201a, 0x83: 0x0192, 0x84: 0x201e, 0x85: 0x2026, 0x86: 0x2020,
  0x87: 0x2021, 0x88: 0x02c6, 0x89: 0x2030, 0x8a: 0x0160, 0x8b: 0x2039, 0x8c: 0x0152,
  0x8e: 0x017d, 0x91: 0x2018, 0x92: 0x2019, 0x93: 0x201c, 0x94: 0x201d, 0x95: 0x2022,
  0x96: 0x2013, 0x97: 0x2014, 0x98: 0x02dc, 0x99: 0x2122, 0x9a: 0x0161, 0x9b: 0x203a,
  0x9c: 0x0153, 0x9e: 0x017e, 0x9f: 0x0178
}
const UNICODE_TO_BYTE = new Map(Object.entries(CP1252).map(([b, u]) => [u, Number(b)]))

/** The byte a character was produced from by a cp1252 re-encode, or null if it is not one. */
function byteOf(ch) {
  const c = ch.codePointAt(0)
  if (c >= 0x80 && c <= 0xff) return c // 0xA0-0xFF and the unmapped 0x81/0x8D/0x8F/0x90/0x9D
  return UNICODE_TO_BYTE.has(c) ? UNICODE_TO_BYTE.get(c) : null
}

function repair(text) {
  const chars = [...text]
  let out = ''
  let i = 0
  while (i < chars.length) {
    const b0 = byteOf(chars[i])
    if (b0 === null) { out += chars[i]; i += 1; continue }

    // collect the maximal run of mappable characters
    const bytes = []
    let j = i
    while (j < chars.length) {
      const b = byteOf(chars[j])
      if (b === null) break
      bytes.push(b)
      j += 1
    }

    const decoded = Buffer.from(bytes).toString('utf8')
    const isClean = !decoded.includes('\ufffd')
    // require at least one MULTI-byte sequence, so a run of plain latin1 accents is never touched
    const hasMultiByte = bytes.some((b, k) => (k === 0 ? b >= 0xc2 : b >= 0x80))
    if (isClean && hasMultiByte) {
      out += decoded
    } else {
      out += chars.slice(i, j).join('')
    }
    i = j
  }
  return out
}

const MARKERS = ['Ã©', 'Ã³', 'Ã¡', 'Ã­', 'Ã±', 'Ãº', 'Ã¨', 'Ã¼', 'â€”', 'â†', 'â˜', 'â–', 'âš', 'âœ', 'âž', 'âˆ', 'ðŸ', 'Ã']
const original = scanMode ? '' : fs.readFileSync(file, 'utf8')
const fixed = scanMode ? '' : repair(original)
const hits = (s) => MARKERS.reduce((n, m) => n + (s.split(m).length - 1), 0)
const asciiSkeleton = (s) => Buffer.from(s, 'utf8').toString('latin1').replace(/[\x80-\xff]/g, '')

const checks = [
  ['file currently has mojibake', hits(original) > 0, `${hits(original)} marker(s)`],
  ['result has no mojibake markers', hits(fixed) === 0, `${hits(fixed)} marker(s)`],
  ['result is valid UTF-8 (no U+FFFD)', !fixed.includes('\ufffd'), 'ok'],
  ['result is a real change', fixed !== original, 'ok'],
  ['ASCII skeleton identical (no code touched)', asciiSkeleton(fixed) === asciiSkeleton(original), 'ok']
]

let ok = true
if (!scanMode) {
  for (const [name, pass, detail] of checks) {
    if (!pass) ok = false
    console.log(`  [${pass ? 'ok  ' : 'FAIL'}] ${name} — ${detail}`)
  }
}

if (!ok) {
  const seen = new Map()
  for (let i = 0; i < fixed.length; i++) {
    for (const m of MARKERS) {
      if (fixed.startsWith(m, i)) {
        const ctx = fixed.slice(Math.max(0, i - 12), i + m.length + 12)
        if (!seen.has(ctx)) seen.set(ctx, true)
      }
    }
  }
  console.log(`remaining distinct contexts: ${seen.size}`)
  for (const ctx of [...seen].slice(0, 12)) console.log('  ', JSON.stringify(ctx))
  console.error('REFUSING to write: a check failed.')
  process.exit(1)
}

if (apply) {
  fs.writeFileSync(file, Buffer.from(fixed, 'utf8'))
  console.log(`REPAIRED ${file}`)
} else {
  console.log('dry run only (pass --apply to write)')
  for (const l of fixed.split('\n')) {
    if (l.includes('formatStorage') || l.includes('INVESTIGACI')) {
      console.log('sample:', JSON.stringify(l.slice(0, 150)))
    }
  }
}

// `--scan <dirs...>`: report every file that is currently double-encoded, and exit 0 either way so
// the caller can sweep a whole tree without the "nothing to repair" case being treated as an error.
if (process.argv.includes('--scan')) {
  const dirs = process.argv.slice(2).filter((a) => !a.startsWith('--') && a !== file)
  const exts = /\.(md|ts|tsx|css|sql|mjs|json|html)$/
  let damaged = 0
  let scanned = 0
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      if (e.name === 'node_modules' || e.name === '.git' || e.name === 'dist') continue
      const full = `${d}/${e.name}`
      if (e.isDirectory()) { walk(full); continue }
      if (!exts.test(e.name)) continue
      // this file stores the mojibake sequences as DETECTION DATA, so it always trips its own scan
      if (path.resolve(full) === path.resolve(fileURLToPath(import.meta.url))) continue
      scanned += 1
      const t = fs.readFileSync(full, 'utf8')
      const n = hits(t)
      if (n > 0) { damaged += 1; console.log(`  DAMAGED  ${full}  (${n} marker(s))`) }
    }
  }
  for (const d of (dirs.length ? dirs : ['.'])) walk(d)
  console.log(`scanned ${scanned} file(s), ${damaged} damaged`)
}
