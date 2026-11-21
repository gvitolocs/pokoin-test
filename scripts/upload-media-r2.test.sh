#!/usr/bin/env bash
# Tests for scripts/upload-media-r2.sh credential loading and preflight.
# Runs a copy of the script under env -i with stub wrangler/node/ssh/scp and a temp HOME.
# Usage: bash scripts/upload-media-r2.test.sh [path-to-script-under-test]
set -euo pipefail

SRC="${1:-$(cd "$(dirname "$0")" && pwd)/upload-media-r2.sh}"
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

if [[ -e "$TMP/forbidden.calls" ]]; then
  bad "ssh/scp stub was called: $(cat "$TMP/forbidden.calls")"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "all passed"
