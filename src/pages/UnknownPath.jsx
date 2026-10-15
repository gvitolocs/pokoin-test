import { BoardBar, usePageTitle } from './tools/board.jsx';

export default function UnknownPath() {
  usePageTitle('Not found · test.pokoin.com');
  return (
    <div class="sanitize">
      <BoardBar host="test.pokoin.com" />
      <main class="sanitize-main">
        <h1>No board on this path</h1>
        <p class="sanitize-lead">
          <a class="linkish" href="/tests">All test boards</a>
        </p>
      </main>
    </div>
  );
}
