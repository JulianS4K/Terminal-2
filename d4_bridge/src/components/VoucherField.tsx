// Buyer voucher entry (pretix-style access token).
//
// A valid voucher may unlock a sold-out tier and/or pin a price. On a successful
// check we report the code + grant up to EventDetails, which then enables the
// buy button (even when sold out) and forwards the code to checkout.

import { useState } from 'react';
import { Ticket, Check } from 'lucide-react';
import { checkVoucher } from '../lib/vouchers';
import { useToast } from '../context/ToastContext';

interface Props {
  eventId: string;
  email?: string | null;
  onApplied: (applied: { code: string; canBypass: boolean } | null) => void;
}

export default function VoucherField({ eventId, email, onApplied }: Props) {
  const { toast } = useToast();
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [appliedCode, setAppliedCode] = useState<string | null>(null);

  const apply = async () => {
    const c = code.trim();
    if (!c) return;
    setBusy(true);
    try {
      const res = await checkVoucher(eventId, c, email);
      if (!res.valid) {
        toast({ kind: 'error', message: `Voucher ${res.reason ?? 'invalid'}.` });
        setAppliedCode(null);
        onApplied(null);
        return;
      }
      setAppliedCode(c);
      onApplied({ code: c, canBypass: res.canBypass });
      toast({ kind: 'success', message: res.canBypass ? 'Voucher applied — you can buy this event.' : 'Voucher applied.' });
    } catch (e: any) {
      toast({ kind: 'error', message: e?.message || 'Could not check voucher.' });
    } finally {
      setBusy(false);
    }
  };

  if (appliedCode) {
    return (
      <div className="mb-4 flex items-center gap-2 text-brand-primary text-xs font-black uppercase tracking-widest">
        <Check className="w-4 h-4" />
        Voucher {appliedCode} applied
      </div>
    );
  }

  return (
    <div className="mb-4 flex items-center gap-2">
      <div className="relative flex-1">
        <Ticket className="absolute left-3 top-1/2 -translate-y-1/2 w-4 h-4 text-white/30" />
        <input
          value={code}
          onChange={(e) => setCode(e.target.value)}
          onKeyDown={(e) => { if (e.key === 'Enter') apply(); }}
          placeholder="Voucher code"
          className="w-full bg-black border-2 border-white/15 focus:border-brand-primary outline-none pl-9 pr-3 py-2 text-sm font-bold uppercase"
        />
      </div>
      <button
        type="button"
        disabled={busy || !code.trim()}
        onClick={apply}
        className="px-4 py-2 border-2 border-white/20 hover:border-brand-primary text-white/70 hover:text-brand-primary text-[10px] font-black uppercase tracking-widest transition-all disabled:opacity-40"
      >
        {busy ? '…' : 'Apply'}
      </button>
    </div>
  );
}
