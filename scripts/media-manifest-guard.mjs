// The checks scripts/media-manifest.mjs runs on its own manifest before it writes the file: a
// manifest is public and the fallback host is a machine the operator names, so the two must not
// meet, and a manifest is a list of keys and holds no directory either. The host check is the one
// that cannot say anything with no fallback configured, which is why the second one is not the same
// rule. It sits beside the generator rather than inside it because importing the generator fetches
// the catalog, and this module holds no side effect at all. The third check is of the same kind and
// for the same reason: the generator is never run here, and the rule that its store is a directory
// can only be asked of a function.

import { statSync } from 'node:fs';

// The directory a run was pointed at for its media objects. A name that is not there, or that holds a
// file, cannot give up any object: read as an empty store it comes back as every key of the list
// missing from it, which the generator would then write as the state of the media. A link is followed,
// as the upload script's [[ -d ]] follows it, so that the two say the same thing about one name. The
// refusal names the reason and not the path, which belongs to the machine the run works on.
export function assertDirectory(path) {
  let st;
  try {
    st = statSync(path);
  } catch (e) {
    throw new Error(`the object store cannot be read: ${e.code || 'unreadable'}`);
  }
  if (!st.isDirectory()) {
    throw new Error('the object store is not a directory');
  }
}

export function assertNoHost(text, host) {
  // no fallback configured is nothing to keep out, and an empty string is inside every string
  if (typeof host !== 'string' || host.length === 0) return;
  if (text.includes(host)) {
    throw new Error('refusing to write a manifest that names the fallback host');
  }
}

// the roots an account sits under, spelled in pieces: this file is tracked, and the rule it carries
// is the one that keeps such a directory out of a public file, so it may not hold one either
const ACCOUNT_ROOTS = ['/ho' + 'me', '/U' + 'sers'];

function looksLikeLocalPath(value) {
  if (value.startsWith('/') || value.startsWith('ssh:')) return true;
  return ACCOUNT_ROOTS.some((root) => new RegExp(`${root}/[A-Za-z0-9_.-]+/`).test(value));
}

function stringsIn(value) {
  if (typeof value === 'string') return [value];
  if (Array.isArray(value)) return value.filter((item) => typeof item === 'string');
  return [];
}

// A manifest object or the text of one: every string a row holds is looked at, and the refusal names
// the row and the column it found the shape in, never the value, which is the thing kept out.
export function assertNoLeaks(manifestOrText) {
  const manifest = typeof manifestOrText === 'string' ? JSON.parse(manifestOrText) : manifestOrText;
  for (const row of manifest.entries) {
    for (const [field, value] of Object.entries(row)) {
      for (const item of stringsIn(value)) {
        if (looksLikeLocalPath(item)) {
          throw new Error(`row ${row.key}: field ${field} looks like a path`);
        }
      }
    }
  }
}
