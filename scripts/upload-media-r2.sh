#!/usr/bin/env bash
# Upload media-manifest.json objects to R2 from nezopt (local object store + pi-home fallback).
# Requires: ~/.bun/bin/wrangler with CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID (use `bash -ic` if needed).
# Do not run in CI without intent — this pushes to pokoin-test-media.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${ROOT}/media-manifest.json"
DONE="${ROOT}/.media-upload.done"
BUCKET="pokoin-test-media"
PUBLIC_BASE="https://test-media.pokoin.com"
OBJECTS="${POKOIN_OBJECTS:-/home/nez/data/pokoin-leftovers/objects}"
PI_OBJECTS="/srv/pokoin/card-images/objects"
PI_HOST="pi-home"
WRANGLER="${WRANGLER:-$HOME/.bun/bin/wrangler}"
PARALLEL="${PARALLEL:-8}"

if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing $MANIFEST — run: node scripts/media-manifest.mjs" >&2
  exit 1
fi

if [[ ! -x "$WRANGLER" ]]; then
  echo "Wrangler not found at $WRANGLER" >&2
  exit 1
fi

touch "$DONE"

mapfile -t KEYS < <(node -e "
const m = JSON.parse(require('fs').readFileSync('${MANIFEST}', 'utf8'));
for (const e of m.entries) console.log(e.key);
")

echo "Keys in manifest: ${#KEYS[@]}"

resolve_file() {
  local key="$1"
  local path="${OBJECTS}/${key}"
  if [[ -f "$path" ]]; then
    printf '%s' "$path"
    return 0
  fi
  if ssh -o BatchMode=yes -o ConnectTimeout=10 "${PI_HOST}" "test -f ${PI_OBJECTS}/${key}" 2>/dev/null; then
    local tmp
    tmp="$(mktemp -p "${TMPDIR:-/tmp}" "$(basename "$key").XXXXXX")"
    scp -q "${PI_HOST}:${PI_OBJECTS}/${key}" "$tmp"
    printf '%s' "$tmp"
    return 0
  fi
  return 1
}

upload_one() {
  local key="$1"
  if grep -Fxq "$key" "$DONE" 2>/dev/null; then
    return 0
  fi
  local file tmp_cleanup=""
  if ! file="$(resolve_file "$key")"; then
    echo "skip (no source): $key" >&2
    return 0
  fi
  if [[ "$file" == /tmp/* ]] || [[ "$file" == "${TMPDIR:-/tmp}"/* ]]; then
    tmp_cleanup="$file"
  fi
  "$WRANGLER" r2 object put "${BUCKET}/${key}" --file "$file" --remote
  echo "$key" >> "$DONE"
  [[ -n "$tmp_cleanup" ]] && rm -f "$tmp_cleanup"
}

export BUCKET DONE OBJECTS PI_HOST PI_OBJECTS WRANGLER
export -f resolve_file upload_one

echo "Uploading with $WRANGLER (parallel ${PARALLEL})…"
printf '%s\n' "${KEYS[@]}" | xargs -P "$PARALLEL" -I {} bash -c 'upload_one "$@"' _ {}

SAMPLE_COUNT=5
echo "HEAD sample on ${PUBLIC_BASE}…"
node -e "
const fs = require('fs');
const keys = JSON.parse(fs.readFileSync('${MANIFEST}', 'utf8')).entries.map((e) => e.key);
const pick = keys.filter((_, i) => i % Math.max(1, Math.floor(keys.length / ${SAMPLE_COUNT})) === 0).slice(0, ${SAMPLE_COUNT});
(async () => {
  for (const key of pick) {
    const url = '${PUBLIC_BASE}/' + key;
    const res = await fetch(url, { method: 'HEAD' });
    console.log(res.status, url);
  }
})();
"

echo "Done. Uploaded keys recorded in ${DONE}"
