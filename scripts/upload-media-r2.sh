#!/usr/bin/env bash
# Upload media-manifest.json objects to R2 from nezopt (local object store + pi-home fallback).
# Requires: ~/.bun/bin/wrangler with CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID (use `bash -ic` if needed).
# Do not run in CI without intent — this pushes to pokoin-test-media.
#
# Optional:
#   KEYS_FILE=path   — upload only keys listed in the file (one per line), ignoring the done-list unless FORCE=1
#   FORCE=1          — re-upload even if the key is in .media-upload.done
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${ROOT}/media-manifest.json"
ALIASES="${ROOT}/media-aliases.json"
DONE="${ROOT}/.media-upload.done"
BUCKET="pokoin-test-media"
PUBLIC_BASE="https://test-media.pokoin.com"
OBJECTS="${POKOIN_OBJECTS:-/home/nez/data/pokoin-leftovers/objects}"
PI_OBJECTS="/srv/pokoin/card-images/objects"
PI_HOST="pi-home"
WRANGLER="${WRANGLER:-$HOME/.bun/bin/wrangler}"
PARALLEL="${PARALLEL:-8}"
FORCE="${FORCE:-0}"

if [[ ! -f "$MANIFEST" ]]; then
  echo "Missing $MANIFEST — run: node scripts/media-manifest.mjs" >&2
  exit 1
fi

if [[ ! -x "$WRANGLER" ]]; then
  echo "Wrangler not found at $WRANGLER" >&2
  exit 1
fi

touch "$DONE"

if [[ -n "${KEYS_FILE:-}" ]]; then
  mapfile -t KEYS < <(grep -v '^[[:space:]]*$' "$KEYS_FILE" | grep -v '^#')
else
  mapfile -t KEYS < <(node -e "
const m = JSON.parse(require('fs').readFileSync('${MANIFEST}', 'utf8'));
for (const e of m.entries) console.log(e.key);
")
fi

echo "Keys to process: ${#KEYS[@]}"

alias_for() {
  node -e "
const aliases = require('${ALIASES}');
const k = process.argv[1];
process.stdout.write(aliases[k] || '');
" "$1"
}

content_type_for() {
  local key="$1"
  local ext="${key##*.}"
  ext="${ext,,}"
  case "$ext" in
    jpg|jpeg) echo "image/jpeg" ;;
    webp) echo "image/webp" ;;
    png) echo "image/png" ;;
    mp3) echo "audio/mpeg" ;;
    wav) echo "audio/wav" ;;
    mp4) echo "video/mp4" ;;
    json) echo "application/json; charset=utf-8" ;;
    txt) echo "text/plain; charset=utf-8" ;;
    *) echo "" ;;
  esac
}

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
  if [[ "$FORCE" != "1" ]] && grep -Fxq "$key" "$DONE" 2>/dev/null; then
    return 0
  fi
  local source_key="$key"
  local file tmp_cleanup=""
  if ! file="$(resolve_file "$source_key")"; then
    local alias
    alias="$(alias_for "$key")"
    if [[ -n "$alias" ]]; then
      source_key="$alias"
      if ! file="$(resolve_file "$source_key")"; then
        echo "skip (no source or alias): $key (alias $alias)" >&2
        return 0
      fi
    else
      echo "skip (no source): $key" >&2
      return 0
    fi
  fi
  if [[ "$file" == /tmp/* ]] || [[ "$file" == "${TMPDIR:-/tmp}"/* ]]; then
    tmp_cleanup="$file"
  fi
  local ct
  ct="$(content_type_for "$key")"
  local -a put_args=(r2 object put "${BUCKET}/${key}" --file "$file" --remote)
  if [[ -n "$ct" ]]; then
    put_args+=(--content-type "$ct")
  fi
  "$WRANGLER" "${put_args[@]}"
  if [[ "$FORCE" == "1" ]]; then
    grep -Fxv "$key" "$DONE" > "${DONE}.tmp" 2>/dev/null || true
    mv "${DONE}.tmp" "$DONE"
  fi
  echo "$key" >> "$DONE"
  [[ -n "$tmp_cleanup" ]] && rm -f "$tmp_cleanup"
  if [[ "$source_key" != "$key" ]]; then
    echo "uploaded $key (from alias $source_key)" >&2
  fi
}

export BUCKET DONE OBJECTS PI_HOST PI_OBJECTS WRANGLER FORCE
export -f resolve_file upload_one alias_for content_type_for

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
