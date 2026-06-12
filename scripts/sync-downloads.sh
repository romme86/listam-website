#!/usr/bin/env bash
# Refreshes public/downloads/ from the sibling app repos and rewrites the
# version/size/sha facts in public/downloads.html (between the
# <!-- dmg-* --> / <!-- tgz-* --> markers, plus the literal filenames).
# The DMG is optional: it is synced only when the desktop dist has one AND
# the page carries dmg markers (Firebase's Spark plan refuses .dmg files,
# so the desktop section currently ships the `pear run` path instead).
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

WITH_DMG="$WITH_DMG" DMG_VERSION="$DMG_VERSION" TGZ_VERSION="$TGZ_VERSION" node <<'EOF'
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
fs.writeFileSync(page, html)

console.log(`synced ${tgzFile} (${kb(tgzFile)})${withDmg ? ` and ${dmgFile} (${mb(dmgFile)})` : ' — no DMG (pear run path)'}`)
EOF
