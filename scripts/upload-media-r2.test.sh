#!/usr/bin/env bash
# Tests for scripts/upload-media-r2.sh: credential loading and preflight, the object directory it
# has to be told about, the fallback host, the key that names a path instead of a file of the store,
# the keys skipped for want of a source, the upload whose wrangler call fails, the keys a run failed
# to account for, the key that is listed twice or twice with blanks in front of it and the one it
# cannot record in the done list; and scripts/no-host-names.test.sh and
# scripts/media-manifest-guard.test.sh as two of its own steps.
# Runs a copy of the script under env -i with stub wrangler/node/ssh/scp and a temp HOME.
# Usage: bash scripts/upload-media-r2.test.sh [path-to-script-under-test]
set -euo pipefail

SRC="${1:-$(cd "$(dirname "$0")" && pwd)/upload-media-r2.sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
DUMMY_TOKEN="dummy-token-for-test"
DUMMY_ACCOUNT="dummy-account-for-test"

TMP="$(mktemp -d "${TMPDIR:-/var/tmp}/upload-media-r2-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

mkdir -p "$TMP/scratch" "$TMP/root/scripts" "$TMP/stubs" "$TMP/objects"
cp "$SRC" "$TMP/root/scripts/upload-media-r2.sh"
printf "{\"entries\":[{\"key\":\"a.png\"}]}\n" > "$TMP/root/media-manifest.json"
printf "{}\n" > "$TMP/root/media-aliases.json"
printf "x" > "$TMP/objects/a.png"
printf "a.png\n" > "$TMP/keys.txt"

CALLS="$TMP/wrangler.calls"
cat > "$TMP/stubs/wrangler" <<STUB
#!/bin/sh
if [ -n "\${CLOUDFLARE_API_TOKEN:-}" ]; then s=token-set; else s=token-unset; fi
if [ "\${CLOUDFLARE_API_TOKEN:-}" = "dummy-token-for-test" ]; then v=value-from-file; else v=value-other; fi
m=\$(env | grep -c "^MANIFEST=" || true)
echo "\$s \$v manifest-exported=\$m \$*" >> "$CALLS"
# wrangler runs in the xargs child where errexit is never on, so only a failing node stub shows it
exit 0
STUB
printf "#!/bin/sh\n[ \"\${NODE_FAIL:-}\" = 1 ] && exit 1\nexit 0\n" > "$TMP/stubs/node"
for n in ssh scp; do
  printf "#!/bin/sh\necho \"%s called\" >> \"%s/forbidden.calls\"\nexit 1\n" "$n" "$TMP" > "$TMP/stubs/$n"
done
chmod +x "$TMP/stubs/"*

fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

# The suite reads the committed media-manifest.json and must never rewrite it: the generator is not
# run here. The guard runs on the way out of the normal path, and on every other way out as well.
guard_done=0
guard_manifest() {
  local root
  guard_done=1
  root="$(cd "$HERE/.." && pwd)"
  if ! git -C "$root" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "ok: skipped: the manifest guard compares against HEAD and this is no git work tree"
    return 0
  fi
  if git -C "$root" diff --quiet HEAD -- media-manifest.json; then
    echo "ok: media-manifest.json is unchanged against HEAD"
    return 0
  fi
  bad "the run changed media-manifest.json"
  return 1
}
on_exit() {
  local rc=$?
  # three cases make the directory of the done list unwritable to get a permission failure; if a run
  # died between that and the restore the cleanup below could not empty it
  chmod -R u+rwX "$TMP/root" 2> /dev/null || true
  rm -rf "$TMP"
  if [[ "$guard_done" -eq 0 ]] && ! guard_manifest; then rc=1; fi
  exit "$rc"
}
trap on_exit EXIT

# the script under test is executable, so ./scripts/upload-media-r2.sh runs after a clone
if [[ -x "$SRC" ]]; then
  ok "o: the script under test is executable"
else
  bad "o: the script under test is not executable: $SRC"
fi

# run_case <name> <HOME dir> [extra env assignments...]; sets STATUS, ERR
run_case() {
  shift; local home="$1"; shift
  rm -f "$CALLS" "$TMP/root/.media-upload.done"
  printf x > "$TMP/objects/a.png"
  set +e
  env -i PATH="$TMP/stubs:/usr/bin:/bin" HOME="$home" TMPDIR="$TMP/scratch" \
    WRANGLER="$TMP/stubs/wrangler" POKOIN_OBJECTS="$TMP/objects" KEYS_FILE="$TMP/keys.txt" \
    "$@" bash "$TMP/root/scripts/upload-media-r2.sh" >"$TMP/out" 2>"$TMP/err"
  STATUS=$?
  set -e
  ERR="$(cat "$TMP/err")"
}

mk_home() { mkdir -p "$TMP/$1/.config/pokoin"; echo "$TMP/$1"; }

# expect_preflight <name> <detail in parentheses>: exact stderr line, exit 1, wrangler not called
expect_preflight() {
  local name="$1" want="CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID must be set ($2)"
  if [[ "$STATUS" -eq 1 ]] && [[ "$ERR" == "$want" ]] && [[ ! -e "$CALLS" ]]; then
    ok "$name: only the preflight line on stderr, exit 1, wrangler not called"
  else
    bad "$name: status=$STATUS err=[$ERR] calls=$(cat "$CALLS" 2>/dev/null || true)"
  fi
}

# write_creds <home> [lines placed before the two dummy assignments...]
write_creds() {
  local home="$1"; shift
  {
    for l in "$@"; do printf "%s\n" "$l"; done
    printf "CLOUDFLARE_API_TOKEN=%s\nCLOUDFLARE_ACCOUNT_ID=%s\n" "$DUMMY_TOKEN" "$DUMMY_ACCOUNT"
  } > "$home/.config/pokoin/cloudflare.env"
}

# a. credentials file present
H="$(mk_home home-a)"
printf "CLOUDFLARE_API_TOKEN=%s\nCLOUDFLARE_ACCOUNT_ID=%s\n" "$DUMMY_TOKEN" "$DUMMY_ACCOUNT" > "$H/.config/pokoin/cloudflare.env"
run_case a "$H"
if [[ "$STATUS" -eq 0 ]] && [[ -e "$CALLS" ]] && grep -q "^token-set " "$CALLS"; then
  ok "a: credentials file loaded, wrangler saw token-set"
else
  bad "a: status=$STATUS err=[$ERR] calls=$(cat "$CALLS" 2>/dev/null || echo none)"
fi
# e. no dummy value in the output of case a
if grep -qF -e "$DUMMY_TOKEN" -e "$DUMMY_ACCOUNT" "$TMP/out" "$TMP/err"; then
  bad "e: a credential value appeared in the output"
else
  ok "e: output contains no credential value"
fi

# b. credentials file absent
H="$(mk_home home-b)"
run_case b "$H"
expect_preflight b "looked in $H/.config/pokoin/cloudflare.env"

# c. credentials file with a syntax error and no valid assignments
H="$(mk_home home-c)"
printf "if then fi ((( \"unterminated\n" > "$H/.config/pokoin/cloudflare.env"
run_case c "$H"
expect_preflight c "looked in $H/.config/pokoin/cloudflare.env"

# d. LANE_WORKER set: file is not loaded
H="$(mk_home home-d)"
printf "CLOUDFLARE_API_TOKEN=%s\nCLOUDFLARE_ACCOUNT_ID=%s\n" "$DUMMY_TOKEN" "$DUMMY_ACCOUNT" > "$H/.config/pokoin/cloudflare.env"
run_case d "$H" LANE_WORKER=1
expect_preflight d "credentials file not read because LANE_WORKER is set"

# f. credentials file that refers to an unset variable before the assignments
H="$(mk_home home-f)"
{
  echo "echo \"\$A_VARIABLE_THAT_IS_NOT_SET\" >/dev/null"
  printf "CLOUDFLARE_API_TOKEN=%s\nCLOUDFLARE_ACCOUNT_ID=%s\n" "$DUMMY_TOKEN" "$DUMMY_ACCOUNT"
} > "$H/.config/pokoin/cloudflare.env"
run_case f "$H"
if [[ "$STATUS" -eq 0 ]] && [[ -e "$CALLS" ]] && grep -q "^token-set " "$CALLS" \
  && [[ "$ERR" != *"unbound variable"* ]]; then
  ok "f: unset variable inside the file tolerated, wrangler saw token-set"
else
  bad "f: status=$STATUS err=[$ERR] calls=$(cat "$CALLS" 2>/dev/null || echo none)"
fi

# g. the credentials file prints to stdout and stderr: the script prints nothing of it
H="$(mk_home home-g)"
write_creds "$H" "echo noise-out" "echo noise-err >&2"
run_case g "$H"
if [[ "$STATUS" -eq 0 ]] && grep -q "^token-set " "$CALLS" \
  && ! grep -q "noise" "$TMP/out" "$TMP/err" && [[ -z "$ERR" ]]; then
  ok "g: output of the credentials file is not printed"
else
  bad "g: status=$STATUS err=[$ERR]"
fi

# h. the credentials file runs set -x: no trace and no credential value on stderr afterwards
H="$(mk_home home-h)"
write_creds "$H" "set -x"
run_case h "$H"
if [[ "$STATUS" -eq 0 ]] && grep -q "^token-set " "$CALLS" \
  && ! grep -qF -e "$DUMMY_TOKEN" -e "$DUMMY_ACCOUNT" "$TMP/out" "$TMP/err" \
  && ! grep -q "^+" "$TMP/err"; then
  ok "h: xtrace from the credentials file is not left on"
else
  bad "h: status=$STATUS err=[$ERR]"
fi

# i. the credentials file runs set +e: errexit stays on. No node call can show that any more, because
#    every one of them has a captured status since the accounting, so the step that makes sure the
#    done list exists is the one that ends the run: the directory of the list will not take a new
#    file, and the run stops there, before the upload and before the final line.
H="$(mk_home home-i)"
write_creds "$H" "set +e"
rm -f "$TMP/root/.media-upload.done"
chmod 555 "$TMP/root"
run_case i "$H"
chmod 755 "$TMP/root"
if [[ "$STATUS" -eq 1 ]] && [[ "$ERR" == *"Permission denied"* ]] && [[ ! -e "$CALLS" ]] \
  && [[ "$ERR" != *"must be set"* ]] && ! grep -q "^Done" "$TMP/out"; then
  ok "i: errexit still on after the credentials file ran set +e"
else
  bad "i: status=$STATUS err=[$ERR] out=[$(cat "$TMP/out")]"
fi

# i2. a run whose node cannot read the manifest rows reports it instead of dying there: the counts,
#     the Done line and exit 4, with the line that names the step that failed.
run_case i2 "$H" NODE_FAIL=1
if [[ "$STATUS" -eq 4 ]] && [[ "$ERR" == *"could not read the manifest rows"* ]] \
  && grep -q "^Done" "$TMP/out"; then
  ok "i2: a failing manifest-row read is reported and ends 4, it does not stop the run"
else
  bad "i2: status=$STATUS err=[$ERR] out=[$(cat "$TMP/out")]"
fi

# l. allexport is off again after the loader: a variable the script defines is not exported
H="$(mk_home home-l)"
write_creds "$H"
run_case l "$H"
if [[ "$STATUS" -eq 0 ]] && grep -q " manifest-exported=0 " "$CALLS"; then
  ok "l: allexport off after the loader"
else
  bad "l: status=$STATUS calls=$(cat "$CALLS" 2>/dev/null || echo none)"
fi

# h2. the credentials file sets PS4 and runs set -x: no trace line and no value on stderr
H="$(mk_home home-h2)"
write_creds "$H" "PS4=\">>\"" "set -x"
run_case h2 "$H"
if [[ "$STATUS" -eq 0 ]] && grep -q "^token-set " "$CALLS" \
  && ! grep -qF -e "$DUMMY_TOKEN" -e "$DUMMY_ACCOUNT" "$TMP/out" "$TMP/err" \
  && ! grep -qF ">>" "$TMP/err"; then
  ok "h2: xtrace with a custom PS4 is not left on"
else
  bad "h2: status=$STATUS err=[$ERR]"
fi

# j. variables exported by the caller are replaced by the values in the file
H="$(mk_home home-j)"
write_creds "$H"
run_case j "$H" CLOUDFLARE_API_TOKEN=caller-token-dummy CLOUDFLARE_ACCOUNT_ID=caller-account-dummy
if [[ "$STATUS" -eq 0 ]] && grep -q "^token-set value-from-file " "$CALLS"; then
  ok "j: values from the credentials file replace exported ones"
else
  bad "j: status=$STATUS calls=$(cat "$CALLS" 2>/dev/null || echo none)"
fi

# m. the loader block restores every set -o and shopt option. The block is extracted from the script
#    and run in a harness (options are not inherited by child processes, so the end-to-end cases
#    cannot see them). The harness compares the options and $- before and after and prints nothing.
sed -n '/loader: begin/,/loader: end/p' "$SRC" > "$TMP/loader-block.sh"
# a moved or deleted marker, or a block without its restore line, stops the run: no cell below may report ok
if [[ ! -s "$TMP/loader-block.sh" ]] || ! grep -q 'eval "\$' "$TMP/loader-block.sh"; then
  echo "FAIL: m: the loader block between the markers is empty or has no restore line"
  echo "FAILED"
  exit 1
