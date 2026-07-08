// PwaShell — three small, defensive UI affordances that make the app
// feel installed:
//
//   * SwUpdateBanner: when registerSW dispatches the SW_UPDATE_EVENT
//     (a new SW finished installing in the background), surface a
//     fixed banner with a Reload button. User stays in control of
//     when the new build kicks in.
//
//   * OfflineBanner: listens to navigator.onLine + the corresponding
//     'online' / 'offline' window events. When offline, shows a
//     small banner so the user knows why API calls are failing — vs
//     thinking the app is broken.
//
//   * InstallPrompt: captures the 'beforeinstallprompt' event on
//     supported browsers (Chrome/Edge desktop + Android) and renders
//     a one-shot CTA. Dismissed-state persists so we don't nag.
//
// All three render as fixed banners stacked at the bottom of the
// viewport so they don't compete with the navbar or shift content.
// Mounted once at the App root, inside the providers.

import { useEffect, useState } from 'react';
import { Download, RefreshCw, WifiOff, X } from 'lucide-react';
import { SW_UPDATE_EVENT, SwUpdatePayload } from '../lib/registerSW';

const INSTALL_DISMISSED_KEY = 'vibepass:install-dismissed';

interface BeforeInstallPromptEvent extends Event {
  prompt: () => Promise<void>;
  userChoice: Promise<{ outcome: 'accepted' | 'dismissed' }>;
}

export default function PwaShell() {
  return (
    <>
      <SwUpdateBanner />
      <OfflineBanner />
      <InstallPrompt />
    </>
  );
}

function SwUpdateBanner() {
  const [apply, setApply] = useState<(() => void) | null>(null);

  useEffect(() => {
    function onUpdate(e: Event) {
      const ce = e as CustomEvent<SwUpdatePayload>;
      // Wrap the apply fn in a stable closure so React's setState
      // doesn't try to invoke it as a setter callback.
      setApply(() => ce.detail.apply);
    }
    window.addEventListener(SW_UPDATE_EVENT, onUpdate);
    return () => window.removeEventListener(SW_UPDATE_EVENT, onUpdate);
  }, []);

  if (!apply) return null;

  return (
    <div className="fixed bottom-4 left-4 right-4 md:left-auto md:right-4 md:max-w-sm z-50 bg-brand-primary text-black border-2 border-black p-4 shadow-2xl">
      <div className="flex items-start gap-3">
        <RefreshCw size={18} className="flex-shrink-0 mt-0.5" />
        <div className="flex-1 min-w-0">
          <p className="disp text-base tracking-wide uppercase leading-none">Update Available</p>
          <p className="type text-xs mt-1 opacity-80">A new version is ready. Reload to apply.</p>
        </div>
        <button
          onClick={apply}
          className="disp bg-black text-brand-primary px-3 py-1.5 text-sm tracking-wide uppercase hover:bg-white hover:text-black transition-all"
        >
          Reload
        </button>
      </div>
    </div>
  );
}

function OfflineBanner() {
  // navigator.onLine is best-effort but it's good enough for the
  // "we lost the network" case we're trying to surface. False
  // positives (claiming we're online when we aren't) are caught by
  // the actual fetch failures elsewhere.
  const [online, setOnline] = useState(() =>
    typeof navigator === 'undefined' ? true : navigator.onLine,
  );

  useEffect(() => {
    function onOnline() {
      setOnline(true);
    }
    function onOffline() {
      setOnline(false);
    }
    window.addEventListener('online', onOnline);
    window.addEventListener('offline', onOffline);
    return () => {
      window.removeEventListener('online', onOnline);
      window.removeEventListener('offline', onOffline);
    };
  }, []);

  if (online) return null;

  return (
    <div
      role="status"
      className="fixed top-0 left-0 right-0 z-50 bg-amber-500 text-black px-4 py-2 text-center type text-[10px] uppercase tracking-widest flex items-center justify-center gap-2"
    >
      <WifiOff size={14} />
      Offline — some features won't work until you're back online
    </div>
  );
}

function InstallPrompt() {
  const [evt, setEvt] = useState<BeforeInstallPromptEvent | null>(null);
  const [dismissed, setDismissed] = useState(() => {
    try {
      return localStorage.getItem(INSTALL_DISMISSED_KEY) === '1';
    } catch {
      return false;
    }
  });

  useEffect(() => {
    function onPrompt(e: Event) {
      // Stash the event so we can fire it on user-gesture later.
      // The browser only delivers this when the PWA install criteria
      // are met (HTTPS, valid manifest, registered SW, not already
      // installed, engagement heuristic).
      e.preventDefault();
      setEvt(e as BeforeInstallPromptEvent);
    }
    window.addEventListener('beforeinstallprompt', onPrompt);
    return () => window.removeEventListener('beforeinstallprompt', onPrompt);
  }, []);

  if (!evt || dismissed) return null;

  function dismiss() {
    setDismissed(true);
    try {
      localStorage.setItem(INSTALL_DISMISSED_KEY, '1');
    } catch {
      /* ignore */
    }
  }

  async function install() {
    if (!evt) return;
    try {
      await evt.prompt();
      const { outcome } = await evt.userChoice;
      // Either way, clear the prompt so we don't try to fire it twice.
      setEvt(null);
      if (outcome === 'dismissed') dismiss();
    } catch (err) {
      console.warn('Install prompt failed:', err);
      setEvt(null);
    }
  }

  return (
    <div className="fixed bottom-4 left-4 right-4 md:left-auto md:right-4 md:max-w-sm z-40 bg-black border border-white/10 text-white p-4 shadow-2xl">
      <button
        onClick={dismiss}
        aria-label="Dismiss install prompt"
        className="absolute top-2 right-2 p-1 text-white/40 hover:text-white transition-all"
      >
        <X size={14} />
      </button>
      <div className="flex items-start gap-3 pr-6">
        <Download size={18} className="flex-shrink-0 mt-0.5 text-brand-primary" />
        <div className="flex-1 min-w-0">
          <p className="disp text-base tracking-wide uppercase leading-none">Install Exos</p>
          <p className="type text-xs mt-1 text-white/60">
            Faster, full-screen, works offline for tickets you've already loaded.
          </p>
          <button
            onClick={install}
            className="disp mt-3 bg-brand-primary text-black px-3 py-1.5 text-sm tracking-wide uppercase hover:bg-white transition-all"
          >
            Install
          </button>
        </div>
      </div>
    </div>
  );
}
