// Buyer-facing product add-on (merch) selector.
//
// Rendered on EventDetails above the buy button. Lists the event's public
// add-ons with quantity steppers and reports the current selection (+ its
// dollar total) up to the parent, which folds it into checkout / free claim.

import { useEffect, useState } from 'react';
import { Plus, Minus } from 'lucide-react';
import { listPublicAddons, type PublicAddon } from '../lib/addons';
import { formatCurrency } from '../lib/utils';

export interface AddonSelection {
  items: { addon_id: string; quantity: number }[];
  totalCents: number;
}

interface Props {
  eventId: string;
  currency?: string;
  onChange: (sel: AddonSelection) => void;
}

export default function AddonSelector({ eventId, currency = 'USD', onChange }: Props) {
  const [addons, setAddons] = useState<PublicAddon[]>([]);
  const [qty, setQty] = useState<Record<string, number>>({});

  useEffect(() => {
    let alive = true;
    listPublicAddons(eventId)
      .then((a) => { if (alive) setAddons(a); })
      .catch((e) => console.error('listPublicAddons failed:', e));
    return () => { alive = false; };
  }, [eventId]);

  const setQuantity = (a: PublicAddon, next: number) => {
    const remaining = a.capacity > 0 ? Math.max(0, a.capacity - a.sold) : Infinity;
    const ceiling = Math.min(a.maxPerOrder ?? Infinity, remaining);
    const clamped = Math.max(0, Math.min(next, ceiling));
    const updated: Record<string, number> = { ...qty, [a.id]: clamped };
    if (clamped === 0) delete updated[a.id];
    setQty(updated);

    const items = Object.entries(updated).map(([addon_id, quantity]) => ({ addon_id, quantity }));
    const totalCents = items.reduce((sum, it) => {
      const found = addons.find((x) => x.id === it.addon_id);
      return sum + Math.round((found?.price ?? 0) * 100) * it.quantity;
    }, 0);
    onChange({ items, totalCents });
  };

  if (addons.length === 0) return null;

  return (
    <div className="mb-6 space-y-3">
      <p className="text-[10px] font-black uppercase tracking-[0.2em] text-white/40">Add-ons</p>
      {addons.map((a) => {
        const remaining = a.capacity > 0 ? Math.max(0, a.capacity - a.sold) : Infinity;
        const soldOut = remaining <= 0;
        const current = qty[a.id] ?? 0;
        return (
          <div key={a.id} className="flex items-center justify-between border-2 border-white/10 p-3">
            <div className="min-w-0 pr-3">
              <p className="font-black uppercase italic tracking-tighter text-sm truncate">{a.name}</p>
              {a.description && <p className="text-white/40 text-xs font-bold truncate">{a.description}</p>}
              <p className="text-brand-primary text-xs font-black mt-0.5">
                {a.price > 0 ? formatCurrency(a.price, currency) : 'Free'}
                {soldOut && <span className="text-brand-accent ml-2">Sold out</span>}
              </p>
            </div>
            <div className="flex items-center space-x-3 shrink-0">
              <button
                type="button"
                disabled={current <= 0}
                onClick={() => setQuantity(a, current - 1)}
                className="w-8 h-8 flex items-center justify-center border-2 border-white/15 hover:border-brand-primary disabled:opacity-30"
                aria-label={`Remove one ${a.name}`}
              >
                <Minus className="w-4 h-4" />
              </button>
              <span className="w-6 text-center font-black tabular-nums">{current}</span>
              <button
                type="button"
                disabled={soldOut || current >= (a.maxPerOrder ?? Infinity) || current >= remaining}
                onClick={() => setQuantity(a, current + 1)}
                className="w-8 h-8 flex items-center justify-center border-2 border-white/15 hover:border-brand-primary disabled:opacity-30"
                aria-label={`Add one ${a.name}`}
              >
                <Plus className="w-4 h-4" />
              </button>
            </div>
          </div>
        );
      })}
    </div>
  );
}
