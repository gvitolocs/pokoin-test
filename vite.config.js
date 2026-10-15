import { defineConfig } from 'vite';
import solid from '@solidjs/vite-plugin';

/** OCR scans and artwork mask previews still request `/card-images/*`.
 * CardArt itself talks to cdn.pokoin.com directly. */
const cardImages = {
  '/card-images': {
    target: 'https://cdn.pokoin.com',
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
