import { For, Match, Show, Switch } from 'solid-js';
import TestDock from '../components/TestDock.jsx';
import { BoardBar, usePageTitle } from './tools/board.jsx';
import { blocksFor, formatDay, POKO_TESTS, testsByMonth } from './poko-tests.js';

const MONTHS = testsByMonth(POKO_TESTS);

function TileDate(props) {
  return <time class="poko-tile-sub" datetime={props.date}>{formatDay(props.date)}</time>;
}

function VideoTile(props) {
  return (
    <li class="poko-tile" id={props.test.id} lang={props.test.lang}>
      <TileDate date={props.test.date} />
      <strong>{props.test.title}</strong>
      <video controls preload="metadata" playsinline poster={props.test.poster} src={props.test.src} />
      <Show when={props.test.note}><p class="poko-caption">{props.test.note}</p></Show>
      <p class="poko-tile-links">
        <a href={props.test.src} target="_blank" rel="noopener noreferrer">Open MP4</a>
        <Show when={props.test.voiceover}>
          <a href={props.test.voiceover} target="_blank" rel="noopener noreferrer">Download voiceover WAV · PCM 24-bit</a>
        </Show>
      </p>
    </li>
  );
}

function AudioSet(props) {
  return (
    <div class="poko-clip-group" lang={props.test.lang}>
      <h3>{props.test.title}</h3>
      <Show when={props.test.intro}><p>{props.test.intro}</p></Show>
      <ul class="poko-tiles poko-ab">
        <For each={props.test.clips}>
          {(clip) => (
            <li class="poko-tile" id={clip.id} lang={clip.lang || props.test.lang}>
              <TileDate date={clip.date || props.test.date} />
              <Show when={props.test.chip || clip.chips?.length}>
                <span class="poko-chip-row">
                  <Show when={props.test.chip}><span class="poko-chip">{props.test.chip}</span></Show>
                  <For each={clip.chips ?? []}>{(chip) => <span class="poko-chip">{chip}</span>}</For>
                </span>
              </Show>
              <strong>{clip.title}</strong>
              <Show when={clip.sub}><span class="poko-tile-sub">{clip.sub}</span></Show>
              <audio controls preload="metadata" aria-label={clip.aria || clip.title} src={clip.src} />
            </li>
          )}
        </For>
      </ul>
      <Show when={props.test.caption}><p class="poko-caption">{props.test.caption}</p></Show>
    </div>
  );
}

/** Every Poko picture and voice test, grouped by month. */
export default function PokoVideoBoard() {
  usePageTitle('Poko · tests by month · test.pokoin.com');

  return (
    <div class="sanitize poko-video-board">
      <BoardBar host="test.pokoin.com · poko" />

      <main class="sanitize-main">
        <p class="sanitize-kicker">Internal review boards</p>
        <h1>Poko tests</h1>
        <p class="sanitize-lead">
          Every picture and voice test, newest month first. Each tile shows the day that test was published.
          The newPoko clip archive stays at <a href="/poko/archive">/poko/archive</a>.
        </p>

        <For each={MONTHS}>
          {(month) => (
            <section id={`poko-${month.id}`} class="poko-video">
              <h2>{month.label}</h2>
              <p class="sanitize-note">{month.tests.length} tests</p>
              <For each={blocksFor(month.tests)}>
                {(block) => (
                  <Switch>
                    <Match when={block.kind === 'videos'}>
                      <ul class="poko-tiles poko-videos">
                        <For each={block.tests}>{(test) => <VideoTile test={test} />}</For>
                      </ul>
                    </Match>
                    <Match when={block.kind === 'audio'}>
                      <AudioSet test={block.test} />
                    </Match>
                  </Switch>
                )}
              </For>
            </section>
          )}
        </For>

        <section class="poko-block">
          <h2>newPoko voice archive</h2>
          <div class="poko-tiles">
            <div class="poko-tile">
              <a class="poko-tile-title" href="/poko/archive">newPoko archive</a>
              <span class="poko-tile-sub">1,091 Gemini Fenrir clips · dataset + episodes 1–7</span>
              <p class="poko-caption">Dataset phrases and remade episode lines</p>
            </div>
          </div>
        </section>
      </main>

      <TestDock />
    </div>
  );
}
