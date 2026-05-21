import { StrictMode } from 'react';
import { createRoot } from 'react-dom/client';
import App from './App.tsx';
import './index.css';
import { registerServiceWorker } from './lib/registerSW';

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);

// Register the service worker AFTER React mounts. The toast wiring
// happens inside the app via ToastProvider, so SW-update prompts
// land in the same toast queue as everything else once the user has
// the app running. registerServiceWorker handles its own
// 'serviceWorker' in navigator guard.
registerServiceWorker();
