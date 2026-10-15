import { render } from '@solidjs/web';
import './styles.css';
import { Router } from './router.js';
import App from './App.jsx';

render(
  () => <Router>{(props) => <App>{props.children}</App>}</Router>,
  document.getElementById('root'),
);
