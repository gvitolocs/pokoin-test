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

mkdir -p "$TMP/root/scripts" "$TMP/stubs" "$TMP/objects"
cp "$SRC" "$TMP/root/scripts/upload-media-r2.sh"
printf "{\"entries\":[{\"key\":\"a.png\"}]}\n" > "$TMP/root/media-manifest.json"
printf "{}\n" > "$TMP/root/media-aliases.json"
printf "x" > "$TMP/objects/a.png"
printf "a.png\n" > "$TMP/keys.txt"

CALLS="$TMP/wrangler.calls"
cat > "$TMP/stubs/wrangler" <<STUB
#!/bin/sh
if [ -n "\${CLOUDFLARE_API_TOKEN:-}" ]; then s=token-set; else s=token-unset; fi
echo "\$s \$*" >> "$CALLS"
STUB
printf "#!/bin/sh\nexit 0\n" > "$TMP/stubs/node"
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
  set +e
  env -i PATH="$TMP/stubs:/usr/bin:/bin" HOME="$home" TMPDIR="$TMP" \
    WRANGLER="$TMP/stubs/wrangler" POKOIN_OBJECTS="$TMP/objects" KEYS_FILE="$TMP/keys.txt" \
    "$@" bash "$TMP/root/scripts/upload-media-r2.sh" >"$TMP/out" 2>"$TMP/err"
  STATUS=$?
  set -e
  ERR="$(cat "$TMP/err")"
}

mk_home() { mkdir -p "$TMP/$1/.config/pokoin"; echo "$TMP/$1"; }

expect_preflight() {
  local name="$1"
  if [[ "$STATUS" -eq 1 ]] \
    && [[ "$ERR" == *CLOUDFLARE_API_TOKEN*CLOUDFLARE_ACCOUNT_ID* ]] \
    && [[ "$ERR" != *"unbound variable"* ]] \
    && [[ ! -e "$CALLS" ]]; then
    ok "$name: preflight message, exit 1, wrangler not called"
  else
    bad "$name: status=$STATUS err=[$ERR] calls=$(cat "$CALLS" 2>/dev/null || true)"
  fi
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
expect_preflight b

# c. credentials file with a syntax error and no valid assignments
H="$(mk_home home-c)"
printf "if then fi ((( \"unterminated\n" > "$H/.config/pokoin/cloudflare.env"
run_case c "$H"
expect_preflight c

# d. LANE_WORKER set: file is not loaded
H="$(mk_home home-d)"
printf "CLOUDFLARE_API_TOKEN=%s\nCLOUDFLARE_ACCOUNT_ID=%s\n" "$DUMMY_TOKEN" "$DUMMY_ACCOUNT" > "$H/.config/pokoin/cloudflare.env"
run_case d "$H" LANE_WORKER=1
expect_preflight d

if [[ -e "$TMP/forbidden.calls" ]]; then
  bad "ssh/scp stub was called: $(cat "$TMP/forbidden.calls")"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "all passed"
