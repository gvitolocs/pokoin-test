/** Print-region flags for the OCR board. Circle SVGs are HatScripts (MIT), in public/flags. */

const SEARCH_LANGS = ['en', 'it', 'fr', 'de', 'es', 'jp', 'pt', 'nl', 'pl', 'ru', 'ko', 'zh', 'zht', 'id', 'th', 'vi'];
const CODES = new Set(SEARCH_LANGS);
const PRINT_FLAG_CODES = new Set(['jp', 'zh', 'eu', 'us', 'euus', 'jpko', 'idth']);
const FLAG_FILE = {
  eu: 'eu.png',
  us: 'us.svg',
  euus: 'euus.svg',
  jpko: 'jpko.svg',
  idth: 'idth.svg',
};

function isSearchLang(code) {
  return CODES.has(String(code || '').toLowerCase());
}

export function flagSrc(code) {
  const raw = String(code || '').toLowerCase();
  const lang = isSearchLang(raw) || PRINT_FLAG_CODES.has(raw) ? raw : 'en';
  const base = (typeof import.meta !== 'undefined' && import.meta.env && import.meta.env.BASE_URL) || '/';
  const file = FLAG_FILE[lang] || `${lang}.svg`;
  return `${base}flags/${file}`;
}

/** Print flag from `pokoin_pokemon_expansions.nationality`. */
export function printFlagFromNationality(nationality) {
  const value = String(nationality || '').trim().toLowerCase();
  if (value === 'japanese') {
    return { code: 'jpko', label: 'Japanese print' };
  }
  if (value === 'chinese') {
    return { code: 'zh', label: 'Chinese print' };
  }
  if (value === 'korean') {
    return { code: 'ko', label: 'Korean print' };
  }
  if (value === 'european' || value === 'eu') {
    return { code: 'eu', label: 'European print' };
  }
  if (value === 'american' || value === 'us') {
    return { code: 'us', label: 'English print' };
  }
  if (value === 'western') {
    return { code: 'euus', label: 'Western print' };
  }
  if (value === 'indonesian') {
    return { code: 'id', label: 'Indonesian print' };
  }
  if (value === 'thai') {
    return { code: 'th', label: 'Thai print' };
  }
  if (value === 'idth') {
    return { code: 'idth', label: 'Indonesian / Thai print' };
  }
  if (value === 'french' || value === 'fr') {
    return { code: 'fr', label: 'French print' };
  }
  if (value === 'german' || value === 'de') {
    return { code: 'de', label: 'German print' };
  }
  return null;
}
