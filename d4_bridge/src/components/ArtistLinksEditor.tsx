// ArtistLinksEditor — per-performer link inputs. Derives its rows from the
// performers the organizer has already entered (so an artist row's name always
// matches a performer name), and lets them paste a Spotify / Apple Music /
// Bandsintown / social URL or handle for each. Controlled: reads the current
// ArtistLink[] and emits the upserted array on every edit.
//
// Empty rows are pruned as they empty out; final trimming/omission happens at
// save time via normalizeArtistLinks (lib/artistLinks.ts).

import type { ArtistLink } from '../types';
import {
  ARTIST_PLATFORMS,
  ArtistPlatform,
  ARTIST_LINK_MAX_LEN,
  hasAnyLink,
  linksForArtist,
} from '../lib/artistLinks';

interface Props {
  performers: string[];
  value: ArtistLink[];
  onChange: (links: ArtistLink[]) => void;
}

export default function ArtistLinksEditor({ performers, value, onChange }: Props) {
  const names = performers.map((p) => p.trim()).filter(Boolean);

  function setField(name: string, platform: ArtistPlatform, raw: string) {
    const key = name.toLowerCase();
    const others = value.filter((l) => l.name.trim().toLowerCase() !== key);
    const existing = linksForArtist(name, value);
    const updated: ArtistLink = { ...(existing ?? { name }), name };
    const val = raw.slice(0, ARTIST_LINK_MAX_LEN);
    if (val.trim()) updated[platform] = val;
    else delete updated[platform];
    onChange(hasAnyLink(updated) ? [...others, updated] : others);
  }

  if (names.length === 0) {
    return (
      <p className="text-[9px] text-slate-300 font-bold uppercase tracking-widest leading-relaxed ml-1">
        Add performers above to attach their Spotify, Bandsintown & social links.
      </p>
    );
  }

  return (
    <div className="space-y-4">
      {names.map((name) => {
        const row = linksForArtist(name, value);
        return (
          <div key={name} className="bg-slate-50 rounded-2xl p-5 space-y-3">
            <p className="text-xs font-black text-slate-900 uppercase tracking-tighter italic truncate">
              {name}
            </p>
            <div className="grid grid-cols-1 sm:grid-cols-2 gap-3">
              {ARTIST_PLATFORMS.map(({ key, label, placeholder }) => (
                <div key={key} className="space-y-1">
                  <label className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">
                    {label}
                  </label>
                  <input
                    type="text"
                    inputMode="url"
                    placeholder={placeholder}
                    maxLength={ARTIST_LINK_MAX_LEN}
                    className="w-full bg-white border-2 border-transparent rounded-xl py-2.5 px-4 text-sm text-slate-900 font-semibold focus:outline-none focus:border-brand-primary transition-all shadow-inner"
                    value={row?.[key] ?? ''}
                    onChange={(e) => setField(name, key, e.target.value)}
                  />
                </div>
              ))}
            </div>
          </div>
        );
      })}
    </div>
  );
}
