#!/usr/bin/env bash
# Upload media-manifest.json objects to R2 from the machine that holds the media objects (local object store + optional fallback host).
# Sources ~/.config/pokoin/cloudflare.env when it is readable and LANE_WORKER is unset (its values replace exported ones), then restores the set -o and shopt options; needs ~/.bun/bin/wrangler.
# Do not run in CI without intent — this pushes to pokoin-test-media.
#
# Optional:
#   KEYS_FILE=path   — upload only keys listed in the file (one per line), ignoring the done-list unless FORCE=1
#   FORCE=1          — re-upload even if the key is in .media-upload.done
set -euo pipefail

# --- credentials loader: begin
# Source the credentials file when it is readable and LANE_WORKER is unset; its values replace
# already exported ones. The set -o options and the bash shopt options are restored after the
# source. Not restored: umask, IFS, traps, the working directory, variables the file assigns,
# and an exit inside the file. The snapshot lives in _cf_env_snapshot, a plain variable unset again
# afterwards; a file that assigns that name changes what is restored, and one that makes it
# read-only leaves the name set.
_cf_env="${HOME:-}/.config/pokoin/cloudflare.env"
if [[ -z "${LANE_WORKER:-}" && -f "$_cf_env" && -r "$_cf_env" ]]; then
  _cf_env_snapshot=$(set +o; shopt -p)
  # the substitution does not report errexit or verbose, so both are added to the snapshot
  case $- in *e*) _cf_env_snapshot="${_cf_env_snapshot}"$'\n'"set -o errexit" ;; esac
  case $- in *v*) _cf_env_snapshot="${_cf_env_snapshot}"$'\n'"set -o verbose" ;; esac
  set +eu
  set -a
  # shellcheck disable=SC1090
  { . "$_cf_env" || true; } >/dev/null 2>&1
  { eval "$_cf_env_snapshot"; } >/dev/null 2>&1 || true
  unset _cf_env_snapshot >/dev/null 2>&1 || true
fi
# --- credentials loader: end

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
MANIFEST="${ROOT}/media-manifest.json"
ALIASES="${ROOT}/media-aliases.json"
DONE="${ROOT}/.media-upload.done"
BUCKET="pokoin-test-media"
PUBLIC_BASE="https://test-media.pokoin.com"
OBJECTS="${POKOIN_OBJECTS:-/home/nez/data/pokoin-leftovers/objects}"
PI_OBJECTS="/srv/pokoin/card-images/objects"
PI_HOST="${POKOIN_MEDIA_FALLBACK_HOST:-}"
# the host reaches ssh and scp as one argument, so it must not start with a dash nor hold a space or
# another shell character; nothing is looked up before it is accepted
if [[ -n "$PI_HOST" && ! "$PI_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._@:-]*$ ]]; then
  echo "invalid POKOIN_MEDIA_FALLBACK_HOST" >&2
  exit 2
fi
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

if [[ -z "${CLOUDFLARE_API_TOKEN:-}" || -z "${CLOUDFLARE_ACCOUNT_ID:-}" ]]; then
  if [[ -n "${LANE_WORKER:-}" ]]; then
    _cf_where="credentials file not read because LANE_WORKER is set"
  else
    _cf_where="looked in ${_cf_env}"
  fi
  echo "CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID must be set (${_cf_where})" >&2
  exit 1
fi

touch "$DONE"

# the keys the run worked through are found by the xargs children, which share no variable with this
# shell, so each of them appends one line per key to one record file in a private temporary
# directory: `ok`, `skip` or `fail` and the key. The parent reads that file for the counts and for
# the keys that never reported themselves.
WORK="$(mktemp -d -p "${TMPDIR:-/tmp}" "upload-media-r2.XXXXXX")"
trap 'rm -rf -- "${WORK}"' EXIT
RESULTS="${WORK}/results"
: > "$RESULTS"
export RESULTS

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
  if [[ -n "$PI_HOST" ]] && ssh -o BatchMode=yes -o ConnectTimeout=10 -- "${PI_HOST}" "test -f ${PI_OBJECTS}/${key}" 2>/dev/null; then
    local tmp
    tmp="$(mktemp -p "${TMPDIR:-/tmp}" "$(basename "$key").XXXXXX")"
    scp -q -- "${PI_HOST}:${PI_OBJECTS}/${key}" "$tmp"
    printf '%s' "$tmp"
    return 0
  fi
  return 1
}

# the one line a child writes for the key it was handed. The write is tested and a child that cannot
# do it ends nonzero itself, because the record is how the parent learns the key was worked at all
record_result() {
  local status="$1" key="$2"
  if ! printf '%s %s\n' "$status" "$key" >> "$RESULTS"; then
    echo "cannot record result for: $key" >&2
    return 1
  fi
  return 0
}

upload_one() {
  local key="$1"
  if [[ "$FORCE" != "1" ]] && grep -Fxq "$key" "$DONE" 2>/dev/null; then
    record_result ok "$key"
    return
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
        record_result skip "$key"
        return
      fi
    else
      echo "skip (no source): $key" >&2
      record_result skip "$key"
      return
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
  # this runs in the xargs child, where errexit is never on, so the exit status of the call is the
  # only thing that says whether the object went up: a failed put is recorded apart and the key is
  # not added to the done list, which a rerun then retries
  local put_status=0
  "$WRANGLER" "${put_args[@]}" || put_status=$?
  if [[ "$put_status" -ne 0 ]]; then
    echo "upload failed: $key" >&2
    if [[ -n "$tmp_cleanup" ]]; then rm -f "$tmp_cleanup"; fi
    record_result fail "$key"
    return
  fi
  if [[ "$FORCE" == "1" ]]; then
    grep -Fxv "$key" "$DONE" > "${DONE}.tmp" 2>/dev/null || true
    mv "${DONE}.tmp" "$DONE"
  fi
  echo "$key" >> "$DONE"
  [[ -n "$tmp_cleanup" ]] && rm -f "$tmp_cleanup"
  if [[ "$source_key" != "$key" ]]; then
    echo "uploaded $key (from alias $source_key)" >&2
  fi
  record_result ok "$key"
}

export ALIASES BUCKET DONE OBJECTS PI_HOST PI_OBJECTS WRANGLER FORCE
export -f resolve_file upload_one alias_for content_type_for record_result

echo "Uploading with $WRANGLER (parallel ${PARALLEL})…"
# the status of xargs is captured rather than left to errexit, because a child that exits 255 or dies
# of a signal makes xargs stop there: the keys it never reached are known only after this, so the
# run has to go on and print what it knows
XARGS_STATUS=0
printf '%s\n' "${KEYS[@]}" | xargs -P "$PARALLEL" -I {} bash -c 'upload_one "$@"' _ {} \
  || XARGS_STATUS=$?

# the manifest is the record of what the generator found on neither store: a row with no object and
# no alias is a key this run cannot be expected to upload, so it is counted apart. The three counts
# go on stderr before the HEAD sample, so that a sample fetch which does not come back cannot hide
# them. The rows are kept in one variable of this shell, not in a file: a child whose record could
# not be written may have taken the private directory of the run with it, and the counts still have
# to be printed after that.
NULL_ROWS="$(node -e "
const m = JSON.parse(require('fs').readFileSync('${MANIFEST}', 'utf8'));
for (const e of m.entries) if (e.object === null && !e.aliasOf) console.log(e.key);
")"

SKIPPED=0
NO_OBJECT=0
FAILED=0
ACCOUNTED=0
if [[ -f "$RESULTS" ]]; then
  ACCOUNTED="$(cut -d' ' -f2- "$RESULTS" 2>/dev/null | sort -u | grep -c '' || true)"
  while IFS= read -r result_line; do
    result_status="${result_line%% *}"
    result_key="${result_line#* }"
    case "$result_status" in
      fail) FAILED=$((FAILED + 1)) ;;
      skip)
        if grep -Fxq -- "$result_key" <<<"$NULL_ROWS"; then
          NO_OBJECT=$((NO_OBJECT + 1))
        else
          SKIPPED=$((SKIPPED + 1))
        fi ;;
    esac
  done < "$RESULTS"
