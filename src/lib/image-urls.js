/** Point a `/card-images/` path at the CDN. The review boards' scans are not in the
 * catalog cache-buster table, so this does not carry that table. */

export const CDN_ORIGIN = 'https://cdn.pokoin.com';

export function cdnFetchUrl(value) {
  const text = String(value || '').trim();
  if (!text || text.startsWith('data:') || text.startsWith('blob:')) {
    return text;
  }
  try {
    const url = new URL(text, 'https://pokoin.com');
    if (url.hostname === 'cdn.pokoin.com') {
      return `${CDN_ORIGIN}${url.pathname}${url.search}`;
    }
    if (url.pathname.startsWith('/card-images/')) {
      return `${CDN_ORIGIN}${url.pathname.slice('/card-images'.length)}${url.search}`;
    }
  } catch (_) {
    /* fall through */
  }
  if (text.startsWith('/card-images/')) {
    return `${CDN_ORIGIN}${text.slice('/card-images'.length)}`;
  }
  return text;
}

function uniqueUrls(list) {
  const out = [];
  for (const item of list) {
    if (item && !out.includes(item)) out.push(item);
  }
  return out;
}

function preferFullImage(value) {
  return String(value || '').replace(/\.(png|webp)(\?|$)/i, '.jpg$2');
}

function homepageDerivativeUrl(value) {
  const full = preferFullImage(value);
  if (!full) return '';
  if (/_homepage\.webp(?:\?|$)/i.test(full)) return full;
  return full.replace(/\.(jpe?g|png|webp)(\?|$)/i, '_homepage.webp$2');
}

/** `full` is the leftover JPEG, then its homepage tile if that 404s. */
export function rasterSiblings(value, { full = false } = {}) {
  const text = String(value || '').trim();
  if (!text) return [];
  if (full) {
    const jpeg = preferFullImage(text);
    if (!jpeg) return [];
    return uniqueUrls([jpeg, homepageDerivativeUrl(jpeg)].filter(Boolean));
  }
  if (/_homepage\.webp(?:\?|$)/i.test(text)) {
    const jpeg = text.replace(/_homepage\.webp(\?|$)/i, '.jpg$1');
    return jpeg && jpeg !== text ? [text, jpeg] : [text];
  }
  return [text];
}
