// Organizer add-on (merch) manager.
//
// Self-contained CRUD section embedded in EditEvent. Manages exos_event_addons
// directly (its own load/save, NOT part of the event form submit) so it stays
// decoupled from the tier/capacity validation in the main form. Light-themed to
// match EditEvent's section styling.

import { useEffect, useState } from 'react';
import { Plus, Trash2, Package } from 'lucide-react';
import { listEventAddons, saveAddon, deleteAddon, type AddonInput } from '../lib/addons';
import { useToast } from '../context/ToastContext';

type Row = AddonInput & { id?: string; sold?: number };

const BLANK: Row = { name: '', description: '', price: 0, capacity: 0, visibility: 'public' };

const inputCls =
  'w-full bg-slate-50 border-2 border-transparent rounded-2xl py-3 px-5 text-slate-900 font-bold ' +
  'focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner';

export default function AddonsEditor({ eventId }: { eventId: string }) {
  const { toast } = useToast();
  const [rows, setRows] = useState<Row[]>([]);
  const [draft, setDraft] = useState<Row>({ ...BLANK });
  const [saving, setSaving] = useState(false);
  const [loading, setLoading] = useState(true);

  const reload = async () => {
    try {
      const list = await listEventAddons(eventId);
      setRows(list.map((a) => ({
        id: a.id, name: a.name, description: a.description ?? '', price: a.price,
        capacity: a.capacity, maxPerOrder: a.maxPerOrder, visibility: a.visibility,
        imageUrl: a.imageUrl, sortOrder: a.sortOrder, sold: a.sold,
      })));
    } catch (e) {
      console.error('listEventAddons failed:', e);
    } finally {
      setLoading(false);
    }
  };

  useEffect(() => { reload(); /* eslint-disable-next-line */ }, [eventId]);

  const add = async () => {
    if (!draft.name.trim()) {
      toast({ kind: 'error', message: 'Add-on needs a name.' });
      return;
    }
    setSaving(true);
    try {
      await saveAddon(eventId, draft);
      setDraft({ ...BLANK });
      await reload();
      toast({ kind: 'success', message: 'Add-on saved.' });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not save add-on.' });
    } finally {
      setSaving(false);
    }
  };

  const remove = async (id?: string) => {
    if (!id) return;
    try {
      await deleteAddon(id);
      await reload();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not delete add-on.' });
    }
  };

  if (loading) return null;

  return (
    <section className="bg-white p-10 rounded-[3rem] border border-slate-100 shadow-xl space-y-6">
      <div className="flex items-center space-x-3 mb-2">
        <Package className="text-brand-primary w-5 h-5" />
        <h2 className="text-xs font-bold text-slate-400 uppercase tracking-widest leading-none">Add-ons & Merch</h2>
      </div>
      <p className="text-slate-400 text-xs font-bold -mt-2">
        Optional extras sold alongside tickets — t-shirts, parking, meet &amp; greet. Price 0 = free extra.
      </p>

      {rows.length > 0 && (
        <div className="space-y-2">
          {rows.map((r) => (
            <div key={r.id} className="flex items-center justify-between bg-slate-50 rounded-2xl px-5 py-3">
              <div className="min-w-0 pr-3">
                <p className="font-bold text-slate-900 text-sm truncate">{r.name}</p>
                <p className="text-slate-400 text-xs font-bold">
                  ${Number(r.price).toFixed(2)}
                  {r.capacity ? ` · ${r.sold ?? 0}/${r.capacity} sold` : ' · unlimited'}
                  {r.visibility === 'hidden' ? ' · hidden' : ''}
                </p>
              </div>
              <button
                type="button"
                onClick={() => remove(r.id)}
                className="text-slate-300 hover:text-red-500 shrink-0 transition-colors"
                aria-label={`Delete ${r.name}`}
              >
                <Trash2 className="w-4 h-4" />
              </button>
            </div>
          ))}
        </div>
      )}

      <div className="grid grid-cols-2 gap-4">
        <input
          value={draft.name}
          onChange={(e) => setDraft({ ...draft, name: e.target.value })}
          placeholder="Name (e.g. T-Shirt)"
          className={`col-span-2 ${inputCls}`}
        />
        <input
          value={draft.description ?? ''}
          onChange={(e) => setDraft({ ...draft, description: e.target.value })}
          placeholder="Description (optional)"
          className={`col-span-2 ${inputCls}`}
        />
        <label className="space-y-1">
          <span className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">Price ($)</span>
          <input
            type="number" min={0} step="0.01" value={draft.price}
            onChange={(e) => setDraft({ ...draft, price: parseFloat(e.target.value) || 0 })}
            className={inputCls}
          />
        </label>
        <label className="space-y-1">
          <span className="text-[9px] font-bold text-slate-400 uppercase tracking-widest ml-1">Capacity (0 = ∞)</span>
          <input
            type="number" min={0} value={draft.capacity ?? 0}
            onChange={(e) => setDraft({ ...draft, capacity: parseInt(e.target.value, 10) || 0 })}
            className={inputCls}
          />
        </label>
      </div>
      <button
        type="button"
        disabled={saving}
        onClick={add}
        className="w-full flex items-center justify-center space-x-2 bg-slate-900 hover:bg-slate-800 text-white py-3 rounded-2xl font-black uppercase italic tracking-tighter text-xs transition-all disabled:opacity-50"
      >
        <Plus className="w-4 h-4" />
        <span>{saving ? 'Saving…' : 'Add add-on'}</span>
      </button>
    </section>
  );
}
