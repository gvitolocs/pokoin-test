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
# the shape of a word wrapped in single quotes, which is how a path that holds anything a shell reads
# has to go over to another machine
WANT_QUOTE_WRAP="'%s'"

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

# g14 (round 2, item D). the remote directory is validated where the host is, in both scripts, with the
#      same line: it stands in front of every key the run asks the other machine for, so a value that is
#      not a plain absolute path ends the run before anything is fetched or ssh is asked anything.
WANT_INVALID_REMOTE_LINE="invalid POKOIN_MEDIA_FALLBACK_OBJECTS"
remote_invalid="$(first_line "$GEN" "$WANT_INVALID_REMOTE_LINE")"
gen_host_msg="$(first_line "$GEN" 'invalid POKOIN_MEDIA_FALLBACK_HOST')"
gen_ssh="$(first_line "$GEN" "spawn('ssh'")"
gen_fetch="$(first_line "$GEN" 'fetch(')"
if [[ "$remote_invalid" == "0" ]]; then
  bad "g14: the generator does not print [$WANT_INVALID_REMOTE_LINE]"
elif (( remote_invalid <= gen_host_msg )); then
  bad "g14: the generator refuses the remote directory ($remote_invalid) before it validates the host ($gen_host_msg)"
elif [[ "$gen_ssh" != "0" ]] && (( remote_invalid >= gen_ssh )); then
  bad "g14: the remote directory is checked on line $remote_invalid, not ahead of the ssh call ($gen_ssh)"
elif [[ "$gen_fetch" != "0" ]] && (( remote_invalid >= gen_fetch )); then
  bad "g14: the remote directory is checked on line $remote_invalid, not ahead of the first fetch ($gen_fetch)"
elif [[ "$(sed -n "$((remote_invalid + 1))p" "$GEN")" != *'process.exit(2)'* ]]; then
  bad "g14: the line after the refusal is not an exit 2: [$(sed -n "$((remote_invalid + 1))p" "$GEN")]"
elif [[ "$(sed -n "${remote_invalid}p" "$GEN")" != *'console.error'* ]]; then
  bad "g14: the refusal does not go to stderr: [$(sed -n "${remote_invalid}p" "$GEN")]"
else
  ok "g14: the generator refuses an unusable remote directory on stderr with exit 2, after its host, ahead of any fetch or ssh"
fi
if holds "$UPLOAD" "$WANT_INVALID_REMOTE_LINE"; then
  ok "g14: the generator and the upload script print the same line for the same unusable value"
else
  bad "g14: the upload script does not print [$WANT_INVALID_REMOTE_LINE]"
fi
# one character class for both, spelled out: a letter, a digit, or one of . _ / @ + -. Nothing that
# starts a second word, an expansion, a glob or a second remote command is in it.
for class_file in "$GEN" "$UPLOAD"; do
  if grep -q -F -- '[A-Za-z0-9._/@+-]' "$class_file"; then
    ok "g14: $(basename "$class_file") holds the one remote-directory class, and no other"
  else
    bad "g14: $(basename "$class_file") does not hold the remote-directory class [A-Za-z0-9._/@+-]"
  fi
done

# g16 (round 2, item D). the remote path of the upload script is quoted, in exactly the one place a
#      remote command is built out of a key
if ! holds "$UPLOAD" 'remote_word'; then
  bad "g16: the upload script builds no quoted remote word at all"
else
  # shellcheck disable=SC2016
  quote_use="$(first_line "$UPLOAD" 'test -f $(remote_word')"
  quote_def="$(first_line "$UPLOAD" 'remote_word() {')"
  if [[ "$quote_def" == "0" || "$quote_use" == "0" ]]; then
    bad "g16: the quoting helper (def=$quote_def) is not used by the remote test (use=$quote_use)"
  elif (( quote_def >= quote_use )); then
    bad "g16: the remote test on line $quote_use runs ahead of the helper defined on line $quote_def"
  elif ! sed -n "${quote_def},$((quote_def + 6))p" "$UPLOAD" | grep -qF -- "$WANT_QUOTE_WRAP"; then
    bad "g16: the helper does not write a quote of the name as a quoted quote: [$(sed -n "${quote_def},$((quote_def + 6))p" "$UPLOAD" | tr '\n' '|')]"
  else
    ok "g16: the remote path is one quoted word, built by the helper the remote test calls"
  fi
fi

# ---------------------------------------------------------------------------
# g17 (round 2, item E). assertDirectory, imported and called for itself. The generator is never run, so
#      the check that its object directory is a directory that is there lives in the guard module, where
#      it can be asked what it does with a path. The upload script has held this rule for a run of its
#      own; a store that is not a directory reads as an empty one, which is every key missing.
# ---------------------------------------------------------------------------
cat > "$TMP/assert-directory.mjs" <<'NODE'
import { pathToFileURL } from 'node:url';
import { mkdirSync, symlinkSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const [guardPath, root] = process.argv.slice(2);
// the module may not reach the network nor a process on the way in, as before
globalThis.fetch = () => {
  throw new Error('the guard reached the network');
};

const mod = await import(pathToFileURL(guardPath).href);
if (typeof mod.assertDirectory !== 'function') {
  console.log(`FAIL: assertDirectory is ${typeof mod.assertDirectory}, not a function`);
  process.exit(1);
}
const { assertDirectory } = mod;

mkdirSync(join(root, 'store'));
mkdirSync(join(root, 'store', 'figures'));
writeFileSync(join(root, 'catalog.json'), '{}\n');
symlinkSync(join(root, 'store'), join(root, 'link-to-store'));
symlinkSync(join(root, 'nothing-there'), join(root, 'dangling-link'));

const problems = [];
const expectPass = (name, path) => {
  try {
    assertDirectory(path);
    console.log(`ok: ${name} is taken for what it is`);
  } catch (e) {
    problems.push(`${name}: threw ${e instanceof Error ? e.message : String(e)}`);
  }
};
const expectThrow = (name, path) => {
  let thrown = null;
  try {
    assertDirectory(path);
  } catch (e) {
    thrown = e;
  }
  if (thrown === null) {
    problems.push(`${name}: nothing was thrown, so the value would have been taken for a store`);
  } else if (!(thrown instanceof Error)) {
    problems.push(`${name}: threw a ${typeof thrown}, not an Error`);
  } else {
    console.log(`ok: ${name} is refused (${thrown.message})`);
  }
};

expectPass('a directory', join(root, 'store'));
expectPass('a directory with something under it', join(root, 'store', 'figures'));
// the upload script asks [[ -d ]], which follows a link, so a link to a directory has to be taken the
// same way here: the two scripts are one rule, not two rules that disagree
expectPass('a link that stands for a directory', join(root, 'link-to-store'));
expectThrow('a path that is not there', join(root, 'no-such-store'));
expectThrow('a link to nothing', join(root, 'dangling-link'));
expectThrow('a regular file', join(root, 'catalog.json'));
expectThrow('an empty value', '');

if (problems.length) {
  console.log(problems.map((p) => `FAIL: ${p}`).join('\n'));
  process.exit(1);
}
console.log('all passed');
NODE

dir_rc=0
dir_out="$(node "$TMP/assert-directory.mjs" "$GUARD" "$TMP" 2>&1)" || dir_rc=$?
if [[ "$dir_rc" -eq 0 ]] && [[ "$dir_out" == *"all passed"* ]]; then
  while IFS= read -r line; do
    [[ "$line" == 'ok: '* ]] && ok "assertDirectory: ${line#ok: }"
  done <<< "$dir_out"
else
  printf '%s\n' "$dir_out"
  bad "assertDirectory: the module did not hold the contract (rc $dir_rc)"
fi

# g18 (round 2, item E). the generator calls that check, in the place the upload script has it: after the
#      value is asked for and before a catalog is fetched, on stderr with an exit 2 and the one line the
#      upload script prints.
WANT_NOT_DIR_LINE="POKOIN_OBJECTS is not a directory"
dir_import="$(grep -F "from './media-manifest-guard.mjs'" "$GEN" | grep -c 'assertDirectory' || true)"
dir_unset="$(first_line "$GEN" "$WANT_DIR_LINE")"
dir_call="$(first_line "$GEN" 'assertDirectory(')"
dir_msg="$(first_line "$GEN" "$WANT_NOT_DIR_LINE")"
dir_fetch="$(first_line "$GEN" 'fetch(')"
dir_spawn="$(first_line "$GEN" "spawn('ssh'")"
if [[ "$dir_import" != "1" ]]; then
  bad "g18: the generator does not import assertDirectory from the guard module once (found $dir_import)"
elif [[ "$dir_call" == "0" ]]; then
  bad "g18: the generator never calls assertDirectory"
elif [[ "$dir_unset" == "0" ]] || (( dir_call <= dir_unset )); then
  bad "g18: the store is checked on line $dir_call, not after the run is asked for it on line $dir_unset"
elif [[ "$dir_fetch" != "0" ]] && (( dir_call >= dir_fetch )); then
  bad "g18: the store is checked on line $dir_call, not ahead of the first fetch on line $dir_fetch"
elif [[ "$dir_spawn" != "0" ]] && (( dir_call >= dir_spawn )); then
  bad "g18: the store is checked on line $dir_call, not ahead of the ssh call on line $dir_spawn"
elif ! sed -n "${dir_call}p" "$GEN" | grep -qF -- 'LOCAL_OBJECTS'; then
  bad "g18: the call does not name the value the store is held in: [$(sed -n "${dir_call}p" "$GEN")]"
elif [[ "$dir_msg" == "0" ]]; then
  bad "g18: the generator does not print [$WANT_NOT_DIR_LINE]"
elif [[ "$(sed -n "${dir_msg}p" "$GEN")" != *'console.error'* ]]; then
  bad "g18: the refusal does not go to stderr: [$(sed -n "${dir_msg}p" "$GEN")]"
elif [[ "$(sed -n "$((dir_msg + 1))p" "$GEN")" != *'process.exit(2)'* ]]; then
  bad "g18: the line after the refusal is not an exit 2: [$(sed -n "$((dir_msg + 1))p" "$GEN")]"
elif (( dir_msg <= dir_call )); then
  bad "g18: the refusal on line $dir_msg does not follow the check on line $dir_call"
else
  ok "g18: the generator checks its store is a directory, after the unset check and before a fetch, with exit 2"
fi
if holds "$UPLOAD" "$WANT_NOT_DIR_LINE"; then
  ok "g18: the generator and the upload script print the same line for a store that is no directory"
else
  bad "g18: the upload script does not print [$WANT_NOT_DIR_LINE]"
fi

# g19 (round 2, item F). the modes the tree holds for this directory: a shell file of scripts/ is a program
#      and is tracked executable, a module is imported and is not. One suite was left non-executable while
#      its two siblings were not, and a file that is run as bash scripts/... only differs from the others
#      by that permission -- the suites go on being run the same way.
if ! git rev-parse --is-inside-work-tree > /dev/null 2>&1; then
  bad "g19: the tree cannot be asked for its modes outside a work tree"
else
  # -r so that the files of the directory are named and not the directory itself, and every row of the
  # list is a blob with its mode in front
  mode_rows="$(git ls-tree -r HEAD -- "$HERE")"
  if [[ -z "$mode_rows" ]]; then
    bad "g19: git ls-tree named no file of $HERE"
  else
    mode_problems=0
    # the row is "mode type sha<TAB>path", and the separator is named rather than typed: a file
    # of this repository holds no invisible byte
    mode_tab=$'\t'
    while IFS= read -r mode_row; do
      mode_value="${mode_row%% *}"
      mode_path="${mode_row##*"$mode_tab"}"
      case "$mode_path" in
        *.sh)
          if [[ "$mode_value" != "100755" ]]; then
            echo "FAIL: $(basename "$mode_path") is tracked $mode_value, a shell file of scripts/ is 100755"
            mode_problems=$((mode_problems + 1))
          fi ;;
        *.mjs)
          if [[ "$mode_value" != "100644" ]]; then
            echo "FAIL: $(basename "$mode_path") is tracked $mode_value, a module of scripts/ is 100644"
            mode_problems=$((mode_problems + 1))
          fi ;;
      esac
    done <<< "$mode_rows"
    if [[ "$mode_problems" -eq 0 ]]; then
      sh_n="$(printf '%s\n' "$mode_rows" | grep -c '\.sh$' || true)"
      mjs_n="$(printf '%s\n' "$mode_rows" | grep -c '\.mjs$' || true)"
      ok "g19: $sh_n shell files of scripts/ are tracked executable and $mjs_n modules are not"
    else
      bad "g19: $mode_problems file(s) of scripts/ are tracked with a mode their kind does not use"
    fi
  fi
fi

if [[ "$fail" -ne 0 ]]; then
  echo "FAILED"
  exit 1
fi
echo "all passed"
