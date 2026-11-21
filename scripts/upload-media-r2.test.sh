#!/usr/bin/env bash
# Tests for scripts/upload-media-r2.sh: credential loading and preflight, the fallback host, the
# keys skipped for want of a source; and scripts/no-host-names.test.sh as one of its own steps.
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
  rm -rf -- "$TMP"
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

# i. the credentials file runs set +e: errexit stays on. The run reaches the upload (wrangler stub
#    called, no preflight text), and a failing node stub at the end stops the script before the
#    final line.
H="$(mk_home home-i)"
write_creds "$H" "set +e"
run_case i "$H" NODE_FAIL=1
if [[ "$STATUS" -ne 0 ]] && [[ -e "$CALLS" ]] && [[ "$ERR" != *"must be set"* ]] \
  && ! grep -q "^Done" "$TMP/out"; then
  ok "i: errexit still on after the credentials file ran set +e"
else
  bad "i: status=$STATUS err=[$ERR] out=[$(cat "$TMP/out")]"
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
# instead of the forbidden one above.
# ---------------------------------------------------------------------------
S2="$TMP/stubs-fallback"
mkdir -p "$S2" "$TMP/objects2" "$TMP/home-fb"
SSH_LOG="$TMP/ssh.args"
SCP_LOG="$TMP/scp.args"
CALLS2="$TMP/wrangler2.calls"
FB_KEYS="$TMP/keys2.txt"
FB_HOST="fallback.example.invalid"   # a dummy, and not a name that resolves
REMOTE_OBJECTS="/srv/pokoin/card-images/objects"   # PI_OBJECTS in the script under test
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
exit 0
STUB
cp "$S2/ssh" "$S2/scp"
# shellcheck disable=SC2016
cat > "$S2/node" <<'STUB'
#!/bin/sh
if [ "$1" = "-e" ]; then
  case "$2" in
    *"method: 'HEAD'"*) exit 0 ;;
  esac
fi
exec "$REAL_NODE" "$@"
STUB
cat > "$S2/wrangler" <<'STUB'
#!/bin/sh
printf '%s\n' "$*" >> "$CALLS2"
exit 0
STUB
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
  rm -f "$TMP/objects2"/*
  local k
  for k in "$@"; do printf x > "$TMP/objects2/$k"; done
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
# ERR, OUT and the number of ssh, scp and wrangler calls of the run
run_fb() {
  shift
  rm -f "$SSH_LOG" "$SCP_LOG" "$CALLS2" "$TMP/root/.media-upload.done"
  printf '%s\n' "${FB_ALIASES:-$FB_ALIASES_DEFAULT}" > "$TMP/root/media-aliases.json"
  set +e
  env -i PATH="$S2:/usr/bin:/bin" HOME="$TMP/home-fb" TMPDIR="$TMP/scratch" \
    CLOUDFLARE_API_TOKEN="$DUMMY_TOKEN" CLOUDFLARE_ACCOUNT_ID="$DUMMY_ACCOUNT" \
    WRANGLER="$S2/wrangler" POKOIN_OBJECTS="$TMP/objects2" KEYS_FILE="$FB_KEYS" \
    SSH_LOG="$SSH_LOG" SCP_LOG="$SCP_LOG" CALLS2="$CALLS2" REAL_NODE="$REAL_NODE" \
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
for bad_value in '-oProxyCommand=x' 'a b' 'x;id'; do
  run_fb s3 POKOIN_MEDIA_FALLBACK_HOST="$bad_value"
  if [[ "$STATUS" -eq 2 ]] && [[ "$ERR" == "invalid POKOIN_MEDIA_FALLBACK_HOST" ]] \
    && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$SCP_CALLS" -eq 0 ]] && [[ "$WR_CALLS" -eq 0 ]]; then
    ok "s3 (c): value [$bad_value]: exit 2, only that line on stderr, no ssh, scp or wrangler call"
  else
    bad "s3: value [$bad_value] status=$STATUS err=[$ERR] ssh=$SSH_CALLS scp=$SCP_CALLS wrangler=$WR_CALLS"
  fi
done
run_fb s3e POKOIN_MEDIA_FALLBACK_HOST=
if [[ "$STATUS" -eq 3 ]] && [[ "$SSH_CALLS" -eq 0 ]] && [[ "$ERR" != *"invalid"* ]] \
  && [[ "$ERR" == *"skip (no source): b.png"* ]]; then
  ok "s3 (c): an empty value means no fallback, not an invalid one"
else
  bad "s3e: status=$STATUS ssh=$SSH_CALLS err=[$ERR]"
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

# s12. the repository-wide check runs as a step of this suite, so its failure fails the suite
hfail=0
hout="$(bash "$HERE/no-host-names.test.sh" 2>&1)" || hfail=1
if [[ "$hfail" -eq 0 ]] && [[ "$hout" == *"all passed"* ]]; then
  ok "s12: scripts/no-host-names.test.sh passes and is a step of this suite"
else
  bad "s12: scripts/no-host-names.test.sh failed (rc=$hfail): $(printf '%s\n' "$hout" | grep -v '^ok: ' | head -5)"
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