fi
# The harness exits 11 when the options differ, 12 when the file was not really sourced (the dummy token is checked
# after tracing is turned off, so no trace line carries the value), 13 when the snapshot variable is left.
# shellcheck disable=SC2016
HARNESS='eval "$2"
before="$(set +o; shopt -p) $-"
. "$1"
after="$(set +o; shopt -p) $-"
[ "$before" = "$after" ] || exit 11
{ set +x +v; } 2>/dev/null
[ "${CLOUDFLARE_API_TOKEN:-}" = "$DUMMY_TOKEN" ] || exit 12
[ -z "${_cf_env_snapshot+x}" ] || exit 13'
H="$(mk_home home-m)"
m_starts=("" "set -e" "set -eu" "set -euo pipefail" "shopt -s extglob" "set -a" "set -f; shopt -s nullglob" "set -x" "set -v")
m_files=("set +e" "set -x" "set -v" "shopt -s nullglob extglob" "set -o pipefail" "set +o pipefail" "set +u" "set -f" "set -euo pipefail" "shopt -u extglob" "TAIL-FAILS")
for start in "${m_starts[@]}"; do
  for line in "${m_files[@]}"; do
    if [[ "$line" == "TAIL-FAILS" ]]; then
      # tracing with a PS4 that runs a command, and the file's last command fails
      write_creds "$H" "PS4='\$(echo SECRET-FROM-PS4)+ '" "set -x"
      printf 'false\n' >> "$H/.config/pokoin/cloudflare.env"
    else
      write_creds "$H" "$line"
    fi
    set +e
    mout="$(env -i PATH="/usr/bin:/bin" HOME="$H" DUMMY_TOKEN="$DUMMY_TOKEN" bash -c "$HARNESS" _ "$TMP/loader-block.sh" "$start" 2>&1)"
    mrc=$?
    set -e
    # a caller that starts with tracing or verbose has bash print its own lines, so for those starts the output must
    # only be free of credential values (a PS4 the file sets also applies to the caller's own trace lines); for every
    # other start it must be empty
    if [[ "$start" == "set -x" || "$start" == "set -v" ]]; then
      mclean=1
      if [[ "$mout" == *"$DUMMY_TOKEN"* || "$mout" == *"$DUMMY_ACCOUNT"* ]]; then mclean=0; fi
    else
      mclean=0
      if [[ -z "$mout" ]]; then mclean=1; fi
    fi
    if [[ "$mrc" -eq 0 && "$mclean" -eq 1 ]]; then
      ok "m: restored after [$line] from start [$start]"
    else
      bad "m: not restored after [$line] from start [$start] rc=$mrc (11 options, 12 not sourced, 13 variable left) out=[${mout:0:200}]"
    fi
  done
done

# n. umask and the working directory are not restored (documented limits)
H="$(mk_home home-n)"
write_creds "$H" "umask 077" "cd /"
# shellcheck disable=SC2016
nout="$(env -i PATH="/usr/bin:/bin" HOME="$H" bash -c 'umask 022; cd "$2"; . "$1"; echo "$(umask) $PWD"' _ "$TMP/loader-block.sh" "$TMP")"
if [[ "$nout" == "0077 /" ]]; then
  ok "n: umask and working directory set by the file are not restored"
else
  bad "n: out=[$nout]"
fi

# ---------------------------------------------------------------------------
# s1..s12: the fallback host, the keys with no source and what the manifest says about them. These
# cases need ssh and scp to answer, so they run with a second stub directory that records every call
# instead of the forbidden one above. Every run of the group is given the dummy remote directory as
# well, which a run with no host set ignores.
# ---------------------------------------------------------------------------
S2="$TMP/stubs-fallback"
mkdir -p "$S2" "$TMP/objects2" "$TMP/home-fb"
SSH_LOG="$TMP/ssh.args"
SCP_LOG="$TMP/scp.args"
CALLS2="$TMP/wrangler2.calls"
FB_KEYS="$TMP/keys2.txt"
FB_HOST="fallback.example.invalid"   # a dummy, and not a name that resolves
# the remote directory the runs below hand to POKOIN_MEDIA_FALLBACK_OBJECTS: a dummy, and the layout
# path of no machine, which is the point of the variable
REMOTE_OBJECTS="/remote/objects"
want_fallback_objects_line="set POKOIN_MEDIA_FALLBACK_OBJECTS to the remote directory that holds the media objects"
FB_ALIASES_DEFAULT='{}'

# the fixture manifest and aliases are read by the script with a real node, so a row that says
# "object": null is honoured; only the HEAD sample program is refused, because it would fetch
cat > "$S2/ssh" <<'STUB'
#!/bin/sh
# one block per call, one argument per line, so a command line can be compared exactly
log="$SSH_LOG"
[ "$(basename "$0")" = scp ] && log="$SCP_LOG"
printf -- '---\n' >> "$log"
for a in "$@"; do printf '%s\n' "$a" >> "$log"; done
# SSH_MISS=<text>: the host says no to a path holding this text, so a case can have the keys it names
# fall through to the alias map and still count what the run asked the host about.
if [ -n "${SSH_MISS:-}" ]; then
  case "$*" in
    *"$SSH_MISS"*) exit 1 ;;
  esac
fi
exit 0
STUB
cp "$S2/ssh" "$S2/scp"
# shellcheck disable=SC2016
cat > "$S2/node" <<'STUB'
#!/bin/sh
if [ "$1" = "-e" ]; then
  case "$2" in
    *"method: 'HEAD'"*)
      # SAMPLE_FAIL=1 is the case of a sample fetch that does not come back
      if [ -n "${SAMPLE_FAIL:-}" ]; then exit 1; fi
      exit 0 ;;
    *"object === null"*)
      # NULL_ROWS_FAIL=1 is the case of the run that cannot read the manifest rows it needs for the
      # count of the keys the generator found on neither store. Only that program matches here, so
      # the key list and the alias lookups still run on the real node.
      if [ -n "${NULL_ROWS_FAIL:-}" ]; then exit 1; fi ;;
  esac
fi
exec "$REAL_NODE" "$@"
STUB
# The put of a key named in the FAIL_KEYS file fails, so a run can be shown what a failed wrangler
# call does; the file is absent or empty when every upload is meant to succeed. The fourth argument
# of a put is the target, bucket/key.
#
# Two more ways of breaking the xargs child, so a run can be shown what a child that never reports
# its key does:
#   UNRECORDABLE_KEY=<key>  the put of that key first removes the private directory the script put
#                           its per-key record files in (only when that directory is under TMPDIR),
#                           then fails: a child that wants to record the key finds nowhere to write.
#   KILLED_KEY=<key>        the put of that key kills the shell that ran it -- the parent of this
#                           stub, and only when that parent is bash -- so the child dies by signal.
cat > "$S2/wrangler" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS2"
put_key=''
if [ "$1" = r2 ] && [ "$2" = object ] && [ "$3" = put ]; then
  put_key="${4#pokoin-test-media/}"
