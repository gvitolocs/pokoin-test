/**
 * Every Poko review on /poko, newest first.
 *
 * `date` is the day the test was published. A `-YYYYMMDD` tag in the CDN
 * path wins. Otherwise the day it landed on the old React board:
 * 7e088baf (4 Oct 2026) for the Part 5 episodes, b20be337 (9 Oct 2026) for
 * the one-minute auditions and the Part 5 opening A/B. The Chatterbox LoRA
 * rounds have no path tag; the review mp3s were published 10 Oct (round 1)
 * and 11 Oct (round 2).
 */

const POSTER = 'https://cdn.pokoin.com/poko-video/ep5/poster.jpg';
const AUDIO_BASE = 'https://cdn.pokoin.com/poko-video/ep5/chatterbox/auditions-v2-20261008';
const EP7_AUDIO_BASE = 'https://cdn.pokoin.com/poko-video/ep5/chatterbox/en-ep7-v4-20261008';
const V5_AUDIO = 'https://cdn.pokoin.com/poko-video/ep5/chatterbox/en-all-v5-20261008';
const CB1 = 'https://cdn.pokoin.com/poko-video/audio-tests/cb-lora1';
const CB2 = 'https://cdn.pokoin.com/poko-video/audio-tests/cb-lora2';

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December'];
const MONTHS_SHORT = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function video(entry) {
  return { kind: 'video', lang: 'en', poster: POSTER, ...entry };
}

function audio(entry) {
  return { kind: 'audio', ...entry };
}

export function formatDay(iso) {
  const [year, month, day] = iso.split('-').map(Number);
  return `${day} ${MONTHS_SHORT[month - 1]} ${year}`;
}

export function monthLabel(isoMonth) {
  const [year, month] = isoMonth.split('-').map(Number);
  return `${MONTHS[month - 1]} ${year}`;
}

/** Newest month first. Same-day tests keep their order in `tests`. */
export function testsByMonth(tests = POKO_TESTS) {
  const indexed = tests.map((test, index) => ({ test, index }));
  indexed.sort((a, b) => b.test.date.localeCompare(a.test.date) || a.index - b.index);
  const groups = [];
  for (const { test } of indexed) {
    const id = test.date.slice(0, 7);
    const last = groups[groups.length - 1];
    if (last?.id === id) last.tests.push(test);
    else groups.push({ id, label: monthLabel(id), tests: [test] });
  }
  return groups;
}

/** Consecutive videos share one tile grid; an audio set stays its own block. */
export function blocksFor(tests) {
  const blocks = [];
  for (const test of tests) {
    const last = blocks[blocks.length - 1];
    if (test.kind === 'video' && last?.kind === 'videos') last.tests.push(test);
    else if (test.kind === 'video') blocks.push({ kind: 'videos', tests: [test] });
    else blocks.push({ kind: 'audio', test });
  }
  return blocks;
}

