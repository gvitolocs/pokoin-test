import { Errored, Loading, Show } from 'solid-js';

function RoutePending() {
  return <div class="sanitize" style={{ 'min-height': '55vh' }} role="status" aria-busy="true" />;
}

function RouteError(props) {
  const detail = String(props.error?.message || props.error || '').slice(0, 200);
  return (
    <div class="sanitize-main" role="alert">
      <p>Something went wrong loading this page.</p>
      <Show when={detail}>
        <p style={{ color: 'var(--muted)', 'font-size': '0.8rem' }}>{detail}</p>
      </Show>
      <button type="button" class="linkish" onClick={() => props.reset()}>Try again</button>
    </div>
  );
}

/** The boards render bare: no marketplace header, cart, or chat. */
export default function App(props) {
  return (
    <Errored fallback={(err, reset) => <RouteError error={err()} reset={reset} />}>
      <Loading fallback={<RoutePending />}>{props.children}</Loading>
    </Errored>
  );
}
