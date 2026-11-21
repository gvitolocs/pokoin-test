#!/usr/bin/env bash
# Tests for scripts/media-manifest-guard.mjs, the two checks the manifest generator runs on its own
# output before it writes the file -- that the text names no fallback host, and that no row holds a
# directory -- and for the two rules scripts/media-manifest.mjs holds so that the file it writes
# names neither a directory nor a host: the object directory comes from the environment with no
# default in the tree, and the object column holds a key.
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
WANT_REMOTE_LINE="set POKOIN_MEDIA_FALLBACK_OBJECTS to the remote directory that holds the media objects"
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
# 1b. assertNoLeaks, imported and called for itself: the check that keeps a directory out of the
#     file when no fallback host is configured, which is exactly the case assertNoHost skips. The
#     guard is the only module imported, behind the same stub that fails the test on a network call.
# ---------------------------------------------------------------------------
# The three shapes, assembled from fragments: a tracked file of this repository holds no account
# directory of its own, any more than the manifest it builds may hold one.
ACCOUNT_ROOT_ONE="/ho""me"
ACCOUNT_ROOT_TWO="/U""sers"
ACCOUNT_OWNER="some.owner"
LEAK_HOST="elsewhere.example.invalid"
LEAK_ABSOLUTE="/store/a.png"
LEAK_HOME_ONE="mnt${ACCOUNT_ROOT_ONE}/${ACCOUNT_OWNER}/a.png"
LEAK_HOME_TWO="mnt${ACCOUNT_ROOT_TWO}/${ACCOUNT_OWNER}/a.png"
LEAK_SSH="ssh:${LEAK_HOST}:/store/a.png"
# the wording of the refusal, with the two names the check fills in: never the offending value
WANT_LEAK_LINE="row KEY: field FIELD looks like a path"

cat > "$TMP/assert-no-leaks.mjs" <<'NODE'
import { pathToFileURL } from 'node:url';
import { readFileSync } from 'node:fs';

const [guardPath, wantLine, committedPath, absolute, homeOne, homeTwo, sshRef] = process.argv.slice(2);
const net = { calls: 0 };
globalThis.fetch = () => {
  net.calls += 1;
  throw new Error('the guard reached the network');
};
const wantFor = (key, field) => wantLine.replace('KEY', key).replace('FIELD', field);

const mod = await import(pathToFileURL(guardPath).href);
if (typeof mod.assertNoLeaks !== 'function') {
  console.log(`FAIL: assertNoLeaks is ${typeof mod.assertNoLeaks}, not a function`);
  process.exit(1);
}
if (typeof mod.assertNoHost !== 'function') {
  console.log('FAIL: assertNoHost is gone from the module');
  process.exit(1);
}
const { assertNoLeaks, assertNoHost } = mod;

const problems = [];
// row <key> with one string in that field; every other field of a real row stays out of the way
const rowWith = (key, field, value) => ({
  entries: [
    {
      key,
      sources: field === 'sources' ? [value] : ['public/review/x.json'],
      object: field === 'object' ? value : null,
      aliasOf: field === 'aliasOf' ? value : undefined,
      objectStore: 'local',
      size: 12,
      sha256: 'ab'.repeat(32),
    },
  ],
});
const expectLeak = (name, key, field, value, manifest) => {
  const want = wantFor(key, field);
  let thrown = null;
  try {
    assertNoLeaks(manifest);
  } catch (e) {
    thrown = e;
  }
  if (!thrown) {
    problems.push(`${name}: it accepted the manifest instead of throwing`);
    return;
  }
  if (thrown.message !== want) {
    problems.push(`${name}: it threw [${thrown.message}] instead of [${want}]`);
    return;
  }
  if (thrown.message.includes(value)) {
    problems.push(`${name}: the refusal printed the offending value`);
    return;
  }
  console.log(`${name}: throws with the key and the field, and no value`);
};
const expectClean = (name, manifest) => {
  try {
    assertNoLeaks(manifest);
    console.log(`${name}: accepts the manifest`);
  } catch (e) {
    problems.push(`${name}: it threw [${e.message}] on a manifest it must accept`);
  }
};

for (const [name, value] of [
  ['an absolute path', absolute],
  ['a home directory of the first account root', homeOne],
  ['a home directory of the second account root', homeTwo],
  ['an ssh reference', sshRef],
]) {
  expectLeak(`${name}, in the object column`, 'a.png', 'object', value, rowWith('a.png', 'object', value));
}
// the field is named, not assumed: the same shape in another column of the same row is refused too
expectLeak('an absolute path in a sources entry', 'a.png', 'sources', absolute, rowWith('a.png', 'sources', absolute));
expectLeak('an absolute path in the alias column', 'a.png', 'aliasOf', absolute, rowWith('a.png', 'aliasOf', absolute));
// the key of the row is what the refusal names, so a run says which row to look at
expectLeak('the row of a key that holds a slash', 'figure-masks-whole/v9.webp', 'object', homeOne,
  rowWith('figure-masks-whole/v9.webp', 'object', homeOne));

