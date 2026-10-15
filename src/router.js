import { lazy } from 'solid-js';
import { createRouter } from '@solidjs/router';
import RedirectTo from './pages/RedirectTo.jsx';
import UnknownPath from './pages/UnknownPath.jsx';

const TestsDashboard = lazy(() => import('./pages/TestsDashboard.jsx'));
const Sanitize = lazy(() => import('./pages/Sanitize.jsx'));
const Espurr = lazy(() => import('./pages/Espurr.jsx'));
const Ocr = lazy(() => import('./pages/Ocr.jsx'));
const OcrArtists = lazy(() => import('./pages/OcrArtists.jsx'));
const ArtworkHover = lazy(() => import('./pages/ArtworkHover.jsx'));
const JumbosBoard = lazy(() => import('./pages/JumbosBoard.jsx'));
const PokoVideoBoard = lazy(() => import('./pages/PokoVideoBoard.jsx'));
const PokoArchive = lazy(() => import('./pages/PokoArchive.jsx'));

function board(path, component) {
  return [
    { path, component },
    { path: `${path}/`, component },
  ];
}

export const Router = createRouter({
  routes: [
    { path: '/', component: RedirectTo, info: { to: '/tests' } },
    ...board('/tests', TestsDashboard),
    ...board('/sanitize', Sanitize),
    ...board('/espurr', Espurr),
    ...board('/ocr/artists', OcrArtists),
    ...board('/ocr', Ocr),
    ...board('/artwork', ArtworkHover),
    ...board('/jumbos', JumbosBoard),
    ...board('/poko/archive', PokoArchive),
    ...board('/poko', PokoVideoBoard),
    { path: '*404', component: UnknownPath },
  ],
});
