#!/usr/bin/env bash
# Tests for scripts/media-manifest-guard.mjs, the check the manifest generator runs on its own
# output before it writes the file, and for the two rules scripts/media-manifest.mjs holds so that
# the file it writes names neither a directory nor a host: the object directory comes from the
# environment with no default in the tree, and the object column holds a key.
#
# The generator is never run and never imported. Importing it reaches the live catalog, so every
# statement about it here is read out of its text, and the only module any process imports is the
# guard, which holds no side effect. That import runs behind a fetch stub that fails the test the
# moment anything is asked of the network.
#
# Usage: bash scripts/media-manifest-guard.test.sh
set -euo pipefail

HERE="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
GUARD="${HERE}/media-manifest-guard.mjs"
GEN="${HERE}/media-manifest.mjs"
UPLOAD="${HERE}/upload-media-r2.sh"
WANT_DIR_LINE="set POKOIN_OBJECTS to the directory that holds the media objects"
WANT_HOST_LINE="refusing to write a manifest that names the fallback host"

fail=0
ok() { echo "ok: $1"; }
bad() { echo "FAIL: $1"; fail=1; }

TMP="$(mktemp -d "${TMPDIR:-/var/tmp}/media-manifest-guard-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

# first_line <file> <fixed string>: the number of the first line that holds it, 0 when none does
first_line() {
  local n=''
  n="$(grep -F -n -- "$2" "$1" 2> /dev/null | head -1 | cut -d: -f1 || true)"
  printf '%s' "${n:-0}"
}
# holds <file> <fixed string>: does the file carry this text at all
holds() {
  grep -F -q -- "$2" "$1"
}

for f in "$GUARD" "$GEN" "$UPLOAD"; do
  if [[ ! -f "$f" ]]; then
    bad "missing file under test: $f"
    echo "FAILED"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 1. assertNoHost, imported and called for itself. No generator, no network.
# ---------------------------------------------------------------------------
cat > "$TMP/assert-no-host.mjs" <<'NODE'
import { pathToFileURL } from 'node:url';

const [guardPath, want] = process.argv.slice(2);
const net = { calls: 0 };
// whatever the guard module does on import, it may not ask the network or run a process
globalThis.fetch = () => {
  net.calls += 1;
  throw new Error('the guard reached the network');
};

const HOST = 'fallback.example.invalid';
const CLEAN = '{"entries":[{"key":"a.png","object":"a.png"}]}\n';
const DIRTY = `{"entries":[{"key":"a.png","object":"ssh:${HOST}:/store/a.png"}]}\n`;

const mod = await import(pathToFileURL(guardPath).href);
if (typeof mod.assertNoHost !== 'function') {
  console.log(`FAIL: assertNoHost is ${typeof mod.assertNoHost}, not a function`);
  process.exit(1);
}
const { assertNoHost } = mod;

const problems = [];
const expectThrow = (name, text, host) => {
  let thrown = null;
  try {
    assertNoHost(text, host);
  } catch (e) {
    thrown = e;
  }
  if (!thrown) problems.push(`${name}: it accepted the text instead of throwing`);
  else if (thrown.message !== want) problems.push(`${name}: it threw [${thrown.message}] instead of [${want}]`);
  else console.log(`${name}: throws with exactly that line`);
};
const expectPass = (name, text, host) => {
  try {
    assertNoHost(text, host);
    console.log(`${name}: accepts the text`);
  } catch (e) {
    problems.push(`${name}: it threw [${e.message}] on text it must accept`);
  }
};

expectThrow('the host in the text', DIRTY, HOST);
expectThrow('the host twice over', DIRTY + DIRTY, HOST);
expectThrow('a host that is only the prefix of a key', `{"object":"${HOST}.txt"}`, HOST);
expectPass('the clean manifest', CLEAN, HOST);
// no host configured is no check: an empty needle is inside every string, so a naive includes()
// would refuse every manifest there is
expectPass('an empty host', DIRTY, '');
expectPass('an unset host', DIRTY, undefined);
expectPass('a host that never appears', CLEAN, 'other.example.invalid');
// a directory is not this function's business: keeping paths out of the tree is the job of
// scripts/no-host-names.test.sh, which runs over every tracked file
expectPass('a path that is not the host', '{"object":"/srv/store/a.png"}', HOST);
expectPass('no host argument at all', CLEAN);

if (net.calls !== 0) problems.push(`the guard module reached the network ${net.calls} time(s)`);
else console.log('importing and calling the guard asks the network nothing');

if (problems.length) {
  console.log(problems.map((p) => `FAIL: ${p}`).join('\n'));
  process.exit(1);
}
console.log('all passed');
NODE