// a relative key is not a path, however many slashes it holds: this is the shape of the seven
// figure-masks-whole rows the committed manifest carries
expectClean('a key with a slash as the object column', {
  entries: [{ key: 'figure-masks-whole/v1.webp', sources: ['src/pages/a.jsx'], object: 'figure-masks-whole/v1.webp',
    objectStore: 'local', size: null, sha256: null }],
});
expectClean('a manifest with no rows', { entries: [] });
expectClean('a row of nulls and numbers', rowWith('a.png', 'object', null));

// the check runs on the manifest object and on the text that is about to become the file alike
expectLeak('the serialised text of a dirty row', 'a.png', 'object', absolute, JSON.stringify(rowWith('a.png', 'object', absolute), null, 2));
expectClean('the serialised text of a clean row', JSON.stringify(rowWith('a.png', 'object', 'a.png'), null, 2));

// the file the repository actually holds passes the check: read, never written, and the generator
// runs in no case of this suite
const committed = JSON.parse(readFileSync(committedPath, 'utf8'));
expectClean(`the committed manifest (${committed.entries.length} rows)`, committed);

// with no host configured assertNoHost refuses nothing, which is the hole this check closes
let hostSaid = '';
try {
  assertNoHost(JSON.stringify(rowWith('a.png', 'object', absolute)), undefined);
} catch (e) {
  hostSaid = e.message;
}
if (hostSaid) problems.push(`assertNoHost threw [${hostSaid}] on an unset host, which it must not`);
else console.log('an unset host is nothing for assertNoHost to keep out, and the leak check still refuses the row');

if (net.calls !== 0) problems.push(`the guard module reached the network ${net.calls} time(s)`);
else console.log('importing and calling the leak check asks the network nothing');

if (problems.length) {
  console.log(problems.map((p) => `FAIL: ${p}`).join('\n'));
  process.exit(1);
}
console.log('all passed');
NODE

node_rc=0
node_out="$(node "$TMP/assert-no-leaks.mjs" "$GUARD" "$WANT_LEAK_LINE" "${HERE}/../media-manifest.json" \
  "$LEAK_ABSOLUTE" "$LEAK_HOME_ONE" "$LEAK_HOME_TWO" "$LEAK_SSH" 2>&1)" || node_rc=$?
