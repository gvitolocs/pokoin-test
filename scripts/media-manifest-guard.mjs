// The check scripts/media-manifest.mjs runs on the manifest text before it writes the file: a
// manifest is public and the fallback host is a machine the operator names, so the two must not
// meet. It sits beside the generator rather than inside it because importing the generator fetches
// the catalog, and this module holds no side effect at all.

export function assertNoHost(text, host) {
  // no fallback configured is nothing to keep out, and an empty string is inside every string
  if (typeof host !== 'string' || host.length === 0) return;
  if (text.includes(host)) {
    throw new Error('refusing to write a manifest that names the fallback host');
  }
}