fi
# handed is what the run gave to xargs, accounted the distinct keys that recorded themselves. What is
# left was never worked, or was worked by a child that could not say what it found.
HANDED="${#KEYS[@]}"
UNACCOUNTED=$(( HANDED - ACCOUNTED ))
if (( NO_OBJECT > 0 )); then
  if (( NO_OBJECT == 1 )); then
    echo "1 key has no object in the manifest" >&2
  else
    echo "$NO_OBJECT keys have no object in the manifest" >&2
  fi
fi
if (( SKIPPED > 0 )); then
  if (( SKIPPED == 1 )); then
    echo "1 key skipped: no source" >&2
  else
    echo "$SKIPPED keys skipped: no source" >&2
  fi
fi
if (( FAILED > 0 )); then
  if (( FAILED == 1 )); then
    echo "1 key failed to upload" >&2
  else
    echo "$FAILED keys failed to upload" >&2
  fi
fi
if (( UNACCOUNTED > 0 )); then
  if (( UNACCOUNTED == 1 )); then
    echo "unaccounted: 1 key" >&2
  else
    echo "unaccounted: $UNACCOUNTED keys" >&2
  fi
fi

SAMPLE_COUNT=5
echo "HEAD sample on ${PUBLIC_BASE}…"
# the status of the sample is kept for the exit code instead of ending the run here, because it
# counts for less than what the records above say
SAMPLE_STATUS=0
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
" || SAMPLE_STATUS=$?

echo "Done. Uploaded keys recorded in ${DONE}"

# the exit code of a run, in the order of what it means: 4 for a key whose upload failed, for a key
# that recorded nothing, and for an xargs run that stopped before the end of the list; 3 for a key
# the manifest gives a source; the sample's own status when the fetch did not come back; and 0 when
# none of these applies, which is the status of an if that took no branch
if (( FAILED > 0 || UNACCOUNTED > 0 || XARGS_STATUS != 0 )); then
  exit 4
elif (( SKIPPED > 0 )); then
  exit 3
elif (( SAMPLE_STATUS != 0 )); then
  exit "$SAMPLE_STATUS"
fi
