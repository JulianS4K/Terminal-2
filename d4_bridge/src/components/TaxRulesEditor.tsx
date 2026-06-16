// Organizer tax-rule manager (pretix parity).
//
// Self-contained CRUD embedded in EditEvent (light theme). Create reusable tax
// rules (rate + inclusive/exclusive) and assign one to each tier / add-on. The
// checkout edge fn applies them (exclusive → a Stripe Tax line; inclusive →
// recorded). Not part of the event form submit.

import { useEffect, useState } from 'react';
import { Plus, Trash2, Percent } from 'lucide-react';
import {
  listTaxRules, saveTaxRule, deleteTaxRule,
  listTaxableProducts, setProductTaxRule,
  type TaxRule, type TaxableProduct,
} from '../lib/tax';
import { useToast } from '../context/ToastContext';

const inputCls =
  'bg-slate-50 border-2 border-transparent rounded-2xl py-3 px-5 text-slate-900 font-bold ' +
  'focus:outline-none focus:border-brand-primary focus:bg-white transition-all shadow-inner';

export default function TaxRulesEditor({ eventId }: { eventId: string }) {
  const { toast } = useToast();
  const [rules, setRules] = useState<TaxRule[]>([]);
  const [products, setProducts] = useState<TaxableProduct[]>([]);
  const [loading, setLoading] = useState(true);
  const [busy, setBusy] = useState(false);
  const [name, setName] = useState('');
  const [rate, setRate] = useState('');
  const [inclusive, setInclusive] = useState(false);

  const reload = async () => {
    try {
      const [r, p] = await Promise.all([listTaxRules(eventId), listTaxableProducts(eventId)]);
      setRules(r); setProducts(p);
    } catch (e) { console.error('tax load failed:', e); }
    finally { setLoading(false); }
  };
  useEffect(() => { reload(); /* eslint-disable-next-line */ }, [eventId]);

  const add = async () => {
    if (!name.trim()) { toast({ kind: 'error', message: 'Tax rule needs a name.' }); return; }
    setBusy(true);
    try {
      await saveTaxRule(eventId, { name, ratePercent: parseFloat(rate) || 0, priceIncludesTax: inclusive });
      setName(''); setRate(''); setInclusive(false);
      await reload();
      toast({ kind: 'success', message: 'Tax rule saved.' });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not save tax rule.' });
    } finally { setBusy(false); }
  };

  const assign = async (p: TaxableProduct, ruleId: string) => {
    try {
      await setProductTaxRule(p, ruleId || null);
      await reload();
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not assign tax.' });
    }
  };

  if (loading) return null;

  return (
    <section className="bg-white p-10 rounded-[3rem] border border-slate-100 shadow-xl space-y-6">
      <div className="flex items-center space-x-3 mb-2">
        <Percent className="text-brand-primary w-5 h-5" />
        <h2 className="text-xs font-bold text-slate-400 uppercase tracking-widest leading-none">Tax / VAT</h2>
      </div>
      <p className="text-slate-400 text-xs font-bold -mt-2">
        Reusable rates assignable to tiers &amp; add-ons. "Included" = tax embedded in the price; otherwise it's added at checkout.
      </p>

      {rules.length > 0 && (
        <div className="space-y-2">
          {rules.map((r) => (
            <div key={r.id} className="flex items-center justify-between bg-slate-50 rounded-2xl px-5 py-3">
              <p className="font-bold text-slate-900 text-sm">
                {r.name} · {r.ratePercent}% · {r.priceIncludesTax ? 'included' : 'added'}
              </p>
              <button type="button" onClick={() => deleteTaxRule(r.id).then(reload)} className="text-slate-300 hover:text-red-500" aria-label={`Delete ${r.name}`}>
                <Trash2 className="w-4 h-4" />
              </button>
            </div>
          ))}
        </div>
      )}

      <div className="grid grid-cols-2 gap-4">
        <input value={name} onChange={(e) => setName(e.target.value)} placeholder="Name (e.g. VAT 19%)" className={`col-span-2 ${inputCls}`} />
        <input value={rate} onChange={(e) => setRate(e.target.value)} type="number" min={0} max={100} step="0.001" placeholder="Rate %" className={inputCls} />
        <label className="flex items-center gap-2 text-xs font-bold text-slate-500 px-2">
          <input type="checkbox" checked={inclusive} onChange={(e) => setInclusive(e.target.checked)} />
          Price includes tax
        </label>
      </div>
      <button type="button" disabled={busy} onClick={add} className="w-full flex items-center justify-center space-x-2 bg-slate-900 hover:bg-slate-800 text-white py-3 rounded-2xl font-black uppercase tracking-tighter italic text-xs transition-all disabled:opacity-50">
        <Plus className="w-4 h-4" /><span>{busy ? 'Saving…' : 'Add tax rule'}</span>
      </button>

      {rules.length > 0 && products.length > 0 && (
        <div className="pt-4 border-t border-slate-100 space-y-2">
          <p className="text-[10px] font-black text-slate-400 uppercase tracking-widest">Assign to products</p>
          {products.map((p) => (
            <div key={`${p.kind}-${p.id}`} className="flex items-center justify-between gap-3">
              <span className="text-sm font-bold text-slate-700 truncate">
                {p.name} <span className="text-slate-300 text-xs">{p.kind}</span>
              </span>
              <select
                value={p.taxRateId ?? ''}
                onChange={(e) => assign(p, e.target.value)}
                className="border-2 border-slate-200 rounded-lg px-3 py-1.5 text-sm font-bold focus:border-slate-900 outline-none"
              >
                <option value="">No tax</option>
                {rules.map((r) => <option key={r.id} value={r.id}>{r.name}</option>)}
              </select>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}
