import { defineConfig } from '../../studio/node_modules/vite/dist/node/index.js';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const here = path.dirname(fileURLToPath(import.meta.url));
export default defineConfig({
  root: path.resolve(here, '../../studio'),
  resolve: {dedupe: ['katex', 'markdown-it', 'dompurify']},
  build: {
    outDir: path.resolve(here, '../App/Resources/Renderer'), emptyOutDir: false,
    lib: {entry: path.join(here, 'entry.ts'), name: 'HajiRenderer', formats: ['iife'], fileName: () => 'renderer.js', cssFileName: 'renderer'},
    rollupOptions: {output: {inlineDynamicImports: true}},
    assetsInlineLimit: 0,
  },
});
