import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';

export default defineConfig({
  base: './',
  plugins: [react()],
  optimizeDeps: { exclude: ['@electric-sql/pglite'] },
  server: { fs: { allow: ['..'] } },
  build: {
    target: 'es2022',
    rollupOptions: { input: { index: 'index.html', admin: 'admin.html' } },
  },
});
