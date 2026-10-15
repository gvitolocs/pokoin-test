import { For, Show } from 'solid-js';
import tests from '../../public/review/tests.json';
import TestDock from '../components/TestDock.jsx';
import { MEDIA_BASE } from '../lib/media.js';
import { BoardBar, usePageTitle } from './tools/board.jsx';
import { testsByMonth } from './poko-tests.js';

// Longer "what this board is for" copy, keyed by route. Falls back to the
// dock note when a board has no entry here.
const ABOUT = {
  '/sanitize': 'Deskew and clean the leftover-print scans: bright-edge crop, rotation, and the GPU deskew variants, shown before / after.',
  '/espurr': 'Confirm the same painting is grouped across its JP / EN / CN printings so one artwork cluster stays one cluster.',
  '/ocr': 'Read expansion and print language straight off the card with Qwen3-VL on the leftover print.',
  '/ocr/artists': 'Match the OCR-read illustrator credit to the pokemontcg.io artist table.',
  '/artwork': 'Pokémon-only album hover masks: Qwen3-VL boxes → SAM 2.1 silhouettes, with the whole-silhouette before / after.',
  '/jumbos': 'Every Jumbo Oversized leftover in one grid — homepage tiles with full-resolution links, so wrong pixels under a right name get caught.',
  '/poko': 'Poko episodes, dubs and voice tests by month — newest first.',
  '/poko/archive': 'newPoko Gemini Fenrir archive: EN/IT dataset phrases plus remade English episode lines (ep1–ep7), with scripts.',
};

const BOARDS = tests.tests.filter((board) => board.path !== '/tests');
const MONTHS = testsByMonth(BOARDS);

function aboutFor(board) {
  const path = board.path.split('#')[0];
  return ABOUT[path] || '';
}

/** test.pokoin.com Test boards index (D00006L). */
export default function TestsDashboard() {
  usePageTitle('Test boards · test.pokoin.com');

  return (
    <div class="sanitize tests-dashboard">
      <BoardBar host="test.pokoin.com · dashboard" />

      <main class="sanitize-main">
        <p class="sanitize-kicker">Internal review boards</p>
        <h1>Test boards</h1>
        <p class="sanitize-lead">
          One place for every review surface. Each board is a snapshot of a pipeline
          stage — open one to inspect the current output. These are internal tools,
          not production pages.
        </p>

        <For each={MONTHS}>
          {(month) => (
            <section class="poko-video tests-dashboard-month" aria-label={month.label}>
              <h2>{month.label}</h2>
              <div class="tests-grid">
                <For each={month.tests}>
                  {(board) => (
                    <a href={board.path} class="tests-card">
                      <Show when={board.kind === 'video' && board.poster}>
                        <img
                          class="tests-card-poster"
                          src={`${MEDIA_BASE}/${board.poster}`}
                          alt=""
                          loading="lazy"
                        />
                      </Show>
                      <div class="tests-card-head">
                        <h2>{board.label}</h2>
                        <time datetime={board.date}>{board.date}</time>
                      </div>
                      <p class="tests-card-note">{board.note}</p>
                      <p class="tests-card-about">{aboutFor(board)}</p>
                      <span class="tests-card-path">{board.path}</span>
                    </a>
                  )}
                </For>
              </div>
            </section>
          )}
        </For>
      </main>

      <TestDock />
    </div>
  );
}
