// The two checks scripts/media-manifest.mjs runs on its own manifest before it writes the file: a
// manifest is public and the fallback host is a machine the operator names, so the two must not
// meet, and a manifest is a list of keys and holds no directory either. The host check is the one
// that cannot say anything with no fallback configured, which is why the second one is not the same
// rule. It sits beside the generator rather than inside it because importing the generator fetches
// the catalog, and this module holds no side effect at all.

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