if [[ "$node_rc" -eq 0 ]] && [[ "$node_out" == *"all passed"* ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && ok "assertNoLeaks: $line"
  done <<< "$node_out"
else
  printf '%s\n' "$node_out"
  bad "assertNoLeaks: the module did not hold the contract (rc $node_rc)"
fi

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

# g5. the host is validated first, then the remote directory it reaches is asked for, then the local
#     store: the same order in both files, so neither guesses a layout before it was told one
for order_file in "$GEN" "$UPLOAD"; do
  host_line="$(first_line "$order_file" 'invalid POKOIN_MEDIA_FALLBACK_HOST')"
  remote_line="$(first_line "$order_file" "$WANT_REMOTE_LINE")"
  own_dir="$(first_line "$order_file" "$WANT_DIR_LINE")"
  if [[ "$host_line" == "0" || "$remote_line" == "0" || "$own_dir" == "0" ]]; then
    bad "g5: $(basename "$order_file") is missing one of the three checks (host=$host_line remote=$remote_line dir=$own_dir)"
  elif (( host_line < remote_line && remote_line < own_dir )); then
    ok "g5: $(basename "$order_file") validates the host ($host_line), asks for its remote directory ($remote_line), then for the local store ($own_dir)"
  else
    bad "g5: in $(basename "$order_file") host=$host_line remote=$remote_line dir=$own_dir, expected that order"
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

# g9. the leak check is wired into the same write: imported, called on the manifest, ahead of it,
#     and its refusal is what ends the run
if ! holds "$GEN" 'assertNoLeaks'; then
  bad "g9: the generator does not name the leak check at all"
else
  leak_call="$(first_line "$GEN" 'assertNoLeaks(')"
  leak_write="$(first_line "$GEN" 'writeFileSync(OUT')"
  if [[ "$leak_call" == "0" || "$leak_write" == "0" ]]; then
    bad "g9: the leak-check call ($leak_call) or the write ($leak_write) was not found"
  elif (( leak_call < leak_write )); then
    ok "g9: the leak check runs on line $leak_call, ahead of the write on line $leak_write"
  else
    bad "g9: the leak check runs after the file was written ($leak_call vs $leak_write)"
  fi
fi
leak_refused="$(first_line "$GEN" 'assertNoLeaks(')"
if [[ "$leak_refused" == "0" ]]; then
  bad "g9: no leak-check call to read the refusal after"
else
  # the two lines under the call carry the message and the exit, however the file is laid out
  around="$(sed -n "$((leak_refused + 1)),$((leak_refused + 4))p" "$GEN")"
  if ! holds <(printf '%s\n' "$around") 'process.exit(1)'; then
    bad "g9: the leak check is not followed by an exit 1: [$(printf '%s | ' "$around")]"
  elif ! printf '%s\n' "$around" | grep -q 'console.error'; then
    bad "g9: the leak check prints no error line: [$(printf '%s | ' "$around")]"
  elif printf '%s\n' "$around" | grep -q 'e\.message'; then
    ok "g9: the leak refusal prints the check's own reason on stderr and exits 1"
  else
    bad "g9: the leak refusal does not pass on what the check named: [$(printf '%s | ' "$around")]"
  fi
fi

# g10. the check runs on the manifest the run is about to write, not on a value read back from disk
if grep -q -E 'assertNoLeaks\((manifest|text)\)' "$GEN"; then
  ok "g10: the leak check is handed the manifest of this run"
else
  bad "g10: the leak check is not handed the manifest object or its text: [$(grep -E 'assertNoLeaks\(' "$GEN" | head -1)]"
fi

# g11. the remote directory of the fallback host is read from the environment in both scripts, with no
#      layout path left in the tree to fall back to
remote_assign="$(grep -E '^const PI_OBJECTS' "$GEN" | head -1 || true)"
if [[ -z "$remote_assign" ]]; then
  bad "g11: no PI_OBJECTS declaration was found in the generator"
elif [[ "$remote_assign" != *'process.env.POKOIN_MEDIA_FALLBACK_OBJECTS'* ]]; then
  bad "g11: the remote directory of the generator is not read from the environment: $remote_assign"
elif [[ "$remote_assign" == */* ]]; then
  bad "g11: the line that reads the remote directory still holds a path: $remote_assign"
else
  ok "g11: the generator takes its remote directory from the environment, with no default in the tree"
fi
upload_remote="$(grep -E '^PI_OBJECTS=' "$UPLOAD" | head -1 || true)"
if [[ -z "$upload_remote" ]]; then
  bad "g11: no PI_OBJECTS assignment was found in the upload script"
elif [[ "$upload_remote" != *'POKOIN_MEDIA_FALLBACK_OBJECTS'* ]]; then
  bad "g11: the remote directory of the upload script is not read from the environment: $upload_remote"
elif [[ "$upload_remote" == */* ]]; then
  bad "g11: the line that reads the remote directory still holds a path: $upload_remote"
else
  ok "g11: the upload script takes its remote directory from the environment, with no default in the tree"
fi

# g12. no script of the pair names a directory layout of the machine it happens to run on
for layout_file in "$GEN" "$UPLOAD" "$HERE/media-manifest-guard.mjs"; do
  if grep -q -F 'srv' "$layout_file"; then
    bad "g12: $(basename "$layout_file") still names a layout directory of one machine"
  else
    ok "g12: $(basename "$layout_file") holds no default remote directory"
  fi
done

# g13. a host with no remote directory behind it ends the generator before the ssh it would run, on
#      stderr, with the line the upload script prints too
remote_msg="$(first_line "$GEN" "$WANT_REMOTE_LINE")"
ssh_spawn="$(first_line "$GEN" "spawn('ssh'")"
host_msg="$(first_line "$GEN" 'invalid POKOIN_MEDIA_FALLBACK_HOST')"
if [[ "$remote_msg" == "0" ]]; then
  bad "g13: the generator does not print [$WANT_REMOTE_LINE]"
elif [[ "$ssh_spawn" != "0" ]] && (( remote_msg >= ssh_spawn )); then
  bad "g13: the remote directory is asked for on line $remote_msg, not ahead of the ssh call on line $ssh_spawn"
elif (( host_msg >= remote_msg )); then
  bad "g13: the remote directory ($remote_msg) is asked for before the host is validated ($host_msg)"
elif [[ "$(sed -n "$((remote_msg + 1))p" "$GEN")" != *'process.exit(2)'* ]]; then
  bad "g13: the line after the message is not an exit 2: [$(sed -n "$((remote_msg + 1))p" "$GEN")]"
elif [[ "$(sed -n "${remote_msg}p" "$GEN")" != *'console.error'* ]]; then
  bad "g13: the message does not go to stderr: [$(sed -n "${remote_msg}p" "$GEN")]"
else
  ok "g13: a host with no remote directory is refused on stderr with an exit 2, ahead of any ssh"
fi
if holds "$UPLOAD" "$WANT_REMOTE_LINE"; then
  ok "g13: the generator and the upload script print the same line for the same missing value"
else
  bad "g13: the upload script does not print [$WANT_REMOTE_LINE]"
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "all passed"
