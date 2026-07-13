// SetTimesEditor — optional lineup / set-time rows for the event Create/Edit
// forms. A venue or promoter can add "Opener 8:00", "Headliner 9:30", etc., or
// leave it empty (most events have no set times). Purely a controlled editor on
// SetTimeRow[] — the parent owns the timezone→UTC conversion (lib/setTimes.ts),
// so this component has no date logic and is trivial to reuse in both forms.

import { Plus, X, Clock } from 'lucide-react';
import type { SetTimeRow } from '../lib/setTimes';
import { MAX_SET_TIMES } from '../lib/setTimes';

interface Props {
  rows: SetTimeRow[];
  onChange: (rows: SetTimeRow[]) => void;
  /** Optional hint shown under the header, e.g. the venue timezone. */
  timezoneNote?: string;
}

export default function SetTimesEditor({ rows, onChange, timezoneNote }: Props) {
  const update = (i: number, patch: Partial<SetTimeRow>) =>
    onChange(rows.map((r, idx) => (idx === i ? { ...r, ...patch } : r)));
  const add = () => onChange([...rows, { label: '', local: '' }]);
  const remove = (i: number) => onChange(rows.filter((_, idx) => idx !== i));

  return (
    <div className="space-y-3">
      <div className="flex items-baseline justify-between">
        <label className="type text-[10px] text-white/40 uppercase tracking-widest ml-1 flex items-center gap-2">
          <Clock className="w-3 h-3" aria-hidden="true" /> Set Times
          <span className="text-white/25 normal-case tracking-normal">optional</span>
        </label>
        {timezoneNote ? (
          <span className="type text-[10px] text-white/25 tracking-widest">{timezoneNote}</span>
        ) : null}
      </div>

      {rows.length === 0 ? (
        <p className="type text-[11px] text-white/30 ml-1">
          No set times. Add the lineup schedule (opener, headliner…) if you have one.
        </p>
      ) : (
        <div className="space-y-2">
          {rows.map((row, i) => (
            <div key={i} className="flex items-center gap-2">
              <input
                type="text"
                value={row.label}
                maxLength={80}
                placeholder="e.g. Headliner"
                onChange={(e) => update(i, { label: e.target.value })}
                className="flex-1 min-w-0 bg-black border border-white/20 py-3 px-4 text-white font-bold text-sm focus:outline-none focus:border-brand-primary transition-colors"
              />
              <input
                type="datetime-local"
                value={row.local}
                onChange={(e) => update(i, { local: e.target.value })}
                onClick={(e) => {
                  const el = e.currentTarget as HTMLInputElement;
                  if (typeof el.showPicker === 'function') {
                    try {
                      el.showPicker();
                    } catch {
                      /* user-gesture errors are non-fatal */
                    }
                  }
                }}
                className="bg-black border border-white/20 py-3 px-3 text-white font-bold text-sm focus:outline-none focus:border-brand-primary transition-colors cursor-pointer"
              />
              <button
                type="button"
                onClick={() => remove(i)}
                aria-label={`Remove set time ${i + 1}`}
                className="shrink-0 p-2 text-white/30 hover:text-rose-400 transition-colors"
              >
                <X className="w-4 h-4" aria-hidden="true" />
              </button>
            </div>
          ))}
        </div>
      )}

      {rows.length < MAX_SET_TIMES ? (
        <button
          type="button"
          onClick={add}
          className="flex items-center gap-2 type text-[10px] uppercase tracking-widest text-white/50 hover:text-white transition-colors ml-1"
        >
          <Plus className="w-3.5 h-3.5" aria-hidden="true" /> Add set time
        </button>
      ) : null}
    </div>
  );
}
