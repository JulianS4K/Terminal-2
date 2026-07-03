// Scheduled tier pricing editor (seller side).
//
// Lives on OrganizerEventReport. Owner/manager set time-based price steps per
// tier — "on/after this date, this tier costs this". The tier's `price` stays the
// opening price; steps ramp it (early-bird → regular → last-minute). Effective
// price is computed at read time (lib/pricing.ts) and shown live on the event
// page. Writes go through the existing org-staff RLS on exos_ticket_tiers
// (updateTier), so no new RPC. Light-theme, matches the dashboard.

import { useMemo, useState } from 'react';
import { Clock, Plus, Trash2 } from 'lucide-react';
import { Event } from '../types';
import { updateTier } from '../lib/events';
import { effectiveTierPrice, normalizeSchedule, type PriceStep } from '../lib/pricing';
import { formatCurrency } from '../lib/utils';
import { useToast } from '../context/ToastContext';

// ISO → <input type="datetime-local"> value (viewer-local, naive).
function toInputValue(iso: string): string {
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '';
  const pad = (n: number) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

export default function TierPricingPanel({
  event,
  canManage,
}: {
  event: Event;
  canManage: boolean;
}) {
  const { toast } = useToast();
  const tiers = useMemo(() => event.ticketTiers ?? [], [event.ticketTiers]);

  // Local, per-tier working copy of the schedule (seeded from the loaded event).
  const [schedules, setSchedules] = useState<Record<string, PriceStep[]>>(() => {
    const seed: Record<string, PriceStep[]> = {};
    for (const t of tiers) seed[t.id] = normalizeSchedule(t.priceSchedule);
    return seed;
  });
  const [savingId, setSavingId] = useState<string | null>(null);

  if (!canManage || tiers.length === 0) return null;

  const setSteps = (tierId: string, steps: PriceStep[]) =>
    setSchedules((prev) => ({ ...prev, [tierId]: steps }));

  const addStep = (tierId: string, basePrice: number) => {
    const steps = schedules[tierId] ?? [];
    // Default the new step a week out at the base price — the organizer edits.
    const wk = new Date();
    wk.setDate(wk.getDate() + 7);
    setSteps(tierId, [...steps, { startsAt: wk.toISOString(), price: basePrice }]);
  };

  const save = async (tierId: string) => {
    const steps = normalizeSchedule(schedules[tierId]);
    setSavingId(tierId);
    try {
      await updateTier(tierId, { priceSchedule: steps });
      setSteps(tierId, steps); // reflect the normalized/sorted result
      toast({ kind: 'success', message: 'Pricing schedule saved.' });
    } catch (err: any) {
      console.error('save price schedule failed:', err);
      toast({ kind: 'error', message: err?.message || 'Could not save pricing.' });
    } finally {
      setSavingId(null);
    }
  };

  const currency = event.currency || 'USD';

  return (
    <div className="bg-white rounded-2xl p-6 shadow-sm mb-6">
      <div className="flex items-center gap-2 mb-1">
        <Clock className="w-4 h-4 text-slate-500" />
        <h3 className="text-sm font-bold text-slate-700">Scheduled pricing</h3>
      </div>
      <p className="text-xs text-slate-400 mb-5">
        Ramp a tier's price over time — early-bird, then regular, then last-minute. Each step is
        "on/after this date, the price becomes this." Buyers see the current price and a "price
        rises on&nbsp;…" nudge on the event page.
      </p>

      <div className="space-y-5">
        {tiers.map((tier) => {
          const steps = schedules[tier.id] ?? [];
          const effective = effectiveTierPrice(tier.price, steps);
          return (
            <div key={tier.id} className="border border-slate-100 rounded-xl p-4">
              <div className="flex items-center justify-between gap-4 mb-3">
                <div>
                  <p className="text-sm font-bold text-slate-800">{tier.name}</p>
                  <p className="text-[11px] text-slate-400">
                    Opening {formatCurrency(tier.price, currency)}
                    <span className="mx-1">·</span>
                    now <span className="font-bold text-slate-700">{formatCurrency(effective, currency)}</span>
                  </p>
                </div>
                <button
                  type="button"
                  onClick={() => addStep(tier.id, tier.price)}
                  className="inline-flex items-center gap-1 px-3 py-1.5 bg-slate-100 hover:bg-slate-200 text-slate-700 rounded-lg text-[10px] font-black uppercase tracking-widest transition-colors"
                >
                  <Plus size={12} aria-hidden="true" /> Add step
                </button>
              </div>

              {steps.length === 0 ? (
                <p className="text-[11px] text-slate-400 italic">Flat price — no scheduled changes.</p>
              ) : (
                <div className="space-y-2">
                  {steps.map((step, i) => (
                    <div key={i} className="flex items-center gap-2">
                      <input
                        type="datetime-local"
                        value={toInputValue(step.startsAt)}
                        onChange={(e) => {
                          const v = e.target.value;
                          const iso = v ? new Date(v).toISOString() : step.startsAt;
                          const nextSteps = steps.slice();
                          nextSteps[i] = { ...step, startsAt: iso };
                          setSteps(tier.id, nextSteps);
                        }}
                        className="flex-1 border-2 border-slate-200 focus:border-slate-900 outline-none px-2 py-1.5 text-xs rounded-lg"
                      />
                      <div className="flex items-center border-2 border-slate-200 focus-within:border-slate-900 rounded-lg px-2">
                        <span className="text-slate-400 text-xs">$</span>
                        <input
                          type="number"
                          min={0}
                          step="0.01"
                          value={step.price}
                          onChange={(e) => {
                            const price = Math.max(0, parseFloat(e.target.value) || 0);
                            const nextSteps = steps.slice();
                            nextSteps[i] = { ...step, price };
                            setSteps(tier.id, nextSteps);
                          }}
                          className="w-20 outline-none px-1 py-1.5 text-xs font-bold"
                        />
                      </div>
                      <button
                        type="button"
                        aria-label="Remove price step"
                        onClick={() => setSteps(tier.id, steps.filter((_, j) => j !== i))}
                        className="p-2 text-slate-400 hover:text-rose-600 transition-colors"
                      >
                        <Trash2 size={14} aria-hidden="true" />
                      </button>
                    </div>
                  ))}
                </div>
              )}

              <div className="mt-3 flex justify-end">
                <button
                  type="button"
                  disabled={savingId === tier.id}
                  onClick={() => save(tier.id)}
                  className="bg-slate-900 hover:bg-slate-800 disabled:bg-slate-200 disabled:text-slate-400 text-white px-4 py-2 rounded-lg font-black uppercase tracking-tighter italic text-xs transition-all"
                >
                  {savingId === tier.id ? 'Saving…' : 'Save pricing'}
                </button>
              </div>
            </div>
          );
        })}
      </div>
    </div>
  );
}
