// EN / ES language toggle (Hi.Events parity). Compact pill for the navbar.

import { useLanguage } from '../context/LanguageContext';
import type { Lang } from '../lib/i18n/dict';

export default function LanguageSwitcher() {
  const { lang, setLang } = useLanguage();
  const opts: Lang[] = ['en', 'es'];
  return (
    <div className="flex items-center border border-white/10" role="group" aria-label="Language">
      {opts.map((l) => (
        <button
          key={l}
          type="button"
          onClick={() => setLang(l)}
          aria-pressed={lang === l}
          className={`px-2 py-1 text-[10px] font-black uppercase tracking-widest transition-all ${
            lang === l ? 'bg-white text-black' : 'text-white/40 hover:text-white'
          }`}
        >
          {l}
        </button>
      ))}
    </div>
  );
}
