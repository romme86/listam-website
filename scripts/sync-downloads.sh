#!/usr/bin/env bash
# Refreshes public/downloads/ from the sibling app repos and rewrites the
# version/size/sha facts in public/downloads.html (between the
# <!-- dmg-* --> / <!-- tgz-* --> / <!-- zip-* --> markers, plus the literal
# filenames).
# The DMG is optional: it is synced only when the desktop dist has one AND
# the page carries dmg markers (Firebase's Spark plan refuses .dmg files,
# so the desktop section currently ships the `pear run` path instead).
# The Windows zip is NOT copied into public/: it is served from GitHub
# Releases. Spark allows 360 MB of egress per DAY, which a multi-megabyte
# binary would exhaust in a couple of dozen downloads and take the whole site
# down with it. This only reads the built zip to refresh the page's facts and
# rewrite the release URL, so the two cannot drift.
# Run after a build or version bump, then commit and `firebase deploy`.
set -euo pipefail
cd "$(dirname "$0")/.."

DESKTOP=../listam-desktop
HEADLESS=../listam-headless
OUT=public/downloads
PAGE=public/downloads.html

DMG_VERSION=$(node -p "require('$DESKTOP/package.json').version")
TGZ_VERSION=$(node -p "require('$HEADLESS/package.json').version")

(cd "$HEADLESS" && npm run dist >/dev/null)
SRC_TGZ="$HEADLESS/dist/listam-headless-$TGZ_VERSION.tgz"

mkdir -p "$OUT"
rm -f "$OUT"/Listam-*.dmg "$OUT"/listam-headless-*.tgz
cp "$SRC_TGZ" "$OUT/"
SUM_FILES=("listam-headless-$TGZ_VERSION.tgz")

SRC_DMG="$DESKTOP/installer/dist/Listam-$DMG_VERSION-production.dmg"
WITH_DMG=0
if grep -q 'dmg-sha' "$PAGE"; then
    if [ -f "$SRC_DMG" ]; then
        cp "$SRC_DMG" "$OUT/Listam-$DMG_VERSION.dmg"
        SUM_FILES=("Listam-$DMG_VERSION.dmg" "${SUM_FILES[@]}")
        WITH_DMG=1
    else
        echo "warn: page expects a DMG but $SRC_DMG is missing — skipped" >&2
    fi
fi

(cd "$OUT" && shasum -a 256 "${SUM_FILES[@]}" > SHA256SUMS.txt)

# Windows: facts only, files stay on GitHub Releases (see header). The setup
# exe is the primary download; the zip is the portable alternative.
SRC_ZIP="$DESKTOP/installer/dist/Listam-$DMG_VERSION-win32-x64.zip"
SRC_SETUP="$DESKTOP/installer/dist/Listam-Setup-$DMG_VERSION-win32-x64.exe"
WITH_ZIP=0
WITH_SETUP=0
missing_win() {
    echo "warn: page expects $1 but $2 is missing — skipped" >&2
    echo "      build it with installer/build-windows.ps1, or download the" >&2
    echo "      windows-appling CI artifact into that path." >&2
}
if grep -q 'zip-sha\|zip-size' "$PAGE"; then
    if [ -f "$SRC_ZIP" ]; then WITH_ZIP=1; else missing_win "a Windows zip" "$SRC_ZIP"; fi
fi
if grep -q 'setup-sha' "$PAGE"; then
    if [ -f "$SRC_SETUP" ]; then WITH_SETUP=1; else missing_win "a Windows installer" "$SRC_SETUP"; fi
fi

WITH_DMG="$WITH_DMG" DMG_VERSION="$DMG_VERSION" TGZ_VERSION="$TGZ_VERSION" \
WITH_ZIP="$WITH_ZIP" SRC_ZIP="$SRC_ZIP" \
WITH_SETUP="$WITH_SETUP" SRC_SETUP="$SRC_SETUP" node <<'EOF'
const fs = require('node:fs')

