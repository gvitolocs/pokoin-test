import { defineConfig } from 'vite';
import solid from '@solidjs/vite-plugin';
import { MEDIA_BASE } from './src/lib/media.js';

/** OCR scans and artwork mask previews request `/card-images/*` → test media (R2). */
const cardImages = {
  '/card-images': {
    target: MEDIA_BASE,
    changeOrigin: true,
    rewrite: (pathname) => pathname.replace(/^\/card-images/, ''),
  },
};

export default defineConfig({
  plugins: [solid()],
  build: { target: 'es2022' },
  server: {
    host: '0.0.0.0',
    port: 5175,
    proxy: cardImages,
  },
  preview: {
    host: '0.0.0.0',
    port: 4175,
    proxy: cardImages,
  },
});