export const POKO_TESTS = [
  video({
    id: 'ep8-voxkit-opening',
    date: '2026-10-15',
    title: 'Part 8 · opening · voxel Lugia from the real game model (Rust voxkit) · review',
    src: 'https://cdn.pokoin.com/poko-video/ep8/voxkit-opening-20261015/lugia-voxkit-opening-720p.mp4',
    poster: 'https://cdn.pokoin.com/poko-video/ep8/voxkit-opening-20261015/lugia-voxkit-opening.jpg',
  }),
  video({
    id: 'ep8-lugia',
    date: '2026-10-14',
    title: 'Part 8 · Lugia: the card that never gives up · full episode · English · Qwen3-TTS v3',
    src: 'https://cdn.pokoin.com/poko-video/ep8/lugia-v1-20261014/poko_lugia_never_gives_up_720p.mp4',
    poster: 'https://cdn.pokoin.com/poko-video/ep8/lugia-v1-20261014/ep8.jpg',
    note: 'one vertical dive from the sand (2000) to the sunrise (2026): Elemental Blast 90 → 200 → 250. Lugia = voxel art built from the game sprites (pixel art first, no pixel redrawn). All cards real scans. 5:15, final Whisper check 99.3 %.',
  }),
  audio({
    id: 'cb-lora2',
    date: '2026-10-11',
    title: 'Chatterbox V3 LoRA round 2 (22 languages)',
    intro: 'Unseen test lines, read as one block. The nine clips below are the languages this round added or retested.',
    clips: [
      ['uk', 'Українська', '16/20', 'stock 4/20'],
      ['sl', 'Slovenščina', '13/20', 'stock 6/20'],
      ['el', 'Ελληνικά', '12/20', 'stock 14/20'],
      ['ja', '日本語', '14/20', 'stock 14/20'],
      ['zh-TW', '繁體中文', 'ASR n/a', 'Whisper writes Simplified: listen'],
      ['et', 'Eesti', '8/20', 'stock 9/20'],
      ['lv', 'Latviešu', '5/20', 'stock 4/20'],
      ['lt', 'Lietuvių', '7/20', 'stock 2/20'],
      ['cs', 'Čeština (round 2)', '14/20', 'round 1 12/20'],
    ].map(([code, name, words, other]) => ({
      id: `cb-lora2-${code}`,
      title: name,
      lang: code,
      chips: [`clear lines ${words}`, other],
      sub: 'unseen test lines, read as one block · Fenrir reference clip in the same language',
      aria: `Chatterbox V3 multilingual LoRA round 2 · ${name}`,
      src: `${CB2}/cb_lora2_${code}.mp3`,
    })),
  }),
  video({
    id: 'ep7-v2',
    date: '2026-10-10',
    title: 'Part 7 v2 · The Mystery of the Wobbly Cards (Komiya) · full episode · English · Qwen3-TTS v3',
    src: 'https://cdn.pokoin.com/poko-video/ep7/mystery-v2d-20261010/poko_komiya_museum_720p.mp4',
    poster: 'https://cdn.pokoin.com/poko-video/ep7/mystery-v2d-20261010/ep7.jpg',
    note: 'new script from the Komiya interview + fan discussions; all cards from the Pokoin database (67-card Komiya wall). Voice: Qwen3-TTS v3, one take per clue, pauses written into the text, 15 % slower with WSOLA (your pick D, no tunnel sound); pixel-art detective hat that moves with Poko. 4:19, final Whisper check 97.8 %.',
  }),
  video({
    id: 'ep7-rooms',
    date: '2026-10-10',
    title: 'Previous version · Part 7 · Komiya Museum (rooms) · Qwen3-TTS v3',
    src: 'https://cdn.pokoin.com/poko-video/ep7/qwen-v3-rooms-20261010/poko_komiya_museum_720p.mp4',
    poster: 'https://cdn.pokoin.com/poko-video/ep7/qwen-v3-rooms-20261010/ep7.jpg',
    note: 'voice: Qwen3-TTS 1.7B v3 fixed, one plain take per museum room (Qwen picks its own rhythm and pauses), no inserted silence; animation and music re-timed to the read. 3:46, final Whisper large-v3 check 98.5 % word match.',
  }),
  audio({
    id: 'cb-lora1',
    date: '2026-10-10',
    title: 'Chatterbox V3 LoRA round 1 (14 languages)',
    clips: [
      ['hr', 'Hrvatski', '17/20', 'stock 4/20'],
      ['bg', 'Български', '13/20', 'stock 9/20'],
      ['cs', 'Čeština', '12/20', 'stock 4/20'],
      ['ro', 'Română', '11/20', 'stock 4/20'],
      ['hu', 'Magyar', '7/20', 'stock 3/20'],
      ['sk', 'Slovenčina', '6/20', 'stock 1/20'],
      ['ko', '한국어', '16/20', 'stock 16/20'],
      ['pl', 'Polski', '15/20', 'stock 17/20'],
      ['nl', 'Nederlands', '14/20', 'stock 14/20'],
      ['sv', 'Svenska', '14/20', 'stock 12/20'],
      ['nb', 'Norsk', '14/20', 'stock 13/20'],
      ['id', 'Bahasa Indonesia', '13/20', 'stock 14/20'],
      ['fi', 'Suomi', '8/20', 'stock 9/20'],
      ['da', 'Dansk', '6/20', 'stock 4/20'],
    ].map(([code, name, words, stock]) => ({
      id: `cb-lora1-${code}`,
      title: name,
      lang: code,
      chips: [`clear lines ${words}`, stock],
      sub: 'unseen test lines, read as one block · Fenrir reference clip in the same language',
      aria: `Chatterbox V3 multilingual LoRA · ${name}`,
      src: `${CB1}/cb_lora1_${code}.mp3`,
    })),
  }),
  audio({
    id: 'qwen-v4',
    date: '2026-10-10',
    title: 'Qwen3-TTS v4 multilingual',
    clips: [
      ['it', 'Italiano', '17/20', '0.723', '0.709'],
      ['fr', 'Français', '17/20', '0.714', '0.665'],
      ['de', 'Deutsch', '18/20', '0.739', '0.715'],
      ['es-ES', 'Español (España)', '18/20', '0.735', '0.711'],
      ['es-419', 'Español (Latinoamérica)', '18/20', '0.745', '0.722'],
      ['pt-BR', 'Português (Brasil)', '16/20', '0.740', '0.752'],
      ['pt-PT', 'Português (Portugal)', '16/20', '0.736', '0.676'],
      ['en', 'English', '18/20', '0.823', '0.801'],
    ].map(([code, name, words, sim, teacher]) => ({
      id: `qwen-v4-${code}`,
      title: name,
      lang: code,
      chips: [`clear lines ${words}`, `similarity ${sim} · Fenrir ${teacher}`],
      sub: 'unseen test lines, read as one block · one Poko voice trained on 6 languages',
      aria: `Qwen3-TTS v4 multilingual · ${name}`,
      src: `https://cdn.pokoin.com/poko-video/qwen-v4-ml-20261010/qwen_v4_${code}.mp3`,
    })),
  }),
  audio({
    id: 'qwen-en-later',
    date: '2026-10-09',
    title: 'Qwen3-TTS 1.7B · same phrases · v3, Expressive, Directed',
    intro: 'Same Part 5 opening phrases as the A/B below, from the later 9 October takes.',
    clips: [
      {
        id: 'qwen-v3b',
        title: 'Qwen3-TTS 1.7B · v3 + 10 epochs (20 total)',
        chips: ['word match 100/100/95 %', 'similarity 0.932'],
        sub: 'v3 continued for 10 more epochs · same fixed training',
        aria: 'Qwen3-TTS v3 continued to 20 epochs · same phrases',
        src: 'https://cdn.pokoin.com/poko-video/ep5/qwen/en-v3b-20ep-20261009/en_qwen_samephrase_v3b.mp3',
      },
      {
        id: 'qwen-v3fixed',
        title: 'Qwen3-TTS 1.7B · v3 fixed training',
        chips: ['word match 100/100/95 %', 'similarity 0.929'],
        sub: 'retrained with the official fine-tune bugs fixed · no instruction, no line stitching',
        aria: 'Qwen3-TTS v3 fixed training · same phrases',
        src: 'https://cdn.pokoin.com/poko-video/ep5/qwen/en-v3fixed-20261009/en_qwen_samephrase_v3fixed.mp3',
      },
      {
        id: 'qwen-expressive',
        title: 'Qwen3-TTS 1.7B · Expressive Poko',
        chips: ['word match 100/100/95 %', 'similarity 0.852'],
        sub: 'same fine-tune · "Expressive Poko" voice instruction',
        aria: 'Qwen3-TTS · Expressive Poko instruction · same phrases',
        src: 'https://cdn.pokoin.com/poko-video/ep5/qwen/en-expressive-v1-20261009/en_qwen_samephrase_expressive_v1.mp3',
      },
      {
        id: 'qwen-directed',
        title: 'Qwen3-TTS 1.7B · Directed',
        chips: ['word match 100/100/95 %', 'similarity 0.897'],
        sub: 'line-by-line direction: fast/slow, high/low, pauses · best of 6–12 takes per line',
        aria: 'Qwen3-TTS · line-by-line directed · same phrases',
        src: 'https://cdn.pokoin.com/poko-video/ep5/qwen/en-directed-v1b-20261009/en_qwen_samephrase_directed_v1.mp3',
      },
    ],
  }),
  audio({
    id: 'part5-opening',
    date: '2026-10-09',
    title: 'Current A/B · same phrases · Part 5 opening',
    lang: 'en',
    intro: 'Lines 1–8 of Part 5 in three blocks: same words, same split, natural pace, constant-gain level match.',
    caption: 'Speaker similarity is an identity estimate against a Gemini Fenrir clip, not a quality score; the 95 % block is Whisper writing Poko as Poco. Your ears decide. voice source: newPoko dataset (vo/dataset-en-001, Gemini Fenrir, episodes 1–7); Chatterbox Multilingual V3 LoRA / Qwen3-TTS-12Hz-1.7B-Base SFT.',
    clips: [
      {
        id: 'part5-fenrir',
        date: '2026-10-08',
        title: 'Gemini Fenrir',
        chips: ['reference'],
        aria: 'Gemini Fenrir · original reference',
        src: `${AUDIO_BASE}/en_gemini_target.mp3`,
      },
      {
        id: 'part5-chatterbox',
        date: '2026-10-08',
        title: 'Chatterbox V3',
        chips: ['word match 100/100/95 %', 'similarity 0.952'],
        sub: 'LoRA · trained on English episodes 1–7',
        aria: 'Chatterbox V3 · same phrases',
        src: `${V5_AUDIO}/en_all_ft_samephrase_v5.mp3`,
      },
      {
        id: 'part5-qwen-v1',
        date: '2026-10-09',
        title: 'Qwen3-TTS 1.7B',
        chips: ['word match 100/100/95 %', 'similarity 0.922'],
        sub: 'single-speaker fine-tune · English episodes 1–7',
        aria: 'Qwen3-TTS · same phrases',
        src: 'https://cdn.pokoin.com/poko-video/ep5/qwen/en-all-v1-20261009/en_qwen_samephrase_v1.mp3',
      },
    ],
  }),
  video({
    id: 'chatterbox_en_all_v5',
    date: '2026-10-09',
    title: 'Chatterbox V3 · English training · episodes 1–7 · 1 min test',
    src: 'https://cdn.pokoin.com/poko-video/ep5/chatterbox/en_all_ft_v5/pokemon30-chatterbox-preview-60s.mp4',
    voiceover: 'https://cdn.pokoin.com/poko-video/ep5/chatterbox/en_all_ft_v5/pokemon30-chatterbox-voiceover-60s.wav',
    note: 'voice source: newPoko sample dataset (vo/dataset-en-001, episodes 1–7), Chatterbox Multilingual V3, LoRA fine-tuned EN only',
  }),
  video({
    id: 'chatterbox_en_ep7_v4',
    date: '2026-10-09',
    title: 'Chatterbox V3 · English-only training on ep7 · 123 clips · 1 min test',
    src: 'https://cdn.pokoin.com/poko-video/ep5/chatterbox/en_ep7_ft_v4/pokemon30-chatterbox-preview-60s.mp4',
    voiceover: 'https://cdn.pokoin.com/poko-video/ep5/chatterbox/en_ep7_ft_v4/pokemon30-chatterbox-voiceover-60s.wav',
    note: 'voice source: newPoko sample dataset (vo/dataset-en-001, ep7), Chatterbox Multilingual V3, LoRA fine-tuned EN only',
  }),
  video({
    id: 'chatterbox_en',
    date: '2026-10-09',
    title: 'Pokémon 30th Anniversary — Chatterbox V3 (newPoko) · English · 1 min',
    src: 'https://cdn.pokoin.com/poko-video/ep5/chatterbox/en_zeroshot/pokemon30-chatterbox-preview-60s.mp4',
    voiceover: 'https://cdn.pokoin.com/poko-video/ep5/chatterbox/en_zeroshot/pokemon30-chatterbox-voiceover-60s.wav',
    note: 'voice source: newPoko sample dataset (vo/dataset-en-001), Chatterbox Multilingual V3, zero-shot',
  }),
  video({
    id: 'chatterbox_it',
    date: '2026-10-09',
    lang: 'it',
    title: 'Pokémon 30th Anniversary — Chatterbox V3 (newPoko) · Italiano · 1 min',
    src: 'https://cdn.pokoin.com/poko-video/ep5/chatterbox/it_zeroshot/pokemon30-chatterbox-preview-60s.mp4',
    voiceover: 'https://cdn.pokoin.com/poko-video/ep5/chatterbox/it_zeroshot/pokemon30-chatterbox-voiceover-60s.wav',
    note: 'voice source: newPoko sample dataset (vo/dataset-it-001), Chatterbox Multilingual V3, zero-shot',
  }),
  video({
    id: 'fenrir',
    date: '2026-10-09',
    title: 'Gemini 3.8 · Fenrir · English · 1 min',
    src: 'https://cdn.pokoin.com/poko-video/ep5/gemini38/gemini_fenrir_1m.mp4',
  }),
  video({
    id: 'fenrir_it',
    date: '2026-10-09',
    lang: 'it',
    title: 'Gemini 3.8 · Fenrir · Italiano · 1 min',
    src: 'https://cdn.pokoin.com/poko-video/ep5/gemini38/gemini_fenrir_it_1m.mp4',
  }),
  video({
    id: 'azure1m',
    date: '2026-10-09',
    title: 'Azure · excited · English · 1 min baseline',
    src: 'https://cdn.pokoin.com/poko-video/ep5/gemini38/azure_excited_1m.mp4',
  }),
  video({
    id: 'azure_it',
    date: '2026-10-09',
    lang: 'it',
    title: 'Azure · excited · Italiano · 1 min baseline',
    src: 'https://cdn.pokoin.com/poko-video/ep5/gemini38/azure_excited_it_1m.mp4',
  }),
  video({
    id: 'puck',
    date: '2026-10-09',
    title: 'Gemini 3.8 · Puck (upbeat) · EN · 1 min',
    src: 'https://cdn.pokoin.com/poko-video/ep5/gemini38/gemini_puck_1m.mp4',
  }),
  video({
    id: 'leda',
    date: '2026-10-09',
    title: 'Gemini 3.8 · Leda (youthful) · EN · 1 min',
    src: 'https://cdn.pokoin.com/poko-video/ep5/gemini38/gemini_leda_1m.mp4',
  }),
  video({
    id: 'achird',
    date: '2026-10-09',
    title: 'Gemini 3.8 · Achird (friendly) · EN · 1 min',
    src: 'https://cdn.pokoin.com/poko-video/ep5/gemini38/gemini_achird_1m.mp4',
  }),
  audio({
    id: 'en-new-phrases',
    date: '2026-10-08',
    title: 'EN · new phrases (ep1–7 test)',
    lang: 'en',
    chip: 'EN · new phrases (ep1–7 test)',
    caption: 'New phrases for comparing the voices. These paragraphs are absent from all seven episode scripts. All three Chatterbox versions read the same new text, with natural pacing. The first video below also shows the new voice on the familiar episode 5 timeline. voice source: newPoko sample dataset (vo/dataset-en-001, Gemini Fenrir), Chatterbox Multilingual V3; zero-shot, ep7 EN training, or episodes 1–7 EN training according to the label.',
    clips: [
      { id: 'en_gemini_target', title: 'Gemini Fenrir · voice reference from the previous test, with different words', aria: 'Gemini Fenrir voice reference', src: `${AUDIO_BASE}/en_gemini_target.mp3` },
      { id: 'en_all_zero_v5', title: 'Chatterbox V3 · zero-shot', aria: 'New English phrases · zero-shot', src: `${V5_AUDIO}/en_all_zero_v5.mp3` },
      { id: 'en_ep7_ft_newtext_v5', title: 'Chatterbox V3 · trained on ep7 only', aria: 'New English phrases · ep7 training', src: `${V5_AUDIO}/en_ep7_ft_newtext_v5.mp3` },
      { id: 'en_all_ft_v5', title: 'Chatterbox V3 · trained on English episodes 1–7', aria: 'New English phrases · episodes 1–7 training', src: `${V5_AUDIO}/en_all_ft_v5.mp3` },
      { id: 'en_azure_same_newtext_v1', title: 'Azure · Alloy Dragon HD · excited · same new phrases', aria: 'New English phrases · Azure Alloy Dragon HD', src: `${V5_AUDIO}/en_azure_same_newtext_v1.mp3` },
    ],
  }),
  audio({
    id: 'en-ep7-training',
    date: '2026-10-08',
    title: 'EN · ep7 training test',
    lang: 'en',
    chip: 'EN · ep7 training test',
    caption: 'English-only comparison using the same test phrases. The ep7 model uses 123 clips; the episodes 1–7 model uses the aligned 1,041-clip dataset. These ep5 phrases were absent from ep7 training and present in episodes 1–7 training. Natural pacing for these short comparisons. The first video below tests the new voice on the original one-minute timeline. voice source: newPoko sample dataset (vo/dataset-en-001, ep7), Chatterbox Multilingual V3, zero-shot or LoRA fine-tuned EN only according to the label.',
    clips: [
      { id: 'en_ep7_gemini', title: 'Gemini Fenrir · original reference', aria: 'Gemini Fenrir · original English reference', src: `${AUDIO_BASE}/en_gemini_target.mp3` },
      { id: 'en_ep7_zero_v4', title: 'Chatterbox V3 · ep7 voice reference · zero-shot', aria: 'English ep7 reference · zero-shot', src: `${EP7_AUDIO_BASE}/en_ep7_zero_v4.mp3` },
      { id: 'en_ep7_ft_pilot_v4', title: 'Chatterbox V3 · trained on English ep7 audio only', aria: 'English-only ep7 training', src: `${EP7_AUDIO_BASE}/en_ep7_ft_pilot_v4.mp3` },
      { id: 'en_all_ft_samephrase_v5', title: 'Chatterbox V3 · trained on English episodes 1–7 · same phrases', aria: 'English episodes 1–7 training · same phrases', src: `${V5_AUDIO}/en_all_ft_samephrase_v5.mp3` },
    ],
  }),
  audio({
    id: 'it-earlier',
    date: '2026-10-08',
    title: 'IT · earlier',
    lang: 'it',
    chip: 'IT · earlier',
    caption: "Prove brevi per confrontare pronuncia e timbro. Le versioni Chatterbox leggono le stesse frasi iniziali con ritmo naturale, senza accelerazione. Il riferimento è l'audio pulito del test Gemini Fenrir. Esperimento precedente bilingue: newPoko sample dataset (vo/dataset-en-001 + vo/dataset-it-001), 50 campioni; 46 training + 4 validazione.",
    clips: [
      { id: 'it_gemini_target', title: 'Gemini Fenrir · riferimento originale', src: `${AUDIO_BASE}/it_gemini_target.mp3` },
      { id: 'it_gemini_reference', title: 'Chatterbox V3 · riferimento Gemini · senza training', src: `${AUDIO_BASE}/it_gemini_reference.mp3` },
      { id: 'it_ft_v2', title: 'Chatterbox V3 · previous bilingual experiment · 50 EN + IT samples', src: `${AUDIO_BASE}/it_ft_v2.mp3` },
    ],
  }),
  audio({
    id: 'en-earlier',
    date: '2026-10-08',
    title: 'EN · earlier',
    lang: 'en',
    chip: 'EN · earlier',
    caption: "Riferimento Chatterbox: Gemini Fenrir Poko test, Chatterbox Multilingual V3; zero-shot oppure LoRA fine-tuned secondo l'etichetta.",
    clips: [
      { id: 'en_earlier_gemini', title: 'Gemini Fenrir · original reference', src: `${AUDIO_BASE}/en_gemini_target.mp3` },
      { id: 'en_gemini_reference', title: 'Chatterbox V3 · Gemini reference · zero-shot', src: `${AUDIO_BASE}/en_gemini_reference.mp3` },
      { id: 'en_ft_v2', title: 'Chatterbox V3 · previous bilingual experiment · 50 EN + IT samples', src: `${AUDIO_BASE}/en_ft_v2.mp3` },
    ],
  }),
  video({
    id: 'ep5-en',
    date: '2026-10-04',
    title: 'Full episode · English · Azure excited',
    src: 'https://cdn.pokoin.com/poko-video/ep5/poko_30th_excited_en_720p.mp4',
  }),
  video({
    id: 'ep5-it',
    date: '2026-10-04',
    lang: 'it',
    title: 'Full episode · Italiano · Azure excited',
    src: 'https://cdn.pokoin.com/poko-video/ep5/poko_30th_excited_it_720p.mp4',
  }),
  video({
    id: 'ep5-before',
    date: '2026-10-04',
    title: 'Full episode · English · Alloy Turbo (before)',
    src: 'https://cdn.pokoin.com/poko-video/ep5/poko_30th_alloy_turbo_en_720p.mp4',
  }),
];