const withDmg = process.env.WITH_DMG === '1'
const dmgVersion = process.env.DMG_VERSION
const tgzVersion = process.env.TGZ_VERSION
const out = 'public/downloads'
const page = 'public/downloads.html'

const sums = Object.fromEntries(
    fs.readFileSync(`${out}/SHA256SUMS.txt`, 'utf8').trim().split('\n')
        .map((line) => line.split(/\s+/)).map(([sha, file]) => [file, sha])
)
const dmgFile = `Listam-${dmgVersion}.dmg`
const tgzFile = `listam-headless-${tgzVersion}.tgz`
const mb = (f) => `${Math.round(fs.statSync(`${out}/${f}`).size / 1048576)} MB`
const kb = (f) => `${Math.round(fs.statSync(`${out}/${f}`).size / 1024)} KB`

let html = fs.readFileSync(page, 'utf8')
const mark = (name, value) => {
    const re = new RegExp(`(<!-- ${name} -->)[\\s\\S]*?(<!-- /${name} -->)`, 'g')
    if (!re.test(html)) return false
    html = html.replace(re, `$1${value}$2`)
    return true
}
html = html.replace(/listam-headless-[0-9][0-9a-zA-Z.-]*\.tgz/g, tgzFile)
if (!mark('tgz-version', tgzVersion) | !mark('tgz-size', kb(tgzFile)) | !mark('tgz-sha', sums[tgzFile])) {
    throw new Error(`tgz markers missing in ${page}`)
}
if (withDmg) {
    html = html.replace(/Listam-[0-9][0-9a-zA-Z.-]*\.dmg/g, dmgFile)
    mark('dmg-version', dmgVersion)
    mark('dmg-size', mb(dmgFile))
    mark('dmg-sha', sums[dmgFile])
}

const sha256 = (f) => require('node:crypto')
    .createHash('sha256').update(fs.readFileSync(f)).digest('hex')
const mbOf = (f) => `${Math.round(fs.statSync(f).size / 1048576)} MB`

// Tag and filename both carry the version, so rewrite each URL as a whole
// rather than in two passes that could half-apply.
const rewriteUrl = (leaf) => {
    const url = `/releases/download/v${dmgVersion}/${leaf(dmgVersion)}`
    const pattern = leaf('[0-9][0-9a-zA-Z.-]*').replace(/\./g, '\\.')
    const re = new RegExp(`/releases/download/v[0-9][0-9a-zA-Z.-]*/${pattern}`, 'g')
    if (!re.test(html)) throw new Error(`release URL for ${leaf(dmgVersion)} not found in ${page}`)
    html = html.replace(re, url)
}

const withZip = process.env.WITH_ZIP === '1'
if (withZip) {
    const srcZip = process.env.SRC_ZIP
    rewriteUrl((v) => `Listam-${v}-win32-x64.zip`)
    if (!mark('zip-size', mbOf(srcZip))) throw new Error(`zip markers missing in ${page}`)
}

const withSetup = process.env.WITH_SETUP === '1'
if (withSetup) {
    const srcSetup = process.env.SRC_SETUP
    rewriteUrl((v) => `Listam-Setup-${v}-win32-x64.exe`)
    if (!mark('setup-size', mbOf(srcSetup)) | !mark('setup-sha', sha256(srcSetup))) {
        throw new Error(`setup markers missing in ${page}`)
    }
}

fs.writeFileSync(page, html)

const parts = [`${tgzFile} (${kb(tgzFile)})`]
parts.push(withDmg ? `${dmgFile} (${mb(dmgFile)})` : 'no DMG (pear run path)')
parts.push(withSetup ? `Listam-Setup-${dmgVersion}-win32-x64.exe` : 'no Windows installer')
parts.push(withZip ? `Listam-${dmgVersion}-win32-x64.zip` : 'no Windows zip')
console.log(`synced ${parts.join(', ')} (Windows files: facts only, hosted on GitHub Releases)`)
EOF
