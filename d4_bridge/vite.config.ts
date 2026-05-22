import tailwindcss from '@tailwindcss/vite';
import react from '@vitejs/plugin-react';
import path from 'path';
import { defineConfig, loadEnv } from 'vite';

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, '.', '');
  return {
    // Served under /bridge/ in the unified static Render env (app.py mounts
    // /bridge → static/bridge/, mirroring D0's /terminal/). Vite emits asset
    // refs as /bridge/assets/... so they resolve under the prefix. Pair with
    // <BrowserRouter basename="/bridge"> in App.tsx.
    base: '/bridge/',
    plugins: [react(), tailwindcss()],
    define: {
      'process.env.GEMINI_API_KEY': JSON.stringify(env.GEMINI_API_KEY),
    },
    resolve: {
      alias: {
        '@': path.resolve(__dirname, '.'),
      },
    },
    server: {
      // HMR is disabled in AI Studio via DISABLE_HMR env var.
      hmr: process.env.DISABLE_HMR !== 'true',
    },
    build: {
      // Split heavy deps into their own chunks so they can be cached
      // independently and the initial route doesn't drag them in.
      // Combined with React.lazy() routes in App.tsx this lowers the
      // entry chunk size considerably.
      rollupOptions: {
        output: {
          manualChunks: {
            stripe: ['@stripe/stripe-js'],
            qr: ['html5-qrcode', 'qrcode.react'],
            motion: ['motion'],
          },
        },
      },
      chunkSizeWarningLimit: 700,
    },
  };
});
