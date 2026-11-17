import { defineConfig } from "vite";
export default defineConfig({
  base: "./",
  server: {
    port: 5173,
    proxy: {
      "/api": "http://127.0.0.1:8765",
      "/artwork": "http://127.0.0.1:8765",
    },
  },
  build: {
    outDir: "dist",
    emptyOutDir: false,
    manifest: true,
    rollupOptions: {
      input: { main: "index.html", renderer: "render-frame.html" },
    },
  },
});
