#!/usr/bin/env bash
# Refreshes public/downloads/ from the sibling app repos and rewrites the
# version/size/sha facts in public/downloads.html (between the
# <!-- dmg-* --> / <!-- tgz-* --> markers, plus the literal filenames).
# Run after a desktop DMG build or a headless version bump, then commit
# and `firebase deploy`.
set -euo pipefail
cd "$(dirname "$0")/.."

DESKTOP=../listam-desktop
HEADLESS=../listam-headless
OUT=public/downloads

DMG_VERSION=$(node -p "require('$DESKTOP/package.json').version")
TGZ_VERSION=$(node -p "require('$HEADLESS/package.json').version")

SRC_DMG="$DESKTOP/installer/dist/Listam-$DMG_VERSION-production.dmg"
if [ ! -f "$SRC_DMG" ]; then
    echo "missing $SRC_DMG — run $DESKTOP/installer/build-macos.sh first" >&2
    exit 1
fi

(cd "$HEADLESS" && npm run dist >/dev/null)
SRC_TGZ="$HEADLESS/dist/listam-headless-$TGZ_VERSION.tgz"

mkdir -p "$OUT"
rm -f "$OUT"/Listam-*.dmg "$OUT"/listam-headless-*.tgz
cp "$SRC_DMG" "$OUT/Listam-$DMG_VERSION.dmg"
cp "$SRC_TGZ" "$OUT/"
(cd "$OUT" && shasum -a 256 "Listam-$DMG_VERSION.dmg" "listam-headless-$TGZ_VERSION.tgz" > SHA256SUMS.txt)

DMG_VERSION="$DMG_VERSION" TGZ_VERSION="$TGZ_VERSION" node <<'EOF'
const fs = require('node:fs')

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
    if (!re.test(html)) throw new Error(`marker ${name} not found in ${page}`)
    html = html.replace(re, `$1${value}$2`)
}
html = html.replace(/Listam-[0-9][0-9a-zA-Z.-]*\.dmg/g, dmgFile)
html = html.replace(/listam-headless-[0-9][0-9a-zA-Z.-]*\.tgz/g, tgzFile)
mark('dmg-version', dmgVersion)
mark('dmg-size', mb(dmgFile))
mark('dmg-sha', sums[dmgFile])
mark('tgz-version', tgzVersion)
mark('tgz-size', kb(tgzFile))
mark('tgz-sha', sums[tgzFile])
fs.writeFileSync(page, html)

console.log(`synced ${dmgFile} (${mb(dmgFile)}) and ${tgzFile} (${kb(tgzFile)})`)
EOF