fi
if [ -n "$put_key" ] && [ -n "${UNRECORDABLE_KEY:-}" ] && [ "$put_key" = "$UNRECORDABLE_KEY" ]; then
  # the three names a version of the script may keep its records under: RESULTS is the one file the
  # present script uses, the two lists are what the script before the accounting used, and the ones
  # that are unset are skipped
  for p in "${RESULTS:-}" "${FAIL_LIST:-}" "${SKIP_LIST:-}"; do
    [ -n "$p" ] || continue
    d=${p%/*}
    case $d in
      "$TMPDIR"/*) rm -rf -- "$d" ;;
    esac
  done
  echo "stub wrangler: the record directory of the run is gone" >&2
  exit 1
fi
if [ -n "$put_key" ] && [ -n "${KILLED_KEY:-}" ] && [ "$put_key" = "$KILLED_KEY" ]; then
  if [ "$(cat "/proc/$PPID/comm" 2>/dev/null)" = bash ]; then
    kill -9 "$PPID"
  fi
  exit 0
fi
if [ -n "${FAIL_KEYS:-}" ] && [ -f "${FAIL_KEYS:-}" ] \
  && [ -n "$put_key" ] && grep -Fxq -- "$put_key" "$FAIL_KEYS"; then
  echo "stub wrangler: the put of $4 failed" >&2
  exit 1
fi
exit 0
STUB
# BASH_ENV is read by every shell bash starts with -c, which is what the xargs children are, so this
# file makes the child of one key exit 255 before it runs any of the upload code. xargs stops at the
# first child that exits 255, so the keys after it are never worked at all.
cat > "$S2/die255.bashenv" <<'BASHENV'
if [ -n "${DIE255_KEY:-}" ] && [ "${1:-}" = "$DIE255_KEY" ]; then
  exit 255
fi
:
BASHENV
chmod +x "$S2"/*

# REAL_NODE is the node the stubs hand everything but the fetch to; the manifest fixtures need it
REAL_NODE="$(command -v node || true)"

# fb_keys <key>... / fb_store <key>...: the key list and the object store of the next run
fb_keys() {
  : > "$FB_KEYS"
  local k
  for k in "$@"; do printf '%s\n' "$k" >> "$FB_KEYS"; done
}
fb_store() {
  rm -rf -- "$TMP/objects2"
  mkdir -p -- "$TMP/objects2"
  local k
  for k in "$@"; do
    mkdir -p -- "$TMP/objects2/$(dirname -- "$k")"
    printf x > "$TMP/objects2/$k"
  done
}

# fb_manifest <key> <object or -> <aliasOf or -> ...: the rows of the fixture manifest, three
# arguments per key. A dash in the object column records "object": null, as the generator does for a
# key it found on neither store.
fb_manifest() {
  local file="$TMP/root/media-manifest.json" k obj alias_of sep=''
  printf '{"entries":[' > "$file"
  while [[ $# -gt 0 ]]; do
    k="$1"; obj="$2"; alias_of="$3"; shift 3
    printf '%s' "$sep" >> "$file"
    sep=','
    printf '{"key":"%s"' "$k" >> "$file"
    if [[ "$obj" == "-" ]]; then
      printf ',"object":null' >> "$file"
    else
      printf ',"object":"%s"' "$obj" >> "$file"
    fi
    if [[ "$alias_of" != "-" ]]; then
      printf ',"aliasOf":"%s"' "$alias_of" >> "$file"
    fi
    printf '}' >> "$file"
  done
  printf ']}\n' >> "$file"
}

# line_for <n> <singular> <plural>: the summary line of the script for n keys
line_for() {
  if [[ "$1" == "1" ]]; then printf '%s %s\n' "$1" "$2"; else printf '%s %s\n' "$1" "$3"; fi
}

# run_fb <name> [extra env assignments...]: like run_case, with the recording stubs; sets STATUS,
# ERR, OUT and the number of ssh, scp and wrangler calls of the run. FB_KEEP_DONE=1 leaves the done
# list of the previous run in place, which is what a rerun is.
run_fb() {
  shift
  rm -f "$SSH_LOG" "$SCP_LOG" "$CALLS2"
  if [[ "${FB_KEEP_DONE:-}" != "1" ]]; then rm -f "$TMP/root/.media-upload.done"; fi
  printf '%s\n' "${FB_ALIASES:-$FB_ALIASES_DEFAULT}" > "$TMP/root/media-aliases.json"
  set +e
  env -i PATH="$S2:/usr/bin:/bin" HOME="$TMP/home-fb" TMPDIR="$TMP/scratch" \
    CLOUDFLARE_API_TOKEN="$DUMMY_TOKEN" CLOUDFLARE_ACCOUNT_ID="$DUMMY_ACCOUNT" \
    WRANGLER="$S2/wrangler" POKOIN_OBJECTS="$TMP/objects2" KEYS_FILE="$FB_KEYS" \
    POKOIN_MEDIA_FALLBACK_OBJECTS="$REMOTE_OBJECTS" \
    SSH_LOG="$SSH_LOG" SCP_LOG="$SCP_LOG" CALLS2="$CALLS2" REAL_NODE="$REAL_NODE" \
    SSH_MISS="${SSH_MISS:-}" \
    "$@" bash "$TMP/root/scripts/upload-media-r2.sh" >"$TMP/out2" 2>"$TMP/err2"
  STATUS=$?
  set -e
  ERR="$(cat "$TMP/err2")"
  OUT="$(cat "$TMP/out2")"
  SSH_CALLS=0
  SCP_CALLS=0
  WR_CALLS=0
  if [[ -e "$SSH_LOG" ]]; then SSH_CALLS="$(grep -c '^---$' "$SSH_LOG")"; fi
  if [[ -e "$SCP_LOG" ]]; then SCP_CALLS="$(grep -c '^---$' "$SCP_LOG")"; fi
  if [[ -e "$CALLS2" ]]; then WR_CALLS="$(grep -c . "$CALLS2")"; fi
}

# the manifest and alias fixtures are read by a real node, so without one these cases prove nothing
if [[ -z "$REAL_NODE" ]]; then
  echo "FAIL: no node on PATH, the fallback-host and manifest cases cannot run"
  echo "FAILED"
  exit 1
fi

# s1. no fallback host and a key the manifest gives an object: ssh is asked nothing, the run says so
#     once, on stderr, after the summary, and exits 3
fb_keys b.png
fb_store
fb_manifest b.png "/store/b.png" -
run_fb s1
if [[ "$STATUS" -eq 3 ]] && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$SCP_CALLS" -eq 0 ]] \
  && [[ "$WR_CALLS" -eq 0 ]] \
  && [[ "$ERR" == *"skip (no source): b.png"* ]] \
  && [[ "$ERR" == *$'\n'"$(line_for 1 'key skipped: no source' 'keys skipped: no source')"* ]] \
  && [[ "$ERR" != *"no object in the manifest"* ]] \
  && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]]; then
  ok "s1 (a): host unset: no ssh or scp call, key skipped, count line on stderr after the summary, exit 3"
else
  bad "s1: status=$STATUS ssh=$SSH_CALLS scp=$SCP_CALLS wrangler=$WR_CALLS err=[$ERR] out=[$OUT]"
fi

# s2. fallback host set: ssh is asked exactly this command line, and the key it confirms is uploaded
fb_keys b.png
fb_store
fb_manifest b.png "/store/b.png" -
run_fb s2 POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST"
want_ssh="$(cat <<EXPECT
---
-o
BatchMode=yes
-o
ConnectTimeout=10
--
$FB_HOST
test -f $REMOTE_OBJECTS/b.png
EXPECT
)"
got_ssh=""
[[ -e "$SSH_LOG" ]] && got_ssh="$(cat "$SSH_LOG")"
scp_line=()
[[ -e "$SCP_LOG" ]] && mapfile -t scp_line < "$SCP_LOG"
want_wr="r2 object put pokoin-test-media/b.png --file ${scp_line[4]:-none} --remote --content-type image/png"
if [[ "$SSH_CALLS" -eq 1 ]] && [[ "$got_ssh" == "$want_ssh" ]] \
  && [[ "$SCP_CALLS" -eq 1 ]] && [[ "${#scp_line[@]}" -eq 5 ]] \
  && [[ "${scp_line[1]}" == "-q" ]] && [[ "${scp_line[2]}" == "--" ]] \
  && [[ "${scp_line[3]}" == "$FB_HOST:$REMOTE_OBJECTS/b.png" ]] \
  && [[ "${scp_line[4]}" == "$TMP/scratch/b.png."* ]] \
  && [[ "$STATUS" -eq 0 ]] && [[ "$WR_CALLS" -eq 1 ]] && [[ "$(cat "$CALLS2")" == "$want_wr" ]] \
  && [[ "$ERR" != *"skipped: no source"* ]] && [[ "$ERR" != *"no object in the manifest"* ]] \
  && [[ ! -e "${scp_line[4]}" ]] && [[ "$(cat "$TMP/root/.media-upload.done")" == "b.png" ]]; then
  ok "s2 (b): host set: ssh got its options then --, the host and the test; the fetched key uploaded, exit 0"
else
  bad "s2: status=$STATUS ssh=$SSH_CALLS scp=$SCP_CALLS wrangler=$WR_CALLS ssh_log=[$got_ssh] scp_log=[${scp_line[*]}] calls=[$(cat "$CALLS2" 2>/dev/null)] want_wr=[$want_wr] err=[$ERR]"
fi

# s3. a value that is not a plain host token is refused before any ssh or scp call; empty is unset
fb_keys b.png
fb_store
fb_manifest b.png "/store/b.png" -
for bad_value in '-oProxyCommand=x' 'a b' 'x;id' 'host:22'; do
  run_fb s3 POKOIN_MEDIA_FALLBACK_HOST="$bad_value"
  if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "invalid POKOIN_MEDIA_FALLBACK_HOST" ]] \
    && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$SCP_CALLS" -eq 0 ]] && [[ "$WR_CALLS" -eq 0 ]]; then
    ok "s3 (c): value [$bad_value]: exit 2, only that line on stderr, no ssh, scp or wrangler call"
  else
    bad "s3: value [$bad_value] status=$STATUS err=[$ERR] ssh=$SSH_CALLS scp=$SCP_CALLS wrangler=$WR_CALLS"
  fi
done

# s3n. a value that runs over two lines: the check is anchored at both ends, and the second line of
#      a host is a command the run would hand to ssh. The value is named by its shape, not printed.
run_fb s3n POKOIN_MEDIA_FALLBACK_HOST=$'host\nx'
if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "invalid POKOIN_MEDIA_FALLBACK_HOST" ]] \
  && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$SCP_CALLS" -eq 0 ]] && [[ "$WR_CALLS" -eq 0 ]]; then
  ok "s3n (item 5): a host value with an embedded newline: exit 2, only that line on stderr, no ssh, scp or wrangler call"
else
  bad "s3n: status=$STATUS err=[$ERR] ssh=$SSH_CALLS scp=$SCP_CALLS wrangler=$WR_CALLS"
fi

# s3t. the two shapes a plain host token is there to let through: a user with an at-sign, and a host
#      with its dots. Each reaches ssh as exactly one argument, after the --.
for good_value in 'user@host' 'host.example.invalid'; do
  run_fb s3t POKOIN_MEDIA_FALLBACK_HOST="$good_value"
  if [[ "$STATUS" -eq 0 ]] && [[ "$SSH_CALLS" -eq 1 ]] && [[ "$ERR" != *"invalid"* ]] \
    && grep -Fxq -- '--' "$SSH_LOG" && grep -Fxq -- "$good_value" "$SSH_LOG"; then
    ok "s3t (item 5): the value [$good_value] is accepted and reaches ssh as one argument"
  else
    bad "s3t: value [$good_value] status=$STATUS ssh=$SSH_CALLS ssh_log=[$(tr '\n' '|' < "$SSH_LOG" 2>/dev/null)] err=[$ERR]"
  fi
done
run_fb s3e POKOIN_MEDIA_FALLBACK_HOST=
if [[ "$STATUS" -eq 3 ]] && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$ERR" != *"invalid"* ]] \
  && [[ "$ERR" == *"skip (no source): b.png"* ]]; then
  ok "s3 (c): an empty value means no fallback, not an invalid one"
else
  bad "s3e: status=$STATUS ssh=$SSH_CALLS err=[$ERR]"
fi

# s3f. a host set and no remote directory to fetch out of: the run names the variable that is missing
#      and ends 2, and it does that before ssh is asked anything at all
fb_keys b.png
fb_store
fb_manifest b.png "/store/b.png" -
run_fb s3f POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST" POKOIN_MEDIA_FALLBACK_OBJECTS=
if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "$want_fallback_objects_line" ]] \
  && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$SCP_CALLS" -eq 0 ]] && [[ "$WR_CALLS" -eq 0 ]]; then
  ok "s3f: host set and remote directory empty: exit 2, only [$want_fallback_objects_line], no ssh, scp or wrangler call"
else
  bad "s3f: status=$STATUS ssh=$SSH_CALLS scp=$SCP_CALLS wrangler=$WR_CALLS err=[$ERR]"
fi

# s3g. no host and no remote directory: nothing is fetched from nowhere, so the variable is not asked
#      for and the run goes on to the skip it went on to before
run_fb s3g POKOIN_MEDIA_FALLBACK_HOST= POKOIN_MEDIA_FALLBACK_OBJECTS=
if [[ "$STATUS" -eq 3 ]] && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$ERR" != *"$want_fallback_objects_line"* ]] \
  && [[ "$ERR" == *"skip (no source): b.png"* ]]; then
  ok "s3g: with no host the remote directory is ignored, empty or not"
else
  bad "s3g: status=$STATUS ssh=$SSH_CALLS err=[$ERR]"
fi

# s0. the object directory has no default in the tree: with POKOIN_OBJECTS unset the run says which
#     variable to set and ends 2 before it looks at anything else, and the fallback-host validation
#     stays in front of it. These cases run with the recording stubs of the first section and a home
#     that holds no credentials file: a run that got past the check would report the missing
#     credentials instead, which is what makes the order visible.
run_objects() {
  shift; local dir="$1"; shift
  local -a objs=()
  if [[ -n "$dir" ]]; then objs=("POKOIN_OBJECTS=$dir"); fi
  mkdir -p "$TMP/home-objects/.config/pokoin"
  rm -f "$CALLS" "$TMP/root/.media-upload.done"
  # the file the forbidden stubs write to belongs to the whole suite and is checked at its end, so
  # this run measures it before and after instead of removing it
  FORB_BEFORE=0
  if [[ -e "$TMP/forbidden.calls" ]]; then FORB_BEFORE="$(wc -c < "$TMP/forbidden.calls")"; fi
  set +e
  env -i PATH="$TMP/stubs:/usr/bin:/bin" HOME="$TMP/home-objects" TMPDIR="$TMP/scratch" \
    WRANGLER="$TMP/stubs/wrangler" KEYS_FILE="$TMP/keys.txt" \
    "${objs[@]}" "$@" bash "$TMP/root/scripts/upload-media-r2.sh" >"$TMP/out" 2>"$TMP/err"
  STATUS=$?
  set -e
  ERR="$(cat "$TMP/err")"
  FORB_NOW="$FORB_BEFORE"
  if [[ -e "$TMP/forbidden.calls" ]]; then FORB_NOW="$(wc -c < "$TMP/forbidden.calls")"; fi
}
want_objects_line="set POKOIN_OBJECTS to the directory that holds the media objects"

# s0a. unset: only that line on stderr, exit 2, and neither wrangler nor ssh was reached
run_objects s0a ""
if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "$want_objects_line" ]] \
  && [[ ! -e "$CALLS" ]] && [[ "$FORB_NOW" -eq "$FORB_BEFORE" ]]; then
  ok "s0a: POKOIN_OBJECTS unset: exit 2, only [$want_objects_line], no wrangler, ssh or scp call"
else
  bad "s0a: status=$STATUS err=[$ERR] calls=$(cat "$CALLS" 2>/dev/null || echo none) forbidden=$((FORB_NOW - FORB_BEFORE))"
fi

# s0b. the same with an empty value: empty is unset, not a directory
run_objects s0b "" POKOIN_OBJECTS=
if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "$want_objects_line" ]] && [[ ! -e "$CALLS" ]] \
  && [[ "$FORB_NOW" -eq "$FORB_BEFORE" ]]; then
  ok "s0b: POKOIN_OBJECTS empty: exit 2 with the same line"
else
  bad "s0b: status=$STATUS err=[$ERR] calls=$(cat "$CALLS" 2>/dev/null || echo none)"
fi

# s0c. an unusable fallback host and no object directory: the host is still validated first
run_objects s0c "" POKOIN_MEDIA_FALLBACK_HOST='-oProxyCommand=x'
if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "invalid POKOIN_MEDIA_FALLBACK_HOST" ]] \
  && [[ ! -e "$CALLS" ]] && [[ "$FORB_NOW" -eq "$FORB_BEFORE" ]]; then
  ok "s0c: the fallback host is validated before the object directory is asked for"
else
  bad "s0c: status=$STATUS err=[$ERR] calls=$(cat "$CALLS" 2>/dev/null || echo none)"
fi

# s0d. set: the run goes on and reaches the credentials preflight it reached before the check existed
run_objects s0d "$TMP/objects"
want_creds_line="CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID must be set (looked in $TMP/home-objects/.config/pokoin/cloudflare.env)"
if [[ "$STATUS" -eq 1 ]] && [[ "$ERR" == "$want_creds_line" ]] \
  && [[ "$ERR" != *"$want_objects_line"* ]]; then
  ok "s0d: POKOIN_OBJECTS set: no complaint about it, the run goes on to the credentials preflight"
else
  bad "s0d: status=$STATUS err=[$ERR] want=[$want_creds_line]"
fi

# s0e/s0f. set, but not a directory: a name that is not there and a regular file, the two shapes a
#          typo makes. The store cannot be read out of either, so the run says so and ends 2 before
#          it looks at a key, at the credentials or at the done list.
want_not_a_dir_line="POKOIN_OBJECTS is not a directory"
for not_a_dir in "$TMP/no-such-dir" "$TMP/objects/a.png"; do
  run_objects s0e "$not_a_dir"
  if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "$want_not_a_dir_line" ]] \
    && [[ ! -e "$CALLS" ]] && [[ "$FORB_NOW" -eq "$FORB_BEFORE" ]] \
    && [[ ! -e "$TMP/root/.media-upload.done" ]]; then
    ok "s0e/s0f: POKOIN_OBJECTS=[$not_a_dir]: exit 2, only [$want_not_a_dir_line], no wrangler, ssh or scp call, no done list touched"
  else
    bad "s0e/s0f: POKOIN_OBJECTS=[$not_a_dir] status=$STATUS err=[$ERR] calls=$(cat "$CALLS" 2>/dev/null || echo none) forbidden=$((FORB_NOW - FORB_BEFORE)) done=$([[ -e "$TMP/root/.media-upload.done" ]] && echo written || echo untouched)"
  fi
done

# s0g. an unusable fallback host beside a store that is not a directory: the host is still validated
#      first, so the check of the directory holds the place the unset one held
run_objects s0g "$TMP/no-such-dir" POKOIN_MEDIA_FALLBACK_HOST='-oProxyCommand=x'
if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "invalid POKOIN_MEDIA_FALLBACK_HOST" ]] \
  && [[ ! -e "$CALLS" ]] && [[ "$FORB_NOW" -eq "$FORB_BEFORE" ]]; then
  ok "s0g: the fallback host is validated before the object directory is looked at"
else
  bad "s0g: status=$STATUS err=[$ERR] calls=$(cat "$CALLS" 2>/dev/null || echo none)"
fi

# s0h. a usable host and the remote directory not given at all: the run says which variable it is
#      missing, before the local store is asked for and before any ssh
run_objects s0h "" POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST"
if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "$want_fallback_objects_line" ]] \
  && [[ ! -e "$CALLS" ]] && [[ "$FORB_NOW" -eq "$FORB_BEFORE" ]]; then
  ok "s0h: host set and remote directory unset: exit 2, only that line, ahead of the local store and of any ssh"
else
  bad "s0h: status=$STATUS err=[$ERR] calls=$(cat "$CALLS" 2>/dev/null || echo none)"
fi

# s0i. the same with the remote directory given: the run goes on and asks for the local store, which
#      is what shows the two checks are separate questions
run_objects s0i "" POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST" POKOIN_MEDIA_FALLBACK_OBJECTS="$REMOTE_OBJECTS"
if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "$want_objects_line" ]] && [[ ! -e "$CALLS" ]] \
  && [[ "$FORB_NOW" -eq "$FORB_BEFORE" ]]; then
  ok "s0i: a run with a host and a remote directory but no local store asks for POKOIN_OBJECTS alone"
else
  bad "s0i: status=$STATUS err=[$ERR] calls=$(cat "$CALLS" 2>/dev/null || echo none)"
fi

# s4. one key resolvable and one not: the resolvable one is still uploaded, the run exits 3
fb_keys a.png b.png
fb_store a.png
fb_manifest a.png "/store/a.png" - b.png "/store/b.png" -
run_fb s4
if [[ "$STATUS" -eq 3 ]] && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$WR_CALLS" -eq 1 ]] \
  && grep -q 'pokoin-test-media/a\.png' "$CALLS2" \
  && [[ "$ERR" == *"skip (no source): b.png"* ]] && [[ "$ERR" != *"skip (no source): a.png"* ]] \
  && [[ "$ERR" == *$'\n'"1 key skipped: no source"* ]] \
  && [[ "$(cat "$TMP/root/.media-upload.done")" == "a.png" ]]; then
  ok "s4 (d): a mixed list: the key with a source uploaded, the one without counted, exit 3"
else
  bad "s4: status=$STATUS ssh=$SSH_CALLS wrangler=$WR_CALLS calls=[$(cat "$CALLS2" 2>/dev/null)] err=[$ERR]"
fi

# s5. a key the manifest records with no object but with an alias is a real skip, not a free one
fb_keys c.png
fb_store
fb_manifest c.png - gone.png
FB_ALIASES='{"c.png":"gone.png"}'
run_fb s5
FB_ALIASES=''
if [[ "$STATUS" -eq 3 ]] && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$WR_CALLS" -eq 0 ]] \
  && [[ "$ERR" == *"skip (no source or alias): c.png (alias gone.png)"* ]] \
  && [[ "$ERR" == *$'\n'"1 key skipped: no source"* ]] \
  && [[ "$ERR" != *"no object in the manifest"* ]]; then
  ok "s5: an alias whose source is missing too is counted as skipped: no source, and exits 3"
else
  bad "s5: status=$STATUS ssh=$SSH_CALLS wrangler=$WR_CALLS err=[$ERR]"
fi

# s5b. a row with no object and no aliasOf, but a key that media-aliases.json names: the alias map is
#      the record of a source the run is told to look for, so a run that finds neither the key nor its
#      alias is a real skip and not a free line about the manifest.
fb_keys null2.png
fb_store
fb_manifest null2.png - -
FB_ALIASES='{"null2.png":"gone.png"}'
run_fb s5b
FB_ALIASES=''
if [[ "$STATUS" -eq 3 ]] && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$WR_CALLS" -eq 0 ]] \
  && [[ "$ERR" == *"skip (no source or alias): null2.png (alias gone.png)"* ]] \
  && [[ "$ERR" == *$'\n'"1 key skipped: no source"* ]] \
  && [[ "$ERR" != *"no object in the manifest"* ]]; then
  ok "s5b (item 7): a null row the alias map names, unresolvable: [1 key skipped: no source] and exit 3, no free no-object line"
else
  bad "s5b: status=$STATUS ssh=$SSH_CALLS wrangler=$WR_CALLS err=[$ERR]"
fi

# s5c. the same row with nothing in the alias map: it stays what it was, a key no run can upload, said
#      apart and costing nothing
fb_keys null2.png
fb_store
fb_manifest null2.png - -
run_fb s5c
if [[ "$STATUS" -eq 0 ]] && [[ "$WR_CALLS" -eq 0 ]] \
  && [[ "$ERR" == *"1 key has no object in the manifest"* ]] \
  && [[ "$ERR" != *"skipped: no source"* ]]; then
  ok "s5c (item 7): a null row the alias map does not name is still counted apart and ends 0"
else
  bad "s5c: status=$STATUS wrangler=$WR_CALLS err=[$ERR]"
fi

# s5d. and the same row with its alias on disk: it goes up under the key it was asked for, which is
#      what it did before the count changed and still does
fb_keys null2.png
fb_store present.png
fb_manifest null2.png - -
FB_ALIASES='{"null2.png":"present.png"}'
run_fb s5d
FB_ALIASES=''
if [[ "$STATUS" -eq 0 ]] && [[ "$WR_CALLS" -eq 1 ]] \
  && grep -q 'pokoin-test-media/null2\.png' "$CALLS2" \
  && [[ "$ERR" != *"no object in the manifest"* ]] && [[ "$ERR" != *"skip"* ]]; then
  ok "s5d (item 7): a null row whose alias is on disk uploads under its own key and costs nothing"
else
  bad "s5d: status=$STATUS wrangler=$WR_CALLS calls=[$(cat "$CALLS2" 2>/dev/null)] err=[$ERR]"
fi

# s6. the keys the committed manifest records with no object are reported apart and cost nothing:
#     the fixture is that manifest with only those rows, and its count is checked against the
#     manifest's own counts.missing while the fixture is written
committed_manifest="$(cd "$HERE/.." && pwd)/media-manifest.json"
null_n="$(node -e '
const fs = require("fs");
const [from, manifestTo, keysTo] = process.argv.slice(1);
const m = JSON.parse(fs.readFileSync(from, "utf8"));
const rows = m.entries.filter((e) => e.object === null);
if (rows.length !== m.counts.missing) {
  console.error("rows with no object: " + rows.length + " != counts.missing: " + m.counts.missing);
  process.exit(1);
}
fs.writeFileSync(manifestTo, JSON.stringify({ entries: rows }) + "\n");
fs.writeFileSync(keysTo, rows.map((e) => e.key).join("\n") + "\n");
process.stdout.write(String(rows.length));
' "$committed_manifest" "$TMP/root/media-manifest.json" "$FB_KEYS" 2>"$TMP/err3")" || null_n=""
if [[ ! "$null_n" =~ ^[0-9]+$ ]] || (( null_n < 1 )); then
  bad "s6: no count of the committed manifest rows with no object: [$null_n] $(cat "$TMP/err3")"
else
  fb_store
  run_fb s6
  want_noobject="$(line_for "$null_n" 'key has no object in the manifest' 'keys have no object in the manifest')"
  skip_lines="$(grep -c '^skip (no source): ' "$TMP/err2" || true)"
  if [[ "$STATUS" -eq 0 ]] && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$WR_CALLS" -eq 0 ]] \
    && [[ "$ERR" == "$want_noobject" || "$ERR" == *$'\n'"$want_noobject" ]] \
    && [[ "$ERR" != *"skipped: no source"* ]] && [[ "$skip_lines" -eq "$null_n" ]]; then
    ok "s6: the $null_n keys the committed manifest records with no object print [$want_noobject], no skipped line, exit 0"
  else
    bad "s6: n=$null_n skip_lines=$skip_lines status=$STATUS ssh=$SSH_CALLS wrangler=$WR_CALLS err=[$ERR]"
  fi
fi

# s7. one key the manifest gives an object, absent on disk: exit 3 and the singular skip line
fb_keys d.png
fb_store
fb_manifest d.png "/store/d.png" -
run_fb s7
last_err="$(printf '%s\n' "$ERR" | tail -1)"
if [[ "$STATUS" -eq 3 ]] && [[ "$last_err" == "1 key skipped: no source" ]] \
  && [[ "$ERR" != *"no object in the manifest"* ]] && [[ "$WR_CALLS" -eq 0 ]]; then
  ok "s7: a key the manifest gives an object, not found: the last line is [1 key skipped: no source], exit 3"
else
  bad "s7: status=$STATUS last=[$last_err] wrangler=$WR_CALLS err=[$ERR]"
fi

# s8. three keys, one of each kind: the source is uploaded, the null row is reported apart, the
#     absent object is the reason the run exits 3
fb_keys present.png absent.png nothing.png
fb_store present.png
fb_manifest present.png "/store/present.png" - absent.png "/store/absent.png" - nothing.png - -
run_fb s8
err_tail="$(printf '%s\n' "$ERR" | tail -2 | tr '\n' '|')"
if [[ "$STATUS" -eq 3 ]] && [[ "$WR_CALLS" -eq 1 ]] \
  && grep -q 'pokoin-test-media/present\.png' "$CALLS2" \
  && [[ "$err_tail" == "1 key has no object in the manifest|1 key skipped: no source|" ]] \
  && [[ "$ERR" == *"skip (no source): nothing.png"* ]] \
  && [[ "$(cat "$TMP/root/.media-upload.done")" == "present.png" ]]; then
  ok "s8: mixed: uploaded the present one, both lines singular and in order, exit 3 for the absent object"
else
  bad "s8: status=$STATUS wrangler=$WR_CALLS tail=[$err_tail] calls=[$(cat "$CALLS2" 2>/dev/null)] err=[$ERR]"
fi

# s9. a key whose alias names an object that is on disk is uploaded under the requested key
fb_keys alias2.png
fb_store present.png
fb_manifest alias2.png - present.png
FB_ALIASES='{"alias2.png":"present.png"}'
run_fb s9
FB_ALIASES=''
if [[ "$STATUS" -eq 0 ]] && [[ "$WR_CALLS" -eq 1 ]] \
  && grep -q 'pokoin-test-media/alias2\.png --file '"$TMP"'/objects2/present\.png' "$CALLS2" \
  && [[ "$ERR" == *"uploaded alias2.png (from alias present.png)"* ]] \
  && [[ "$ERR" != *"skip"* ]]; then
  ok "s9: the alias is read from media-aliases.json in the upload child and uploaded under the key"
else
  bad "s9: status=$STATUS wrangler=$WR_CALLS calls=[$(cat "$CALLS2" 2>/dev/null)] err=[$ERR]"
fi

# s10. the host pattern is plain ASCII, its at-sign is the ASCII one, and user@host is accepted
pattern_ascii() {
  local file="$1" line n
  line="$(grep -F 'A-Za-z0-9' "$file")" || return 1
  n="$(printf '%s\n' "$line" | grep -c .)"
  if [[ "$n" -ne 1 ]]; then return 1; fi
  if LC_ALL=C grep -q '[^ -~]' <<<"$line"; then return 1; fi
  [[ "$(printf '%s' "$line" | tr -cd '@' | wc -c)" -ge 1 ]]
}
for pattern_file in "$SRC" "$HERE/media-manifest.mjs"; do
  if pattern_ascii "$pattern_file"; then
    ok "s10 (E): the host pattern of $(basename "$pattern_file") is one line of plain ASCII with an ASCII @"
  else
    bad "s10: the host pattern of $pattern_file is missing, ambiguous or not plain ASCII"
  fi
  # the colon is not one of the characters: it is how a URL splits a port off a host, and ssh and scp
  # take such a value for a host they cannot reach, so the pattern holds no colon at all
  if grep -F 'A-Za-z0-9' "$pattern_file" | grep -q ':'; then
    bad "s10b: the host pattern of $(basename "$pattern_file") still lets a colon through"
  else
    ok "s10b (item 5): the host pattern of $(basename "$pattern_file") holds no colon"
  fi
done
fb_keys b.png
fb_store
fb_manifest b.png "/store/b.png" -
run_fb s10 POKOIN_MEDIA_FALLBACK_HOST='user@host'
if [[ "$STATUS" -eq 0 ]] && [[ "$SSH_CALLS" -eq 1 ]] && [[ "$ERR" != *"invalid"* ]] \
  && grep -Fxq -- '--' "$SSH_LOG" && grep -Fxq 'user@host' "$SSH_LOG"; then
  ok "s10 (E): the ASCII value user@host is accepted and reaches ssh after the --"
else
  bad "s10: value user@host status=$STATUS ssh=$SSH_CALLS ssh_log=[$(cat "$SSH_LOG" 2>/dev/null)] err=[$ERR]"
fi

# s11. the credentials loader block is delimited by exactly one begin and one end marker line
begin_n="$(awk '/^# --- credentials loader: begin$/{n++} END{print n+0}' "$SRC")"
end_n="$(awk '/^# --- credentials loader: end$/{n++} END{print n+0}' "$SRC")"
if [[ "$begin_n" == "1" && "$end_n" == "1" ]]; then
  ok "s11 (e): exactly one loader begin marker and one loader end marker"
else
  bad "s11: begin markers=$begin_n end markers=$end_n"
fi

# ---------------------------------------------------------------------------
# s13..s17: an upload that fails. The wrangler stub of this section refuses the put of every key
# named in the FAIL_KEYS file. The per-key work runs in an xargs child bash that has no errexit, so
# a failed put ran on into the done list: the key was recorded as uploaded, a rerun never retried
# it, and the whole run ended 0.
# ---------------------------------------------------------------------------
FAIL_KEYS="$TMP/wrangler-fail-keys"

# fail_keys [key]...: the keys whose wrangler put fails from now on; with no argument the stub is
# fixed again, which is what the rerun of s14 needs.
fail_keys() {
  : > "$FAIL_KEYS"
  local k
  for k in "$@"; do printf '%s\n' "$k" >> "$FAIL_KEYS"; done
}

# done_list: the done list of the last run, sorted, or a word for its absence
done_list() {
  if [[ -e "$TMP/root/.media-upload.done" ]]; then
    sort "$TMP/root/.media-upload.done"
  else
    printf '(none)\n'
  fi
}

# s13 (a). one key whose wrangler call fails and one that succeeds: the run exits 4, says how many
#          failed in its last stderr line, and the done list holds the good key alone
fb_keys good.png bad.png
fb_store good.png bad.png
fb_manifest good.png "/store/good.png" - bad.png "/store/bad.png" -
fail_keys bad.png
run_fb s13 FAIL_KEYS="$FAIL_KEYS"
err_last="$(printf '%s\n' "$ERR" | tail -1)"
DONE_ROWS="$(done_list | tr '\n' '|')"
if [[ "$STATUS" -eq 4 ]] \
  && [[ "$err_last" == "$(line_for 1 'key failed to upload' 'keys failed to upload')" ]] \
  && [[ "$ERR" == *"upload failed: bad.png"* ]] && [[ "$ERR" != *"upload failed: good.png"* ]] \
  && [[ "$WR_CALLS" -eq 2 ]] && grep -q 'pokoin-test-media/good\.png' "$CALLS2" \
  && [[ "$DONE_ROWS" == "good.png|" ]]; then
  ok "s13 (a): a failed put: exit 4, [1 key failed to upload] as the last line, the good key uploaded and recorded, the failed key not recorded"
else
  bad "s13: status=$STATUS err_last=[$err_last] wrangler=$WR_CALLS done=[$DONE_ROWS] calls=[$(sort "$CALLS2" 2>/dev/null | tr '\n' '|')] err=[$ERR]"
fi

# s14 (b). the same run again with the stub fixed: the key that failed was not recorded as done, so
#          the rerun uploads it, the recorded one is not uploaded twice, and the run ends 0
fail_keys
FB_KEEP_DONE=1
run_fb s14 FAIL_KEYS="$FAIL_KEYS"
FB_KEEP_DONE=""
DONE_ROWS="$(done_list | tr '\n' '|')"
if [[ "$STATUS" -eq 0 ]] && [[ "$WR_CALLS" -eq 1 ]] \
  && grep -q 'pokoin-test-media/bad\.png' "$CALLS2" \
  && [[ "$ERR" != *"failed to upload"* ]] && [[ "$ERR" != *"upload failed"* ]] \
  && [[ "$DONE_ROWS" == "bad.png|good.png|" ]]; then
  ok "s14 (b): a rerun with the stub fixed uploads the key that had failed, does not re-upload the recorded one, and exits 0"
else
  bad "s14: status=$STATUS wrangler=$WR_CALLS done=[$DONE_ROWS] calls=[$(sort "$CALLS2" 2>/dev/null | tr '\n' '|')] err=[$ERR]"
fi

# s15 (c). two failed uploads and a real skip in one list: both count lines, in the order of the
#          summary, and the failure outranks the skip's 3
fb_keys good.png bad1.png bad2.png absent.png
fb_store good.png bad1.png bad2.png
fb_manifest good.png "/store/good.png" - bad1.png "/store/bad1.png" - \
  bad2.png "/store/bad2.png" - absent.png "/store/absent.png" -
fail_keys bad1.png bad2.png
run_fb s15 FAIL_KEYS="$FAIL_KEYS"
err_tail="$(printf '%s\n' "$ERR" | tail -2 | tr '\n' '|')"
DONE_ROWS="$(done_list | tr '\n' '|')"
if [[ "$STATUS" -eq 4 ]] \
  && [[ "$err_tail" == "1 key skipped: no source|2 keys failed to upload|" ]] \
  && [[ "$ERR" == *"upload failed: bad1.png"* ]] && [[ "$ERR" == *"upload failed: bad2.png"* ]] \
  && [[ "$ERR" == *"skip (no source): absent.png"* ]] \
  && [[ "$ERR" != *"no object in the manifest"* ]] \
  && [[ "$WR_CALLS" -eq 3 ]] \
  && [[ "$DONE_ROWS" == "good.png|" ]] \
  && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]]; then
  ok "s15 (c): two failed uploads with a skip: the skip line then the plural failure line, exit 4 for the failure, only the good key recorded"
else
  bad "s15: status=$STATUS err_tail=[$err_tail] wrangler=$WR_CALLS done=[$DONE_ROWS] out=[$OUT] err=[$ERR]"
fi

# s16 (d). nothing failing: the exit status and the output are exactly the ones of today, both for
#          a list that uploads whole and for one with a real skip in it
fb_keys good.png other.png
fb_store good.png other.png
fb_manifest good.png "/store/good.png" - other.png "/store/other.png" -
fail_keys
run_fb s16 FAIL_KEYS="$FAIL_KEYS"
DONE_ROWS="$(done_list | tr '\n' '|')"
if [[ "$STATUS" -eq 0 ]] && [[ "$WR_CALLS" -eq 2 ]] \
  && [[ -z "$ERR" ]] && [[ "$DONE_ROWS" == "good.png|other.png|" ]] \
  && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]]; then
  ok "s16 (d): all uploads fine: exit 0, nothing on stderr, both keys recorded, the usual lines on stdout"
else
  bad "s16: status=$STATUS wrangler=$WR_CALLS done=[$DONE_ROWS] out=[$OUT] err=[$ERR]"
fi
fb_keys good.png absent.png
fb_store good.png
fb_manifest good.png "/store/good.png" - absent.png "/store/absent.png" -
run_fb s16b FAIL_KEYS="$FAIL_KEYS"
err_last="$(printf '%s\n' "$ERR" | tail -1)"
DONE_ROWS="$(done_list | tr '\n' '|')"
if [[ "$STATUS" -eq 3 ]] && [[ "$err_last" == "1 key skipped: no source" ]] \
  && [[ "$ERR" != *"failed"* ]] && [[ "$WR_CALLS" -eq 1 ]] \
  && [[ "$DONE_ROWS" == "good.png|" ]]; then
  ok "s16 (d): a real skip on its own still costs 3, with its own line and no failure line"
else
  bad "s16b: status=$STATUS err_last=[$err_last] wrangler=$WR_CALLS done=[$DONE_ROWS] err=[$ERR]"
fi

# s17 (e). the HEAD sample at the end of the run fails after uploads that all worked: the count
#          lines are already printed when the sample is attempted, the run still says Done, and the
#          status is the one a sample fetch costs, 5, because nothing of a higher code happened. A
#          key the committed manifest gives no object reports itself but costs nothing, which is
#          what keeps this run above the 0 of a clean one.
fb_keys good.png nothing.png
fb_store good.png
fb_manifest good.png "/store/good.png" - nothing.png - -
fail_keys
run_fb s17 FAIL_KEYS="$FAIL_KEYS" SAMPLE_FAIL=1
err_last="$(printf '%s\n' "$ERR" | tail -1)"
if [[ "$STATUS" -eq 5 ]] \
  && [[ "$err_last" == "$(line_for 1 'key has no object in the manifest' 'keys have no object in the manifest')" ]] \
  && [[ "$ERR" == *"skip (no source): nothing.png"* ]] && [[ "$ERR" != *"failed"* ]] \
  && [[ "$WR_CALLS" -eq 1 ]] && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]]; then
  ok "s17 (e): a failing sample fetch after good uploads: the count line precedes it, the run still says Done, exit 5"
else
  bad "s17: status=$STATUS err_last=[$err_last] wrangler=$WR_CALLS out=[$OUT] err=[$ERR]"
fi

# a real skip outranks the sample's status: 3, with its line already printed
fb_keys good.png absent.png
fb_store good.png
fb_manifest good.png "/store/good.png" - absent.png "/store/absent.png" -
run_fb s17b FAIL_KEYS="$FAIL_KEYS" SAMPLE_FAIL=1
err_last="$(printf '%s\n' "$ERR" | tail -1)"
if [[ "$STATUS" -eq 3 ]] && [[ "$err_last" == "1 key skipped: no source" ]] \
  && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]]; then
  ok "s17 (e): a failing sample fetch with a real skip: exit 3, the skip outranks the sample"
else
  bad "s17b: status=$STATUS err_last=[$err_last] out=[$OUT] err=[$ERR]"
fi

# a failed upload outranks both
fb_keys good.png bad.png
fb_store good.png bad.png
fb_manifest good.png "/store/good.png" - bad.png "/store/bad.png" -
fail_keys bad.png
run_fb s17c FAIL_KEYS="$FAIL_KEYS" SAMPLE_FAIL=1
err_last="$(printf '%s\n' "$ERR" | tail -1)"
if [[ "$STATUS" -eq 4 ]] && [[ "$err_last" == "1 key failed to upload" ]] \
  && grep -q 'pokoin-test-media/good\.png' "$CALLS2"; then
  ok "s17 (e): a failed upload with a failing sample fetch: exit 4, the failure line last"
else
  bad "s17c: status=$STATUS err_last=[$err_last] calls=[$(sort "$CALLS2" 2>/dev/null | tr '\n' '|')] err=[$ERR]"
fi
fail_keys

# ---------------------------------------------------------------------------
# s18..s21: every key handed to xargs is accounted for. The per-key work runs in an xargs child
# that has no errexit, so the only thing that says a key was worked at all is the record the child
# writes. Three ways a child can leave that record unwritten: nowhere to write it (s18), a child
# that exits 255, which stops xargs before the later keys (s19), and a child killed by a signal,
# which does the same (s20). Today all three end the run without the counts: s18 silently, because
# the write of the failure record is not checked and the child still returns 0, and s19 and s20
# loudly, because a nonzero xargs status hits errexit and the script dies at that line.
# ---------------------------------------------------------------------------

# unaccounted_line <n>: the line the run must print when n of the keys it handed to xargs reported
# nothing at all.
unaccounted_line() {
  if [[ "$1" == "1" ]]; then printf 'unaccounted: 1 key\n'; else printf 'unaccounted: %s keys\n' "$1"; fi
}

# s18 (a). a failing put whose record cannot be written, because the directory holding the record
#          files of the run was removed during that put: the key is not accounted for, so the run
#          says so, prints its counts, still says Done and ends 4 -- never 0.
fb_keys good.png bad.png
fb_store good.png bad.png
fb_manifest good.png "/store/good.png" - bad.png "/store/bad.png" -
fail_keys
run_fb s18 PARALLEL=1 UNRECORDABLE_KEY=bad.png
DONE_ROWS="$(done_list | tr '\n' '|')"
if [[ "$STATUS" -eq 4 ]] \
  && [[ "$ERR" == *"upload failed: bad.png"* ]] \
  && [[ "$ERR" == *"cannot record result for: bad.png"* ]] \
  && [[ "$ERR" == *"$(unaccounted_line 2)"* ]] \
  && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]] \
  && [[ "$DONE_ROWS" == "good.png|" ]]; then
  ok "s18 (a): a failure record that cannot be written: the child says so, the key is counted unaccounted, the counts and Done print, exit 4"
else
  bad "s18: status=$STATUS done=[$DONE_ROWS] out=[$OUT] err=[$ERR]"
fi

# s18b. the same with one key only, which is the singular of the unaccounted line.
fb_keys bad.png
fb_store bad.png
fb_manifest bad.png "/store/bad.png" -
fail_keys
run_fb s18b PARALLEL=1 UNRECORDABLE_KEY=bad.png
if [[ "$STATUS" -eq 4 ]] \
  && [[ "$ERR" == *"$(unaccounted_line 1)"* ]] && [[ "$ERR" != *"$(unaccounted_line 2)"* ]] \
  && [[ "$ERR" == *"cannot record result for: bad.png"* ]]; then
  ok "s18b: one key that recorded nothing prints [$(unaccounted_line 1)], not the plural"
else
  bad "s18b: status=$STATUS out=[$OUT] err=[$ERR]"
fi

# s19 (b). the child of one key exits 255, which makes xargs stop there: the keys after it were
#          never worked, so they are the unaccounted ones, and the run still prints its counts and
#          ends 4 instead of dying at the xargs line.
fb_keys good.png die255.png later.png
fb_store good.png die255.png later.png
fb_manifest good.png "/store/good.png" - die255.png "/store/die255.png" - later.png "/store/later.png" -
run_fb s19 PARALLEL=1 BASH_ENV="$S2/die255.bashenv" DIE255_KEY=die255.png
DONE_ROWS="$(done_list | tr '\n' '|')"
if [[ "$STATUS" -eq 4 ]] \
  && [[ "$ERR" == *"$(unaccounted_line 2)"* ]] \
  && [[ "$ERR" == *"xargs status: 124"* ]] \
  && [[ "$ERR" != *"failed to upload"* ]] && [[ "$ERR" != *"skipped: no source"* ]] \
  && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]] \
  && [[ "$WR_CALLS" -eq 1 ]] && [[ "$DONE_ROWS" == "good.png|" ]]; then
  ok "s19 (b): a child that exits 255: [$(unaccounted_line 2)] and [xargs status: 124] on stderr, the counts and Done print, exit 4"
else
  bad "s19: status=$STATUS wrangler=$WR_CALLS done=[$DONE_ROWS] out=[$OUT] err=[$ERR]"
fi

# s20 (c). the child of one key is killed by a signal during its put, which also stops xargs: that
#          key and the one after it are unaccounted, and the killed key is neither recorded as done
#          nor counted as failed, since it never got to say anything.
fb_keys good.png killed.png later.png
fb_store good.png killed.png later.png
fb_manifest good.png "/store/good.png" - killed.png "/store/killed.png" - later.png "/store/later.png" -
run_fb s20 PARALLEL=1 KILLED_KEY=killed.png
DONE_ROWS="$(done_list | tr '\n' '|')"
if [[ "$STATUS" -eq 4 ]] \
  && [[ "$ERR" == *"$(unaccounted_line 2)"* ]] \
  && [[ "$ERR" == *"xargs status: 125"* ]] \
  && [[ "$ERR" != *"upload failed: killed.png"* ]] \
  && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]] \
  && [[ "$DONE_ROWS" == "good.png|" ]]; then
  ok "s20 (c): a child killed by a signal: [$(unaccounted_line 2)] and [xargs status: 125] on stderr, the counts and Done print, exit 4"
else
  bad "s20: status=$STATUS done=[$DONE_ROWS] out=[$OUT] err=[$ERR]"
fi

# s21 (d). an ordinary mixed run keeps the output PK-C043 gives: one key uploaded, one real skip,
#          one row the manifest gives no object, one failed put. All of its keys report themselves,
#          so nothing is unaccounted and the script's own stderr is exactly the per-key lines then
#          the three counts, in that order. The stub's own line about the failed put is left out of
#          the comparison.
fb_keys good.png absent.png nothing.png bad.png
fb_store good.png bad.png
fb_manifest good.png "/store/good.png" - absent.png "/store/absent.png" - \
  nothing.png - - bad.png "/store/bad.png" -
fail_keys bad.png
run_fb s21 PARALLEL=1 FAIL_KEYS="$FAIL_KEYS"
want_err="$(printf '%s\n' 'skip (no source): absent.png' 'skip (no source): nothing.png' \
  'upload failed: bad.png' \
  '1 key has no object in the manifest' '1 key skipped: no source' '1 key failed to upload')"
err_script="$(printf '%s\n' "$ERR" | grep -v '^stub wrangler:' || true)"
DONE_ROWS="$(done_list | tr '\n' '|')"
if [[ "$STATUS" -eq 4 ]] && [[ "$err_script" == "$want_err" ]] \
  && [[ "$ERR" != *"unaccounted"* ]] \
  && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]] && [[ "$DONE_ROWS" == "good.png|" ]]; then
  ok "s21 (d): the counts of an ordinary run are exactly the PK-C043 ones, with no unaccounted line and exit 4"
else
  bad "s21: status=$STATUS err=[$err_script] want=[$want_err] done=[$DONE_ROWS] out=[$OUT]"
fi

# ---------------------------------------------------------------------------
# s22..s24: the done list. A key is looked up in it as data, never as an option (s22), and a forced
# run rewrites it: the children of that run used to share one temporary file, so eight of them
# rewriting the list at once lost keys that had never been touched (s24). s23 is the end state a
# forced run has to give, which the old code already gave as long as one child ran at a time.
# ---------------------------------------------------------------------------

# force_keys: the eight keys of the forced runs, in the store and in the fixture manifest
force_rows=()
force_keys=()
for i in 1 2 3 4 5 6 7 8; do
  force_keys+=("k$i.png")
  force_rows+=("k$i.png" "/store/k$i.png" "-")
done
force_store() {
  rm -f "$TMP/objects2"/*
  local k
  for k in "${force_keys[@]}"; do printf x > "$TMP/objects2/$k"; done
}

# s22. a key whose name starts with a dash is already recorded: the lookup is a data lookup, so the
#      key is not uploaded again and its row is not written twice.
fb_keys '-c.png'
fb_store '-c.png'
fb_manifest '-c.png' "/store/-c.png" -
fail_keys
printf '%s\n' '-c.png' > "$TMP/root/.media-upload.done"
FB_KEEP_DONE=1
run_fb s22 PARALLEL=1
FB_KEEP_DONE=''
DONE_ROWS="$(done_list | tr '\n' '|')"
if [[ "$STATUS" -eq 0 ]] && [[ "$WR_CALLS" -eq 0 ]] && [[ -z "$ERR" ]] \
  && [[ "$DONE_ROWS" == "-c.png|" ]]; then
  ok "s22: a key whose name starts with a dash is looked up in the done list as data: not uploaded, recorded once"
else
  bad "s22: status=$STATUS wrangler=$WR_CALLS done=[$DONE_ROWS] err=[$ERR]"
fi

# s23. FORCE=1 over two keys, one of them recorded twice: both go up, and the list holds every key
#      once, the re-uploaded ones last.
fb_keys k1.png k2.png
force_store
fb_manifest k1.png "/store/k1.png" - k2.png "/store/k2.png" -
fail_keys
printf '%s\n' other.png k1.png k1.png > "$TMP/root/.media-upload.done"
FB_KEEP_DONE=1
run_fb s23 PARALLEL=1 FORCE=1
FB_KEEP_DONE=''
want_done="$(printf '%s\n' other.png k1.png k2.png)"
DONE_ROWS="$(cat "$TMP/root/.media-upload.done")"
if [[ "$STATUS" -eq 0 ]] && [[ "$WR_CALLS" -eq 2 ]] && [[ "$DONE_ROWS" == "$want_done" ]]; then
  ok "s23: FORCE over a recorded key: it uploads again and the done list holds each key once, the forced ones last"
else
  bad "s23: status=$STATUS wrangler=$WR_CALLS done=[$(printf '%s\n' "$DONE_ROWS" | tr '\n' '|')] err=[$ERR]"
fi

# s24. the same with eight forced keys and two hundred rows the run never touches, all eight children
#      at once: every key of the list is still there, once each. One shared temporary file for the
#      rewrite is how PK-C043 lost rows of it.
fb_keys "${force_keys[@]}"
force_store
fb_manifest "${force_rows[@]}"
fail_keys
{
  for i in $(seq 1 200); do printf 'fill%s.png\n' "$i"; done
  for k in "${force_keys[@]}"; do printf '%s\n' "$k"; done
} > "$TMP/root/.media-upload.done"
FB_KEEP_DONE=1
run_fb s24 FORCE=1 PARALLEL=8
FB_KEEP_DONE=''
done_rows="$(grep -c . "$TMP/root/.media-upload.done" || true)"
done_dups="$(sort "$TMP/root/.media-upload.done" | uniq -d | grep -c '' || true)"
done_fill="$(grep -c '^fill' "$TMP/root/.media-upload.done" || true)"
if [[ "$STATUS" -eq 0 ]] && [[ "$WR_CALLS" -eq 8 ]] \
  && [[ "$done_rows" -eq 208 ]] && [[ "$done_dups" -eq 0 ]] && [[ "$done_fill" -eq 200 ]]; then
  ok "s24: eight forced children leave the two hundred rows they were never given: 208 rows, none twice"
else
  bad "s24: status=$STATUS wrangler=$WR_CALLS rows=$done_rows dups=$done_dups fill=$done_fill err=[$ERR]"
fi
fail_keys

# ---------------------------------------------------------------------------
# s25..s31: the key list a rerun was given twice (s25, s26), a done list that will not take the row
# of a key that uploaded (s27, s27b, s28), a run that cannot read or rewrite what its counts are
# made of (s29, s30), and a run with nothing to do (s31, s31b). The line that says what xargs ended
# with, for the two child deaths of s19 and s20, is asserted there.
# ---------------------------------------------------------------------------

# wrangler_calls_for <key>: how many puts of that key the last run made
wrangler_calls_for() {
  if [[ -e "$CALLS2" ]]; then
    grep -c -- "pokoin-test-media/$1 " "$CALLS2" || true
  else
    printf '0\n'
  fi
}

# s25 (A). a keys file that lists one key twice: both children report that key, so it accounts for
#          itself once while the run handed it out twice. The comparison of the two ends 4 with
#          [unaccounted: 1 key] for a run in which nothing went wrong at all.
fb_keys dup.png dup.png other.png
fb_store dup.png other.png
fb_manifest dup.png "/store/dup.png" - other.png "/store/other.png" -
run_fb s25 PARALLEL=1
dup_uploads="$(wrangler_calls_for dup.png)"
if [[ "$STATUS" -eq 0 ]] && [[ "$OUT" == *"Keys to process: 2"* ]] \
  && [[ "$ERR" != *"unaccounted"* ]] && [[ "$dup_uploads" -eq 1 ]] && [[ "$WR_CALLS" -eq 2 ]]; then
  ok "s25 (A): a key listed twice in the keys file is uploaded once, the run says 2 keys and ends 0"
else
  bad "s25: status=$STATUS first_out=[$(printf '%s\n' "$OUT" | head -1)] wrangler=$WR_CALLS dup=$dup_uploads err=[$ERR]"
fi

# s26 (A). the same with the keys taken from the manifest, where the generator can list one key as
#          two rows: two rows of one key are two keys to process minus one, not three.
fb_manifest dup.png "/store/dup.png" - other.png "/store/other.png" - dup.png "/store/dup.png" -
run_fb s26 PARALLEL=1 KEYS_FILE=
dup_uploads="$(wrangler_calls_for dup.png)"
if [[ "$STATUS" -eq 0 ]] && [[ "$OUT" == *"Keys to process: 2"* ]] \
  && [[ "$ERR" != *"unaccounted"* ]] && [[ "$dup_uploads" -eq 1 ]] && [[ "$WR_CALLS" -eq 2 ]]; then
  ok "s26 (A): a manifest that lists one key twice is 2 keys to process, and the key goes up once"
else
  bad "s26: status=$STATUS first_out=[$(printf '%s\n' "$OUT" | head -1)] wrangler=$WR_CALLS dup=$dup_uploads err=[$ERR]"
fi

# s26b (item 6). two keys that differ only by the blanks in front of them: the dedupe of the string
#                sees two, the workers see one -- xargs -I takes the blanks off before it hands the
#                argument over -- so the run handed two keys out, got one record back and ended 4 with
#                an unaccounted key for a list that held nothing wrong. The blanks come off the keys
#                before anything else uses them, which makes the two the same key to both ends.
fb_keys ' a.png' 'a.png'
fb_store a.png
fb_manifest a.png "/store/a.png" -
run_fb s26b PARALLEL=1
a_uploads="$(wrangler_calls_for a.png)"
if [[ "$STATUS" -eq 0 ]] && [[ "$OUT" == *"Keys to process: 1"* ]] \
  && [[ "$a_uploads" -eq 1 ]] && [[ "$WR_CALLS" -eq 1 ]] && [[ "$ERR" != *"unaccounted"* ]] \
  && [[ "$(done_list)" == "a.png" ]]; then
  ok "s26b (F): [ a.png] and [a.png] in one keys file are one key: 1 to process, one upload, exit 0"
else
  bad "s26b: status=$STATUS first_out=[$(printf '%s\n' "$OUT" | head -1)] wrangler=$WR_CALLS uploads=$a_uploads done=[$(done_list)] err=[$ERR]"
fi

# s26c (item 6). the strip leaves the keys that are not blanks alone: a name with a blank inside it is
#                still the name it was, and a key that starts with a dash is still data
fb_keys ' k1.png' 'k2 p x.png' '-c.png'
fb_store 'k2 p x.png' '-c.png'
fb_manifest 'k2 p x.png' "/store/k2 p x.png" - '-c.png' "/store/-c.png" -
run_fb s26c PARALLEL=1
if [[ "$STATUS" -eq 3 ]] && [[ "$OUT" == *"Keys to process: 3"* ]] \
  && [[ "$WR_CALLS" -eq 2 ]] && grep -qF -- 'pokoin-test-media/k2 p x.png ' "$CALLS2" \
  && grep -qF -- 'pokoin-test-media/-c.png ' "$CALLS2" \
  && [[ "$ERR" == *"skip (no source): k1.png"* ]] && [[ "$ERR" != *"skip (no source):  k1.png"* ]]; then
  ok "s26c (F): the blanks that come off are the ones in front: the name holds its own, the key holds its dash"
else
  bad "s26c: status=$STATUS first_out=[$(printf '%s\n' "$OUT" | head -1)] wrangler=$WR_CALLS calls=[$(tr '\n' '|' < "$CALLS2" 2>/dev/null)] err=[$ERR]"
fi

# s27 (B). the done list will not take a row, because it is not writable: every key still goes up,
#          but a rerun of this bucket would put them up again, so the run says so and ends 4.
fb_keys good.png other.png
fb_store good.png other.png
fb_manifest good.png "/store/good.png" - other.png "/store/other.png" -
printf '%s\n' seed.png > "$TMP/root/.media-upload.done"
chmod 444 "$TMP/root/.media-upload.done"
FB_KEEP_DONE=1
run_fb s27 PARALLEL=1
FB_KEEP_DONE=''
chmod 644 "$TMP/root/.media-upload.done"
want_not_recorded="$(line_for 2 'key uploaded but not recorded in the done list' \
  'keys uploaded but not recorded in the done list')"
if [[ "$STATUS" -eq 4 ]] && [[ "$ERR" == *"done list not writable: good.png"* ]] \
  && [[ "$ERR" == *"done list not writable: other.png"* ]] && [[ "$ERR" == *"$want_not_recorded"* ]] \
  && [[ "$ERR" != *"unaccounted"* ]] && [[ "$WR_CALLS" -eq 2 ]] \
  && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]] \
  && [[ "$(cat "$TMP/root/.media-upload.done")" == "seed.png" ]]; then
  ok "s27 (B): an unwritable done list: both keys upload, each says [done list not writable], [$want_not_recorded] and exit 4"
else
  bad "s27: status=$STATUS wrangler=$WR_CALLS done=[$(cat "$TMP/root/.media-upload.done")] err=[$ERR]"
fi

# s27b. the same with one key, which is the singular of that line, and a manifest null row beside it
#       so the other counts keep their places.
fb_keys bad1.png nothing.png
fb_store bad1.png
fb_manifest bad1.png "/store/bad1.png" - nothing.png - -
printf '%s\n' seed.png > "$TMP/root/.media-upload.done"
chmod 444 "$TMP/root/.media-upload.done"
FB_KEEP_DONE=1
run_fb s27b PARALLEL=1
FB_KEEP_DONE=''
chmod 644 "$TMP/root/.media-upload.done"
want_one="$(line_for 1 'key uploaded but not recorded in the done list' \
  'keys uploaded but not recorded in the done list')"
if [[ "$STATUS" -eq 4 ]] && [[ "$ERR" == *"$want_one"* ]] && [[ "$ERR" != *"$want_not_recorded"* ]] \
  && [[ "$ERR" == *"1 key has no object in the manifest"* ]] \
  && [[ "$ERR" != *"unaccounted"* ]] && [[ "$ERR" != *"skipped: no source"* ]]; then
  ok "s27b: one key that could not be recorded prints [$want_one], not the plural, and the null row keeps its own line"
else
  bad "s27b: status=$STATUS wrangler=$WR_CALLS err=[$ERR]"
fi

# s28. the done-list path is a directory: the append cannot work either, and the run must not read
#      it as an empty list and end 0.
fb_keys good.png
fb_store good.png
fb_manifest good.png "/store/good.png" -
rm -f "$TMP/root/.media-upload.done"
mkdir -p "$TMP/root/.media-upload.done"
FB_KEEP_DONE=1
run_fb s28 PARALLEL=1
FB_KEEP_DONE=''
rmdir "$TMP/root/.media-upload.done"
if [[ "$STATUS" -eq 4 ]] && [[ "$ERR" == *"done list not writable: good.png"* ]] \
  && [[ "$ERR" == *"$want_one"* ]] && [[ "$ERR" != *"unaccounted"* ]] \
  && [[ "$WR_CALLS" -eq 1 ]] && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]]; then
  ok "s28: a done list that is a directory: the key uploads, the run says it recorded nothing and ends 4"
else
  bad "s28: status=$STATUS wrangler=$WR_CALLS err=[$ERR] out=[$OUT]"
fi

# s29 (D). the node call that reads the manifest rows for the counts fails. The counts of the keys
#          that reported are already known, so the run must print them, say what it could not read,
#          and end 4 instead of dying at that line with no report at all.
fb_keys good.png absent.png
fb_store good.png
fb_manifest good.png "/store/good.png" - absent.png "/store/absent.png" -
run_fb s29 PARALLEL=1 NULL_ROWS_FAIL=1
if [[ "$STATUS" -eq 4 ]] && [[ "$ERR" == *"could not read the manifest rows"* ]] \
  && [[ "$ERR" == *"1 key skipped: no source"* ]] \
  && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]]; then
  ok "s29 (D): a failing manifest-rows read: the counts still print, [could not read the manifest rows] says why, exit 4"
else
  bad "s29: status=$STATUS err=[$ERR] out=[$OUT]"
fi

# s30 (D). a forced run whose done-list rewrite cannot work, because nothing new can be created in
#          the directory of the list: the children had already appended their keys, so the list is
#          left with the duplicates and the run says it could not rewrite it.
fb_keys "${force_keys[0]}" "${force_keys[1]}"
force_store
fb_manifest "${force_keys[0]}" "/store/${force_keys[0]}" - "${force_keys[1]}" "/store/${force_keys[1]}" -
{
  printf '%s\n' seed.png
  printf '%s\n' "${force_keys[0]}"
} > "$TMP/root/.media-upload.done"
chmod 555 "$TMP/root"
FB_KEEP_DONE=1
run_fb s30 PARALLEL=1 FORCE=1
FB_KEEP_DONE=''
chmod 755 "$TMP/root"
done_rows_after="$(grep -c . "$TMP/root/.media-upload.done" || true)"
rm -f "$TMP/root/.media-upload.done.tmp"
if [[ "$STATUS" -eq 4 ]] && [[ "$ERR" == *"could not rewrite the done list"* ]] \
  && [[ "$WR_CALLS" -eq 2 ]] && [[ "$ERR" != *"unaccounted"* ]] \
  && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]] && [[ "$done_rows_after" -eq 4 ]]; then
  ok "s30 (D): a done list that cannot be rewritten: the rows the children appended stay, [could not rewrite the done list] prints, exit 4"
else
  bad "s30: status=$STATUS wrangler=$WR_CALLS rows=$done_rows_after err=[$ERR] out=[$OUT]"
fi

# s31 (E). nothing to process at all: the keys file is empty. That is the ordinary state of a bucket
#          that is fully uploaded with nothing recorded yet, and it ends 0 with an empty stderr --
#          no count line and no unaccounted line. This case pins what the script already does.
fb_manifest nothing.png - -
fb_store
: > "$FB_KEYS"
run_fb s31
if [[ "$STATUS" -eq 0 ]] && [[ -z "$ERR" ]] && [[ "$OUT" == *"Keys to process: 0"* ]] \
  && [[ "$OUT" == *"Done. Uploaded keys recorded in"* ]] && [[ ! -e "$CALLS2" ]]; then
  ok "s31 (E): an empty keys file ends 0, with [Keys to process: 0] and nothing on stderr"
else
  bad "s31: status=$STATUS err=[$ERR] out=[$OUT]"
fi

# s31b. the same with two keys, both already recorded: the run uploads nothing and says nothing, and
#       the list keeps the rows it already had.
fb_keys good.png other.png
fb_store good.png other.png
fb_manifest good.png "/store/good.png" - other.png "/store/other.png" -
printf '%s\n' good.png other.png > "$TMP/root/.media-upload.done"
FB_KEEP_DONE=1
run_fb s31b PARALLEL=1
FB_KEEP_DONE=''
if [[ "$STATUS" -eq 0 ]] && [[ -z "$ERR" ]] && [[ "$WR_CALLS" -eq 0 ]] \
  && [[ "$OUT" == *"Keys to process: 2"* ]] \
  && [[ "$(cat "$TMP/root/.media-upload.done")" == "$(printf '%s\n' good.png other.png)" ]]; then
  ok "s31b: keys that are all recorded already end 0 with no stderr and no put"
else
  bad "s31b: status=$STATUS wrangler=$WR_CALLS err=[$ERR] done=[$(cat "$TMP/root/.media-upload.done")]"
fi

# ---------------------------------------------------------------------------
# s33..s35: a key that names a path instead of a file under the object directory. The key comes from
# the manifest or from the keys file, and the first thing a run does with it is build
# "$OBJECTS/$key" out of it, so the shape is refused there: it is a bad record, not a missing object,
# and it costs the run the same 4 a failed upload costs.
# ---------------------------------------------------------------------------

# s33. three keys of that shape beside a good one, with a fallback host configured: each says so
#      once, none of them reaches the store, the host or wrangler, and the good key still goes up.
fb_keys '../x.png' 'a/../b.png' '/etc/x' good.png
fb_store good.png
fb_manifest good.png "/store/good.png" -
run_fb s33 POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST" POKOIN_MEDIA_FALLBACK_OBJECTS="$REMOTE_OBJECTS"
err_last="$(printf '%s\n' "$ERR" | tail -1)"
DONE_ROWS="$(done_list | tr '\n' '|')"
for want_bad in '../x.png' 'a/../b.png' '/etc/x'; do
  if grep -Fq -- "invalid key (skipped): $want_bad" "$TMP/err2"; then
    ok "s33: the key [$want_bad] is refused with its own line"
  else
    bad "s33: no refusal line for [$want_bad]: err=[$ERR]"
  fi
done
if [[ "$STATUS" -eq 4 ]] && [[ "$OUT" == *"Keys to process: 4"* ]] \
  && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$SCP_CALLS" -eq 0 ]] && [[ "$WR_CALLS" -eq 1 ]] \
  && grep -q 'pokoin-test-media/good\.png' "$CALLS2" \
  && [[ "$err_last" == "$(line_for 3 'key failed to upload' 'keys failed to upload')" ]] \
  && [[ "$ERR" != *"skipped: no source"* ]] && [[ "$ERR" != *"unaccounted"* ]] \
  && [[ "$DONE_ROWS" == "good.png|" ]]; then
  ok "s33 (a): a key that is a path: no ssh, scp or store lookup for it, the good key uploaded, [$(line_for 3 'key failed to upload' 'keys failed to upload')] last, exit 4"
else
  bad "s33: status=$STATUS keys=[$(printf '%s\n' "$OUT" | head -1)] ssh=$SSH_CALLS scp=$SCP_CALLS wrangler=$WR_CALLS err_last=[$err_last] done=[$DONE_ROWS] err=[$ERR]"
fi

# s34. a keys file with a carriage return inside a key, which is what a file written on another
#      system holds: the control character is shown and never written out, the key is refused, and
#      the key beside it is accounted for.
fb_keys good.png $'cr\rfile.png'
fb_store good.png
fb_manifest good.png "/store/good.png" -
run_fb s34 PARALLEL=1
if [[ "$STATUS" -eq 4 ]] && grep -Fq -- 'invalid key (skipped): cr?file.png' "$TMP/err2" \
  && [[ "$OUT" == *"Keys to process: 2"* ]] && [[ "$SSH_CALLS" -eq 0 ]] \
  && [[ "$WR_CALLS" -eq 1 ]] && [[ "$ERR" != *"unaccounted"* ]] \
  && [[ "$(done_list)" == "good.png" ]] && printf '%s\n' "$ERR" | grep -vq $'\r'; then
  ok "s34 (b): a key with a carriage return: refused as [cr?file.png], the good key uploaded alone, exit 4"
else
  bad "s34: status=$STATUS keys=[$(printf '%s\n' "$OUT" | head -1)] ssh=$SSH_CALLS wrangler=$WR_CALLS done=[$(done_list)] err=[$ERR]"
fi

# s35. the validator itself, extracted from the script and called with the keys a line-based list
#      cannot hand it: a key with an embedded newline. The shapes the run must accept are called in
#      the same harness, so the refusal is not a catch-all.
awk '/^key_is_bad\(\) \{/,/^\}$/' "$SRC" > "$TMP/key_is_bad.sh"
if [[ ! -s "$TMP/key_is_bad.sh" ]]; then
  bad "s35: no key_is_bad function was found in $SRC to extract"
else
  cat > "$TMP/key-cases.bash" <<'HARNESS'
#!/usr/bin/env bash
set +e
# shellcheck disable=SC1090
source "$1"
problems=0
# key_case <name> <want status> <want line or -> <key>
key_case() {
  local name="$1" want_status="$2" want_line="$3" key="$4" got_line got_status
  got_line="$(key_is_bad "$key" 2>&1 >/dev/null)"
  got_status=$?
  if [[ "$got_status" -ne "$want_status" ]]; then
    echo "FAIL: $name: status $got_status, expected $want_status"
    problems=$((problems + 1))
    return
  fi
  if [[ "$want_line" == "-" ]]; then
    if [[ -n "$got_line" ]]; then
      echo "FAIL: $name: it printed [$got_line] on a key it must accept"
      problems=$((problems + 1))
    fi
    return
  fi
  if [[ "$got_line" != "$want_line" ]]; then
    echo "FAIL: $name: line [$got_line], expected [$want_line]"
    problems=$((problems + 1))
    return
  fi
  echo "ok: $name"
}
key_case 'a key above the store' 1 '-' 'a.png'
key_case 'a key in a folder of the store' 1 '-' 'figure-masks-whole/v1.webp'
key_case 'a key whose name starts with a dash' 1 '-' '-c.png'
key_case 'a key with single dots in it' 1 '-' 'a.b.c.png'
# item A: two dots inside a name are part of the name. A parent step is one component of its own, and
# only such a component is a step above the store.
key_case 'a key whose name holds two dots' 1 '-' 'a..b.png'
key_case 'a key whose name holds two dots and a folder' 1 '-' 'x/a..b.png'
key_case 'a key between two dots' 1 '-' 'v1..v2.webp'
key_case 'a key that is only two dots' 0 'invalid key (skipped): ..' '..'
key_case 'a key that ends in a parent step' 0 'invalid key (skipped): x/..' 'x/..'
key_case 'a key that reaches above the store' 0 'invalid key (skipped): ../x.png' '../x.png'
key_case 'a key with a parent step inside it' 0 'invalid key (skipped): a/../b.png' 'a/../b.png'
key_case 'a key that is an absolute path' 0 'invalid key (skipped): /etc/x' '/etc/x'
key_case 'a key with an embedded newline' 0 'invalid key (skipped): a?b.png' $'a\nb.png'
key_case 'a key with an embedded carriage return' 0 'invalid key (skipped): a?b.png' $'a\rb.png'
key_case 'a key with an embedded tab' 0 'invalid key (skipped): a?b.png' $'a\tb.png'
[[ "$problems" -eq 0 ]] && echo 'all passed'
exit "$problems"
HARNESS
  kfail=0
  kout="$(bash "$TMP/key-cases.bash" "$TMP/key_is_bad.sh" 2>&1)" || kfail=1
  if [[ "$kfail" -eq 0 ]] && [[ "$kout" == *"all passed"* ]]; then
    while IFS= read -r line; do
      [[ "$line" == 'ok: '* ]] && ok "key validator: ${line#ok: }"
    done <<< "$kout"
  else
    printf '%s\n' "$kout"
    bad "s35: the extracted key validator did not hold the contract (rc=$kfail)"
  fi
fi

# s36 (item A). two dots inside a name are part of the name: three keys of that shape, one of them in
#               a folder of the store, go up like any other key. The fallback host is set so that a
#               refusal would also show as a store lookup and an ssh call the run must not make.
fb_keys 'a..b.png' 'v1..v2.webp' 'x/a..b.png' good.png
fb_store 'a..b.png' 'v1..v2.webp' 'x/a..b.png' good.png
fb_manifest 'a..b.png' "/store/a..b.png" - 'v1..v2.webp' "/store/v1..v2.webp" - \
  'x/a..b.png' "/store/x/a..b.png" - good.png "/store/good.png" -
run_fb s36 POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST" POKOIN_MEDIA_FALLBACK_OBJECTS="$REMOTE_OBJECTS"
if [[ "$STATUS" -eq 0 ]] && [[ "$OUT" == *"Keys to process: 4"* ]] \
  && [[ "$WR_CALLS" -eq 4 ]] && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$SCP_CALLS" -eq 0 ]] \
  && [[ "$ERR" != *"invalid key"* ]] && [[ "$ERR" != *"unaccounted"* ]] \
  && [[ "$(done_list | sort | tr '\n' '|')" == "a..b.png|good.png|v1..v2.webp|x/a..b.png|" ]]; then
  ok "s36 (item A): [a..b.png], [v1..v2.webp] and [x/a..b.png] are names and not parent steps: 4 keys, 4 uploads, exit 0"
else
  bad "s36: status=$STATUS keys=[$(printf '%s\n' "$OUT" | head -1)] wrangler=$WR_CALLS ssh=$SSH_CALLS done=[$(done_list | tr '\n' '|')] err=[$ERR]"
fi

# s37 (item B). a key that names nothing is no key: the workers take no blank argument, so a run that
#               counted one would hand out a name it could never get a record for. The keys file already
#               ignores a blank line, and a line of blanks alone is what the strip of the leading blanks
#               turns into nothing -- the count and the work must say the same thing about it.
fb_keys '   ' '' good.png
fb_store good.png
fb_manifest good.png "/store/good.png" -
run_fb s37 PARALLEL=1
if [[ "$STATUS" -eq 0 ]] && [[ "$OUT" == *"Keys to process: 1"* ]] \
  && [[ "$WR_CALLS" -eq 1 ]] && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$ERR" != *"unaccounted"* ]] \
  && [[ "$ERR" != *"invalid key"* ]] && [[ "$(done_list)" == "good.png" ]]; then
  ok "s37 (item B): a blank-only line and an empty line of the keys file are no keys: 1 to process, one upload, exit 0"
else
  bad "s37: status=$STATUS first_out=[$(printf '%s\n' "$OUT" | head -1)] wrangler=$WR_CALLS done=[$(done_list)] err=[$ERR]"
fi

# s37b (item B). the same empty key coming from the manifest, where no line filter runs first: the row
#                is there, the strip leaves it with no name, and the list the run counts is the list it
#                hands out. It goes with the duplicates, before anything counts a key.
fb_manifest '  ' "/store/none.png" - good.png "/store/good.png" -
fb_store good.png
run_fb s37b PARALLEL=1 KEYS_FILE=
if [[ "$STATUS" -eq 0 ]] && [[ "$OUT" == *"Keys to process: 1"* ]] \
  && [[ "$WR_CALLS" -eq 1 ]] && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$ERR" != *"unaccounted"* ]] \
  && [[ "$ERR" != *"invalid key"* ]] && [[ "$(done_list)" == "good.png" ]]; then
  ok "s37b (item B): a manifest row with an empty key is dropped before the list is counted: 1 to process, exit 0"
else
  bad "s37b: status=$STATUS first_out=[$(printf '%s\n' "$OUT" | head -1)] wrangler=$WR_CALLS ssh=$SSH_CALLS done=[$(done_list)] err=[$ERR]"
fi

# s37c (item B). the empty key alone in the file is nothing to do, not a failure and not a key: the run
#                that uploads nothing and says nothing ends 0, as the empty keys file does (s31).
fb_keys '   '
fb_store
fb_manifest good.png "/store/good.png" -
run_fb s37c PARALLEL=1
if [[ "$STATUS" -eq 0 ]] && [[ "$OUT" == *"Keys to process: 0"* ]] \
  && [[ "$WR_CALLS" -eq 0 ]] && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$ERR" == "" ]]; then
  ok "s37c (item B): a keys file that holds one blank line only is a run with nothing to do: 0 keys, exit 0, nothing on stderr"
else
  bad "s37c: status=$STATUS first_out=[$(printf '%s\n' "$OUT" | head -1)] wrangler=$WR_CALLS err=[$ERR]"
fi

# s38 (item C). an alias target is a key like any other, and the child builds a path out of it once the
#               requested key is not on the store: a target that is a path above the store is refused
#               where a key of its own would be, before that path is built, before the store or the host
#               is asked for it, and the requested key is a failed key rather than a missing one. The
#               good alias beside it goes on working.
fb_keys bad1.png good1.png
fb_store present.png
fb_manifest bad1.png "/store/bad1.png" - good1.png "/store/good1.png" -
FB_ALIASES='{"bad1.png":"../x.png","good1.png":"present.png"}'
# the host holds neither key, so both fall through to the alias map and the only thing left to see is
# what the run asks the host about for a target
SSH_MISS='.png'
run_fb s38 POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST" POKOIN_MEDIA_FALLBACK_OBJECTS="$REMOTE_OBJECTS"
FB_ALIASES=''
SSH_MISS=''
err_last="$(printf '%s\n' "$ERR" | tail -1)"
if [[ "$STATUS" -eq 4 ]] && grep -Fq -- 'invalid key (skipped): ../x.png' "$TMP/err2" \
  && [[ "$SSH_CALLS" -eq 2 ]] && [[ "$SCP_CALLS" -eq 0 ]] && [[ "$WR_CALLS" -eq 1 ]] \
  && grep -q 'pokoin-test-media/good1\.png' "$CALLS2" \
  && [[ "$err_last" == "$(line_for 1 'key failed to upload' 'keys failed to upload')" ]] \
  && [[ "$ERR" != *"skip (no source or alias)"* ]] && [[ "$ERR" != *"unaccounted"* ]] \
  && [[ "$(done_list)" == "good1.png" ]]; then
  ok "s38 (item C): an alias target that is a path: refused, the host asked once per requested key and never for the target, [$(line_for 1 'key failed to upload' 'keys failed to upload')] and exit 4"
else
  bad "s38: status=$STATUS ssh=$SSH_CALLS scp=$SCP_CALLS wrangler=$WR_CALLS last=[$err_last] done=[$(done_list)] calls=[$(tr '\n' '|' < "$CALLS2" 2>/dev/null)] err=[$ERR]"
fi

# s38b (item C). a target with a parent step inside it is the same refusal, and a name under the store
#                is untouched by it: the check is on the shape of the target, not on the alias path
fb_keys bad1.png good1.png
fb_store present.png
fb_manifest bad1.png "/store/bad1.png" - good1.png "/store/good1.png" -
FB_ALIASES='{"bad1.png":"a/../b.png","good1.png":"present.png"}'
SSH_MISS='.png'
run_fb s38b POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST" POKOIN_MEDIA_FALLBACK_OBJECTS="$REMOTE_OBJECTS"
FB_ALIASES=''
SSH_MISS=''
if [[ "$STATUS" -eq 4 ]] && [[ "$SSH_CALLS" -eq 2 ]] && [[ "$SCP_CALLS" -eq 0 ]] \
  && [[ "$WR_CALLS" -eq 1 ]] && grep -Fq -- 'invalid key (skipped): a/../b.png' "$TMP/err2" \
  && [[ "$(done_list)" == "good1.png" ]]; then
  ok "s38b (item C): a target with a parent step inside it is refused the same way, one step before any lookup"
else
  bad "s38b: status=$STATUS ssh=$SSH_CALLS scp=$SCP_CALLS wrangler=$WR_CALLS done=[$(done_list)] err=[$ERR]"
fi

# s39 (item D). the remote test is one command line, and the shell that reads it is on the other
#               machine: a key with a space in it is two words there, a quote in it closes the command
#               and everything after it is whatever the key says, and a star is a list of files. The path
#               goes over as one quoted word -- not with bash's own quoting, because the shell behind ssh
#               is the login shell of a machine this run knows nothing about.
# The words are spelled here, not recomputed, so a case cannot pass by agreeing with the same
# construction twice. A name holding a single quote is not in the table: xargs reads the quotes of its own
# input before the key reaches a child, so such a key never arrives to be quoted at all (s39b builds the
# word itself). The rows are pairs of lines -- a key, then the one line the host has to be handed for it --
# because a key may hold any delimiter a table would use.
while read -r d1_key; do
  read -r d1_want
  fb_keys "$d1_key"
  fb_store
  fb_manifest "$d1_key" "/store/$d1_key" -
  run_fb s39 POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST" POKOIN_MEDIA_FALLBACK_OBJECTS="$REMOTE_OBJECTS"
  d1_got="$(tail -1 "$SSH_LOG" 2>/dev/null || printf '(no call)')"
  if [[ "$SSH_CALLS" -eq 1 ]] && [[ "$d1_got" == "$d1_want" ]] && [[ "$STATUS" -eq 0 ]] \
    && [[ "$WR_CALLS" -eq 1 ]]; then
    ok "s39 (item D): the key [$d1_key] reaches the host as the one word [$d1_got]"
  else
    bad "s39: key=[$d1_key] status=$STATUS ssh=$SSH_CALLS wrangler=$WR_CALLS got=[$d1_got] want=[$d1_want] err=[$ERR]"
  fi
done <<'D1CASES'
my card.png
test -f '/remote/objects/my card.png'
a*b.png
test -f '/remote/objects/a*b.png'
a$(x).png
test -f '/remote/objects/a$(x).png'
a;b.png
test -f '/remote/objects/a;b.png'
a|b.png
test -f '/remote/objects/a|b.png'
a`x`.png
test -f '/remote/objects/a`x`.png'
a[b].png
test -f '/remote/objects/a[b].png'
D1CASES

# s39b (item D). the helper on its own, extracted from the script, for the name xargs cannot hand over:
#                the quote a key holds has to leave a word that the far shell reads as that one name.
awk '/^remote_word\(\) \{/,/^\}$/' "$SRC" > "$TMP/remote_word.sh"
if [[ ! -s "$TMP/remote_word.sh" ]]; then
  bad "s39b: no remote_word function was found in $SRC to extract"
else
  cat > "$TMP/word-cases.bash" <<'HARNESS'
#!/usr/bin/env bash
set +e
# shellcheck disable=SC1090
source "$1"
problems=0
word_case() {
  local name="$1" want="$2" path="$3" got
  got="$(remote_word "$path")"
  if [[ "$got" != "$want" ]]; then
    echo "FAIL: $name: word [$got], expected [$want]"
    problems=$((problems + 1))
    return
  fi
  # the word is read back by a plain shell: what comes out has to be the path, exactly once
  local -a read_back=()
  mapfile -t read_back < <(eval "set -- $got; printf '%s\n' \"\$@\"")
  if [[ "${#read_back[@]}" -ne 1 || "${read_back[0]}" != "$path" ]]; then
    echo "FAIL: $name: a shell reads it as ${#read_back[@]} word(s) [${read_back[*]}], expected the path alone"
    problems=$((problems + 1))
    return
  fi
  echo "ok: $name"
}
word_case 'a name with a blank in it' "'/remote/objects/my card.png'" '/remote/objects/my card.png'
word_case 'a name with a quote in it' "'/remote/objects/it'\\''s.png'" "/remote/objects/it's.png"
word_case 'a name with a star in it' "'/remote/objects/a*b.png'" '/remote/objects/a*b.png'
word_case 'a name with a substitution in it' "'/remote/objects/a\$(x).png'" '/remote/objects/a$(x).png'
word_case 'a name with two quotes in it' "'/remote/objects/a'\\''b'\\''c.png'" "/remote/objects/a'b'c.png"
[[ "$problems" -eq 0 ]] && echo 'all passed'
exit "$problems"
HARNESS
  wfail=0
  wout="$(bash "$TMP/word-cases.bash" "$TMP/remote_word.sh" 2>&1)" || wfail=1
  if [[ "$wfail" -eq 0 ]] && [[ "$wout" == *"all passed"* ]]; then
    while IFS= read -r line; do
      [[ "$line" == 'ok: '* ]] && ok "remote word: ${line#ok: }"
    done <<< "$wout"
  else
    printf '%s\n' "$wout"
    bad "s39b: the extracted remote-word helper did not hold the contract (rc=$wfail)"
  fi
fi

# s3o (item D). the remote directory is validated where the host is: it has to be an absolute path of
#              plain characters, no parent step in it and nothing after its name, because it is put in
#              front of every key the run asks the host for.
want_invalid_objects_line="invalid POKOIN_MEDIA_FALLBACK_OBJECTS"
for bad_dir in '/remote obj' "/remote/obj's" '/remote/$(x)' '/remote/`x`' '/remote/*' '/remote/a?b' \
  '/remote/;id' '/remote/a|b' '/remote/../objects' '/remote/objects/..' '..' 'remote/objects' \
  '/remote/objects ' '/remote/objects/a b'; do
  run_fb s3o POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST" POKOIN_MEDIA_FALLBACK_OBJECTS="$bad_dir"
  if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "$want_invalid_objects_line" ]] \
    && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$SCP_CALLS" -eq 0 ]] && [[ "$WR_CALLS" -eq 0 ]]; then
    ok "s3o (item D): remote directory [$bad_dir]: exit 2, only [$want_invalid_objects_line], no ssh, scp or wrangler call"
  else
    bad "s3o: value=[$bad_dir] status=$STATUS ssh=$SSH_CALLS scp=$SCP_CALLS wrangler=$WR_CALLS err=[$ERR]"
  fi
done

# s3p (item D). the shapes that are a directory of plain characters go through and are used as given
for good_dir in '/remote/objects' '/remote/obj-1' '/remote/obj_2' '/remote/a@b' '/remote/c+d' '/remote/v1.2'; do
  fb_keys b.png
  fb_store
  fb_manifest b.png "/store/b.png" -
  run_fb s3p POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST" POKOIN_MEDIA_FALLBACK_OBJECTS="$good_dir"
  if [[ "$STATUS" -eq 0 ]] && [[ "$SSH_CALLS" -eq 1 ]] && [[ "$SCP_CALLS" -eq 1 ]] \
    && [[ "$ERR" != *"$want_invalid_objects_line"* ]] && grep -Fq -- "$good_dir/b.png" "$SSH_LOG"; then
    ok "s3p (item D): the remote directory [$good_dir] is accepted, and the key is asked for under it"
  else
    bad "s3p: value=[$good_dir] status=$STATUS ssh=$SSH_CALLS scp=$SCP_CALLS log=[$(tr '\n' '|' < "$SSH_LOG" 2>/dev/null)] err=[$ERR]"
  fi
done

# s3q (item D). a value that cannot be a directory is a typo whatever the host says, so it is refused
#              with no host set too; an empty one stays the unset it always was (s3g)
run_fb s3q POKOIN_MEDIA_FALLBACK_HOST= POKOIN_MEDIA_FALLBACK_OBJECTS='/remote/*'
if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "$want_invalid_objects_line" ]] \
  && [[ "$SSH_CALLS" -eq 0 ]]; then
  ok "s3q (item D): with no host set an unusable remote directory is still refused, and an empty one is not (s3g)"
else
  bad "s3q: status=$STATUS ssh=$SSH_CALLS err=[$ERR]"
fi

# s0j/s0k (item D). the order: the host first, then its directory being asked for, then its shape, then
#              the local store. Each run below is missing more than one thing and names the first.
run_objects s0j "" POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST" POKOIN_MEDIA_FALLBACK_OBJECTS='/remote/*'
if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "$want_invalid_objects_line" ]] \
  && [[ "$ERR" != *"$want_objects_line"* ]] && [[ "$FORB_NOW" -eq "$FORB_BEFORE" ]]; then
  ok "s0j: the shape of the remote directory is refused before the local store is asked for"
else
  bad "s0j: status=$STATUS err=[$ERR]"
fi
run_objects s0k "" POKOIN_MEDIA_FALLBACK_HOST='-oProxyCommand=x' POKOIN_MEDIA_FALLBACK_OBJECTS='/remote/*'
if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "invalid POKOIN_MEDIA_FALLBACK_HOST" ]]; then
  ok "s0k: an unusable host is still the first thing refused, before the directory that belongs to it"
else
  bad "s0k: status=$STATUS err=[$ERR]"
fi
run_objects s0l "" POKOIN_MEDIA_FALLBACK_HOST="$FB_HOST" POKOIN_MEDIA_FALLBACK_OBJECTS=
if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "$want_fallback_objects_line" ]]; then
  ok "s0l: a directory that is missing is asked for, not called invalid: the two lines stay apart"
else
  bad "s0l: status=$STATUS err=[$ERR] want=[$want_fallback_objects_line]"
fi

# s12. the repository-wide check runs as a step of this suite, so its failure fails the suite
hfail=0
hout="$(bash "$HERE/no-host-names.test.sh" 2>&1)" || hfail=1
if [[ "$hfail" -eq 0 ]] && [[ "$hout" == *"all passed"* ]]; then
  ok "s12: scripts/no-host-names.test.sh passes and is a step of this suite"
else
  bad "s12: scripts/no-host-names.test.sh failed (rc=$hfail): $(printf '%s\n' "$hout" | grep -v '^ok: ' | head -5)"
fi

# s32. the manifest guard runs as a step of this suite for the same reason: the generator it checks is
#      the one that writes the media-manifest.json this suite reads
gfail=0
gout="$(bash "$HERE/media-manifest-guard.test.sh" 2>&1)" || gfail=1
if [[ "$gfail" -eq 0 ]] && [[ "$gout" == *"all passed"* ]]; then
  ok "s32: scripts/media-manifest-guard.test.sh passes and is a step of this suite"
else
  bad "s32: scripts/media-manifest-guard.test.sh failed (rc=$gfail): $(printf '%s\n' "$gout" | grep -v '^ok: ' | head -5)"
fi

if [[ -e "$TMP/forbidden.calls" ]]; then
  bad "ssh/scp stub was called: $(cat "$TMP/forbidden.calls")"
fi

# the manifest of the repository is left exactly as HEAD has it
guard_manifest || fail=1

if [[ "$fail" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "all passed"
