#!/usr/bin/env node
// Generate the wiki's mechanically-derivable facts from source, so they cannot
// drift.
//
// The wiki is hand-written prose, and most of it should stay that way — a
// 2026-07-28 audit resolved all 93 <span class="source"> file references and
// found ZERO broken, so file indexes are NOT the drift problem and are not
// generated here. What HAD gone stale were the version numbers: desktop.html
// advertised v0.14.0 while listam-desktop was at 0.19.9, five minor versions on.
//
// Facts are marked in the HTML rather than pattern-matched, so this reads and
// writes exactly what it owns and never touches prose:
//
//   <span data-fact="version:listam-desktop">0.19.9</span>
//
// Usage:
//   node scripts/wiki-facts.mjs --check   # CI: fail if any marked fact is stale
//   node scripts/wiki-facts.mjs --write   # rewrite marked facts from source
//
// Adding a fact type: add a resolver to FACTS below and mark it up. Anything a
// script can derive belongs here; anything requiring judgement stays prose.
import { readFileSync, writeFileSync, readdirSync, existsSync } from 'node:fs'
import { join, dirname } from 'node:path'
import { fileURLToPath } from 'node:url'

const websiteRoot = join(fileURLToPath(import.meta.url), '..', '..')
const workspace = join(websiteRoot, '..')
const WIKI_DIR = join(websiteRoot, 'public', 'wiki')

// fact kind -> (arg) => string. Throw for an argument this repo cannot answer,
// so a typo in a marker fails loudly instead of silently writing "undefined".
const FACTS = {
    version(repo) {
        const pkgPath = join(workspace, repo, 'package.json')
        if (existsSync(pkgPath)) {
            const version = JSON.parse(readFileSync(pkgPath, 'utf8')).version
            if (version) return version
        }
        // Expo apps carry the user-facing version in app.json.
        const appJson = join(workspace, repo, 'app.json')
        if (existsSync(appJson)) {
            const version = JSON.parse(readFileSync(appJson, 'utf8'))?.expo?.version
            if (version) return version
        }
        throw new Error(`no version found for '${repo}'`)
    },
}

const MARKER = /<span data-fact="([a-z]+):([^"]+)">([^<]*)<\/span>/g

function wikiFiles() {
    return readdirSync(WIKI_DIR).filter((f) => f.endsWith('.html')).map((f) => join(WIKI_DIR, f))
}

function resolve(kind, arg) {
    const fn = FACTS[kind]
    if (!fn) throw new Error(`unknown fact kind '${kind}' (known: ${Object.keys(FACTS).join(', ')})`)
    return String(fn(arg))
}

const mode = process.argv.includes('--write') ? 'write' : 'check'
const stale = []
const errors = []
let marked = 0
let rewritten = 0

for (const file of wikiFiles()) {
    const source = readFileSync(file, 'utf8')
    let changed = false
    const next = source.replace(MARKER, (whole, kind, arg, current) => {
        marked++
        let actual
        try {
            actual = resolve(kind, arg)
        } catch (error) {
            errors.push(`${file.replace(workspace + '/', '')}: ${error.message}`)
            return whole
        }
        if (actual === current) return whole
        stale.push(`${file.replace(workspace + '/', '')}: ${kind}:${arg} says "${current}", source says "${actual}"`)
        changed = true
        return `<span data-fact="${kind}:${arg}">${actual}</span>`
    })
    if (changed && mode === 'write') {
        writeFileSync(file, next)
        rewritten++
    }
}

if (errors.length > 0) {
    console.error('wiki-facts: FAIL — markers this script cannot resolve:\n')
    for (const e of errors) console.error(`  ${e}`)
    process.exit(1)
}

if (marked === 0) {
    console.error('wiki-facts: FAIL — no data-fact markers found; this gate is checking nothing')
    process.exit(1)
}

if (mode === 'write') {
    console.log(`wiki-facts: wrote ${stale.length} fact(s) across ${rewritten} file(s); ${marked} marked total`)
    process.exit(0)
}

if (stale.length > 0) {
    console.error('wiki-facts: FAIL — the wiki states facts the source contradicts:\n')
    for (const s of stale) console.error(`  ${s}`)
    console.error('\nRun: node scripts/wiki-facts.mjs --write')
    process.exit(1)
}

console.log(`wiki-facts: OK — ${marked} generated fact(s) match source`)
