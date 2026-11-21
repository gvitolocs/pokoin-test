#!/usr/bin/env bash
# Upload media-manifest.json objects to R2 from the machine that holds the media objects (local object store + optional fallback host).
# Sources ~/.config/pokoin/cloudflare.env when it is readable and LANE_WORKER is unset (its values replace exported ones), then restores the set -o and shopt options; needs ~/.bun/bin/wrangler.
# Do not run in CI without intent — this pushes to pokoin-test-media.
#
# Required:
#   POKOIN_OBJECTS=path -- the directory that holds the media objects; the manifest gives every key
#     relative to it. Unset or empty, the script says so and ends 2 before it looks at anything else;
#     set but not a directory, it says that instead, in the same place.
# Optional:
#   KEYS_FILE=path   — upload only keys listed in the file (one per line), ignoring the done-list unless FORCE=1
#   FORCE=1          — re-upload even if the key is in .media-upload.done
#   POKOIN_MEDIA_FALLBACK_HOST=host -- the ssh host that holds objects the local store is missing.
#     With it set, POKOIN_MEDIA_FALLBACK_OBJECTS=path is the directory on that host the keys are
#     relative to: a host with no directory behind it ends the run 2, and with no host the directory
#     is not asked for. The tree names neither of them for a run that was not told.
# A key the file or the manifest names twice is uploaded once: the list is deduped before the keys go
# out, so what the run handed out and what it got reports about are the same set. The blanks in front
# of a key come off before that, so a key and the same key with spaces in front of it are one key.
# A key that is not one name under the object directory -- one of its components is "..", it starts
# with "/", or it carries a control character -- is refused where it stands, never looked up, and
# counted as a failed key. Two dots inside a name are part of that name and a key like any other.
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
OBJECTS="${POKOIN_OBJECTS:-}"
PI_OBJECTS="${POKOIN_MEDIA_FALLBACK_OBJECTS:-}"
PI_HOST="${POKOIN_MEDIA_FALLBACK_HOST:-}"
# the host reaches ssh and scp as one argument, so it must not start with a dash nor hold a space, a
# colon or another shell character; a host with a port on it is not one ssh can use, and nothing is
# looked up before the value is accepted
if [[ -n "$PI_HOST" && ! "$PI_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9._@-]*$ ]]; then
  echo "invalid POKOIN_MEDIA_FALLBACK_HOST" >&2
  exit 2
fi
# the remote directory belongs to the host and to nothing else: with no host set the variable is not
# asked for, and with one set the run that was not told names the variable instead of guessing the
# layout of the machine it reaches
if [[ -n "$PI_HOST" && -z "$PI_OBJECTS" ]]; then
  echo "set POKOIN_MEDIA_FALLBACK_OBJECTS to the remote directory that holds the media objects" >&2
  exit 2
fi
# the store is where the operator keeps it, and the tree holds no guess at it: the run that was not
# told does not look around for one
if [[ -z "$OBJECTS" ]]; then
  echo "set POKOIN_OBJECTS to the directory that holds the media objects" >&2
  exit 2
fi
# a name that is not there, or that holds a file, cannot give up any object: read as an empty store
# it would come back as every key of the list missing from it
if [[ ! -d "$OBJECTS" ]]; then
  echo "POKOIN_OBJECTS is not a directory" >&2
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
# directory: `ok`, `skip`, `fail` or `norecord` and the key. The parent reads that file for the
# counts and for the keys that never reported themselves.
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

# The accounting at the end compares the keys handed to xargs with the distinct keys that reported
# themselves, so a key named twice in the file, or held as two rows of the manifest, would be handed
# out twice and accounted once. The list keeps one row per key here, the first row it came in on, in
# the order of the list; an empty list stays empty.
# The blanks in front of a key come off before that, and before anything else uses the list: they are
# not part of the name, and the workers take them off on their own, so two rows that differ only by
# them are one key to the store and to the accounting.
if (( ${#KEYS[@]} > 0 )); then
  mapfile -t KEYS < <(printf '%s\n' "${KEYS[@]}" | awk '{ sub(/^[ \t]+/, ""); } !seen[$0]++')
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

# a key is one name under the object directory. One that reaches above it, that starts at the root of
# the store, or that runs over two lines is a bad record and not a missing object: it is refused here,
# before the path is built out of it and before the store, the done list or the fallback host is
# looked at, and its control characters are shown rather than written.
#
# Reaching above the store is a step of its own, and only such a step: the key is "..", one of its
# components is, or it starts with one. Two dots inside a name are part of that name -- a..b.png and
# v1..v2.webp are keys this store holds -- so the four shapes are matched one by one instead of ".."
# anywhere in the string. The middle one spells its dots as bracket classes: an unquoted ".." between
# two stars does not match a parent step, whatever it looks like it should match.
key_is_bad() {
  local key="$1"
  if [[ "$key" == /* || "$key" == *[[:cntrl:]]* || "$key" == .. || "$key" == ../* \
    || "$key" == */.. || "$key" == */[.][.]/* ]]; then
    printf 'invalid key (skipped): %s\n' "${key//[[:cntrl:]]/?}" >&2
    return 0
  fi
  return 1
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
  if key_is_bad "$key"; then
    record_result fail "$key"
    return
  fi
  if [[ "$FORCE" != "1" ]] && grep -Fxq -- "$key" "$DONE" 2>/dev/null; then
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
  # The key went up. The row in the done list is what tells a later run not to put it up again, and a
  # list that will not take it is a result of its own: the status of the append is the only thing
  # that says so. The group keeps the error of the redirection itself off stderr, since the line
  # under is the same fact in words; the record still says the key was worked.
  if ! { echo "$key" >> "$DONE"; } 2> /dev/null; then
    [[ -n "$tmp_cleanup" ]] && rm -f "$tmp_cleanup"
    echo "done list not writable: $key" >&2
    record_result norecord "$key"
    return
  fi
  [[ -n "$tmp_cleanup" ]] && rm -f "$tmp_cleanup"
  if [[ "$source_key" != "$key" ]]; then
    echo "uploaded $key (from alias $source_key)" >&2
  fi
  record_result ok "$key"
}

export ALIASES BUCKET DONE OBJECTS PI_HOST PI_OBJECTS WRANGLER FORCE
export -f resolve_file upload_one alias_for content_type_for record_result key_is_bad

echo "Uploading with $WRANGLER (parallel ${PARALLEL})…"
# the status of xargs is captured rather than left to errexit, because a child that exits 255 or dies
# of a signal makes xargs stop there: the keys it never reached are known only after this, so the
# run has to go on and print what it knows
XARGS_STATUS=0
printf '%s\n' "${KEYS[@]}" | xargs -P "$PARALLEL" -I {} bash -c 'upload_one "$@"' _ {} \
  || XARGS_STATUS=$?

# a forced key is recorded once, at the end of the done list: the children only append to it, and the
# row that stays is the last copy of each key, so what the whole list is left holding is every key
# once. Two children rewriting it through one shared temporary file used to lose rows of keys they
# were never given. The status is captured, because the list as the children left it already says
# what was uploaded: a rewrite that cannot create its temporary file or cannot move it leaves the
# duplicate rows and is reported below, rather than ending the run before the counts.
REWRITE_STATUS=0
if [[ "$FORCE" == "1" ]]; then
  tac "$DONE" | awk '!seen[$0]++' | tac > "${DONE}.tmp" \
    && mv "${DONE}.tmp" "$DONE" \
    || REWRITE_STATUS=$?
fi

# the manifest is the record of what the generator found on neither store: a row with no object and no
# source the run could look for is a key this run cannot be expected to upload, so it is counted apart.
# The alias map names a source for a key of its own -- the child tries it for a null row too, whether or
# not the row carries an aliasOf -- so a key it holds is not one this run gave up on before it looked.
# A row with an aliasOf is left out of the list as before: its source is the key the alias points at,
# and the child reports it as a skip when neither that file nor the remote has it. The three counts
# go on stderr before the HEAD sample, so that a sample fetch which does not come back cannot hide
# them. The rows are kept in one variable of this shell, not in a file: a child whose record could
# not be written may have taken the private directory of the run with it, and the counts still have
# to be printed after that. The status of the read is captured for the same reason: without it every
# skip counts as a key the store is missing, which is said apart below and costs the run its 0.
MANIFEST_ROWS_STATUS=0
NULL_ROWS="$(node -e "
const fs = require('fs');
const m = JSON.parse(fs.readFileSync('${MANIFEST}', 'utf8'));
let aliases = {};
if (fs.existsSync('${ALIASES}')) aliases = JSON.parse(fs.readFileSync('${ALIASES}', 'utf8'));
for (const e of m.entries) if (e.object === null && !e.aliasOf && !aliases[e.key]) console.log(e.key);
")" || MANIFEST_ROWS_STATUS=$?

SKIPPED=0
NO_OBJECT=0
FAILED=0
NOTRECORDED=0
ACCOUNTED=0
if [[ -f "$RESULTS" ]]; then
  ACCOUNTED="$(cut -d' ' -f2- "$RESULTS" 2>/dev/null | sort -u | grep -c '' || true)"
  while IFS= read -r result_line; do
    result_status="${result_line%% *}"
    result_key="${result_line#* }"
    case "$result_status" in
      fail) FAILED=$((FAILED + 1)) ;;
      norecord) NOTRECORDED=$((NOTRECORDED + 1)) ;;
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
if (( NOTRECORDED > 0 )); then
  if (( NOTRECORDED == 1 )); then
    echo "1 key uploaded but not recorded in the done list" >&2
  else
    echo "$NOTRECORDED keys uploaded but not recorded in the done list" >&2
  fi
fi
if (( UNACCOUNTED > 0 )); then
  if (( UNACCOUNTED == 1 )); then
    echo "unaccounted: 1 key" >&2
  else
    echo "unaccounted: $UNACCOUNTED keys" >&2
  fi
fi
# xargs ends with a code of its own when a child exits 255 or dies of a signal, and neither is a
# count of keys: the line names the status itself, so a run that accounted for every key and still
# ends 4 says what it saw
if (( XARGS_STATUS != 0 )); then
  echo "xargs status: $XARGS_STATUS" >&2
fi
if (( MANIFEST_ROWS_STATUS != 0 )); then
  echo "could not read the manifest rows" >&2
fi
if (( REWRITE_STATUS != 0 )); then
  echo "could not rewrite the done list" >&2
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
# the list gave as a path rather than a name, for a key that uploaded into a done list that would not
# take it, for a key that recorded nothing, for an xargs run that stopped before the end of the list,
# and for the two steps that read or rewrite what the counts are made of; 3 for a key the manifest
# gives a source; 5 for the HEAD sample that did not come back; and 0 when none of these applies,
# which is the status of an if that took no branch. The 1 of a preflight check ended the run before
# any of this, and so did the 2 of an unusable fallback host, of a host with no remote directory
# behind it, or of an object directory the run was not given or was given as something other than a
# directory.
if (( FAILED > 0 || NOTRECORDED > 0 || UNACCOUNTED > 0 || XARGS_STATUS != 0 \
      || MANIFEST_ROWS_STATUS != 0 || REWRITE_STATUS != 0 )); then
  exit 4
elif (( SKIPPED > 0 )); then
  exit 3
elif (( SAMPLE_STATUS != 0 )); then
  exit 5
fi