node_rc=0
node_out="$(node "$TMP/assert-no-host.mjs" "$GUARD" "$WANT_HOST_LINE" 2>&1)" || node_rc=$?
if [[ "$node_rc" -eq 0 ]] && [[ "$node_out" == *"all passed"* ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && ok "assertNoHost: $line"
  done <<< "$node_out"
else
  printf '%s\n' "$node_out"
  bad "assertNoHost: the module did not hold the contract (rc $node_rc)"
fi

# the two modules parse, which is as far as node is allowed to go with the generator
if node --check "$GUARD"; then ok "node --check parses the guard module"; else bad "node --check failed on $GUARD"; fi
if node --check "$GEN"; then ok "node --check parses the generator"; else bad "node --check failed on $GEN"; fi

# ---------------------------------------------------------------------------
# 2. What the generator must say, read out of its text: it is never run.
# ---------------------------------------------------------------------------
# g1. the object directory comes from the environment, and the tree holds no default for it
assign="$(grep -E '^const LOCAL_OBJECTS' "$GEN" | head -1 || true)"
if [[ -z "$assign" ]]; then
  bad "g1: no LOCAL_OBJECTS declaration was found in the generator"
elif [[ "$assign" != *'process.env.POKOIN_OBJECTS'* ]]; then
  bad "g1: LOCAL_OBJECTS is not read from POKOIN_OBJECTS: $assign"
elif [[ "$assign" == */* ]]; then
  bad "g1: the line that reads the directory still holds a path: $assign"
else
  ok "g1: LOCAL_OBJECTS comes from the environment with no default in the tree"
fi

# g2. an unset directory ends the run before anything is asked of the network
dir_check="$(first_line "$GEN" "$WANT_DIR_LINE")"
first_fetch="$(first_line "$GEN" 'fetch(')"
main_call="$(first_line "$GEN" 'main().catch')"
if [[ "$dir_check" == "0" || "$first_fetch" == "0" || "$main_call" == "0" ]]; then
  bad "g2: the directory check, a fetch or the main call was not found (check=$dir_check fetch=$first_fetch main=$main_call)"
elif (( dir_check < first_fetch && dir_check < main_call )); then
  ok "g2: the directory check (line $dir_check) is ahead of the first fetch (line $first_fetch) and of main (line $main_call)"
else
  bad "g2: the directory check on line $dir_check is not ahead of the fetch on line $first_fetch"
fi

# g3. the check exits 2, on the line that follows the message, and prints it as an error
msg_line="$(sed -n "${dir_check}p" "$GEN")"
next_line="$(sed -n "$((dir_check + 1))p" "$GEN")"
if [[ "$msg_line" != *'console.error'* ]]; then
  bad "g3: the message does not go to stderr: [$msg_line]"
elif [[ "$next_line" != *'process.exit(2)'* ]]; then
  bad "g3: the line after the message is [$next_line], not an exit 2"
else
  ok "g3: an unset directory is printed on stderr and exits 2"
fi

# g4. one variable, one wording: the upload script prints the same line
if holds "$UPLOAD" "$WANT_DIR_LINE"; then
  ok "g4: the generator and the upload script print the same line for the same missing value"
else
  bad "g4: the upload script no longer prints [$WANT_DIR_LINE]"
fi

# g5. the fallback host validation still comes before the directory check in both files
for order_file in "$GEN" "$UPLOAD"; do
  host_line="$(first_line "$order_file" 'invalid POKOIN_MEDIA_FALLBACK_HOST')"
  own_dir="$(first_line "$order_file" "$WANT_DIR_LINE")"
  if [[ "$host_line" == "0" || "$own_dir" == "0" ]]; then
    bad "g5: $(basename "$order_file") is missing one of the two checks (host=$host_line dir=$own_dir)"
  elif (( host_line < own_dir )); then
    ok "g5: $(basename "$order_file") validates the host (line $host_line) before it asks for the directory (line $own_dir)"
  else
    bad "g5: in $(basename "$order_file") the host line is at $host_line and the directory check at $own_dir"
  fi
done

# g6. the object column is written as a key, not as the path the generator read
if holds "$GEN" 'object: resolved.path || null'; then
  bad "g6: the generator still writes the path it read into the object column"
elif grep -q -E 'object:[[:space:]]*resolved\.[a-zA-Z]+[[:space:]]*\|\|[[:space:]]*null' "$GEN"; then
  ok "g6: the object column is written from the resolved row field: $(grep -E -o 'object: [^,]*' "$GEN" | head -1)"
else
  bad "g6: no object assignment from a resolved field was found in the generator"
fi
if printf '%s\n' "$(grep -E 'object:' "$GEN")" | grep -q 'LOCAL_OBJECTS'; then
  bad "g6: something built from the object directory reaches the object column"
else
  ok "g6: nothing built from the object directory reaches the object column"
fi
if holds "$GEN" 'ssh:' && grep -q -E 'object:.*ssh:' "$GEN"; then
  bad "g6: an ssh reference is written into the object column, which names the host"
else
  ok "g6: the object column never carries an ssh reference"
fi

# g7. the refusal is wired into the write: imported, called on the final string, before the write
if ! holds "$GEN" 'media-manifest-guard.mjs'; then
  bad "g7: the generator does not import the guard module"
else
  ok "g7: the generator imports the guard module"
  call_line="$(first_line "$GEN" 'assertNoHost(')"
  write_line="$(first_line "$GEN" 'writeFileSync(OUT')"
  if [[ "$call_line" == "0" || "$write_line" == "0" ]]; then
    bad "g7: the guard call ($call_line) or the write ($write_line) was not found"
  elif (( call_line < write_line )); then
    ok "g7: the guard runs on line $call_line, ahead of the write on line $write_line"
  else
    bad "g7: the guard runs after the file was written ($call_line vs $write_line)"
  fi
fi
refused="$(first_line "$GEN" "$WANT_HOST_LINE")"
if [[ "$refused" == "0" ]]; then
  bad "g7: the generator does not print [$WANT_HOST_LINE]"
elif [[ "$(sed -n "$((refused + 1))p" "$GEN")" != *'process.exit(1)'* ]]; then
  bad "g7: the line after the refusal is not an exit 1: [$(sed -n "$((refused + 1))p" "$GEN")]"
else
  ok "g7: the refusal prints its line on stderr and exits 1"
fi

# g8. the file is written from exactly one statement, so a refusal cannot be routed around
write_n="$(grep -c -E 'writeFileSync\(OUT' "$GEN" || true)"
if [[ "$write_n" == "1" ]]; then
  ok "g8: OUT is written from exactly one statement, which the guard stands in front of"
else
  bad "g8: OUT is written from $write_n statements, expected exactly 1"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "all passed"
