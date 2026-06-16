// Language context — English + Spanish (Hi.Events parity).
//
// Provides the active language + a t(key, vars) translator. Persists the choice
// to localStorage; first-load default follows the browser language (es → es,
// else en). English is the fallback for any missing key.

import { createContext, useCallback, useContext, useEffect, useState, type ReactNode } from 'react';
import { DICTS, en, type DictKey, type Lang } from '../lib/i18n/dict';

const STORAGE_KEY = 'exos.lang';

interface LanguageCtx {
  lang: Lang;
  setLang: (l: Lang) => void;
  t: (key: DictKey, vars?: Record<string, string | number>) => string;
}

const Ctx = createContext<LanguageCtx | null>(null);

function detectInitial(): Lang {
  try {
    const saved = localStorage.getItem(STORAGE_KEY);
    if (saved === 'en' || saved === 'es') return saved;
  } catch { /* ignore */ }
  const nav = (typeof navigator !== 'undefined' ? navigator.language : 'en') || 'en';
  return nav.toLowerCase().startsWith('es') ? 'es' : 'en';
}

function interpolate(template: string, vars?: Record<string, string | number>): string {
  if (!vars) return template;
  return template.replace(/\{(\w+)\}/g, (_, k) => (k in vars ? String(vars[k]) : `{${k}}`));
}

export function LanguageProvider({ children }: { children: ReactNode }) {
  const [lang, setLangState] = useState<Lang>(detectInitial);

  useEffect(() => {
    try { localStorage.setItem(STORAGE_KEY, lang); } catch { /* ignore */ }
    if (typeof document !== 'undefined') document.documentElement.lang = lang;
  }, [lang]);

  const setLang = useCallback((l: Lang) => setLangState(l), []);

  const t = useCallback<LanguageCtx['t']>((key, vars) => {
    const table = DICTS[lang] ?? en;
    const str = table[key] ?? en[key] ?? key;
    return interpolate(str, vars);
  }, [lang]);

  return <Ctx.Provider value={{ lang, setLang, t }}>{children}</Ctx.Provider>;
}

export function useLanguage(): LanguageCtx {
  const ctx = useContext(Ctx);
  if (!ctx) throw new Error('useLanguage must be used within LanguageProvider');
  return ctx;
}

/** Convenience hook — just the translator. */
export function useT() {
  return useLanguage().t;
}
