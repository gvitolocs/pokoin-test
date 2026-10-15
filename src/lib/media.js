/** Public origin for test.pokoin.com media (Cloudflare R2: pokoin-test-media). */
export const MEDIA_BASE = 'https://test-media.pokoin.com';

/**
 * Replace `fromPrefix` at the start of `url` with `toPrefix` (prefixes normalized without trailing slash).
 * Returns `url` unchanged when it does not start with `fromPrefix`.
 */
export function rebaseMediaUrl(url, fromPrefix, toPrefix) {
  if (typeof url !== 'string' || !url) return url;
  const from = fromPrefix.replace(/\/$/, '');
  const to = toPrefix.replace(/\/$/, '');
  if (!url.startsWith(from)) return url;
  const rest = url.slice(from.length);
  if (rest === '') return to;
  if (rest.startsWith('/')) return `${to}${rest}`;
  return url;
}
