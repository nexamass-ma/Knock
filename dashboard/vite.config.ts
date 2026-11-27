import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  base: './',
  plugins: [react()],
  optimizeDeps: { exclude: ['@electric-sql/pglite'] },
  server: { fs: { allow: ['..'] } },
  build: {
    target: 'es2022',
    rollupOptions: {
      input: { index: 'index.html', admin: 'admin.html' },
      // PGlite's filesystem bundle is a binary ".data" file. Some static hosts
      // (including the preview host) only serve known web types, so ship it
      // with a binary-safe extension. PGlite fetches it by URL either way.
      output: { assetFileNames: (a) => (a.names?.[0] ?? a.name ?? '').endsWith('.data') ? 'assets/[name]-[hash].data.wasm' : 'assets/[name]-[hash][extname]' },
    },
  },
});
