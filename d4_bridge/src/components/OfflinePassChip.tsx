// OfflinePassChip — the one honest label on a pass served from the device.
//
// Rendered by WalletPass / TicketDetail / MyTickets when the network read
// failed and lib/offlinePass supplied the data instead. It says two things,
// because at a door both matter: this copy is offline, and it is this old.
// A holder whose ticket was refunded an hour ago should be able to see that
// the screen they are showing predates the refund.
//
// The age comes from the pure `syncAge` helper so the wording stays in the
// dictionary rather than in this component.

import { WifiOff } from 'lucide-react';
import { syncAge } from '../lib/offlinePass';
import type { DictKey } from '../lib/i18n/dict';

interface Props {
  /** Epoch-ms the cached copy was fetched. */
  savedAt: number;
  /** The `useT()` translator from the calling view. */
  t: (key: DictKey, vars?: Record<string, string | number>) => string;
  /** `dark` sits on the black pass chrome; `light` on a white card. */
  tone?: 'dark' | 'light';
}

export default function OfflinePassChip({ savedAt, t, tone = 'dark' }: Props) {
  const age = syncAge(savedAt);
  const when =
    age.unit === 'now'
      ? t('offline.justNow')
      : age.unit === 'min'
      ? t('offline.minutesAgo', { n: age.value })
      : age.unit === 'hour'
      ? t('offline.hoursAgo', { n: age.value })
      : t('offline.daysAgo', { n: age.value });

  const cls =
    tone === 'dark'
      ? 'text-amber-300/90 border-amber-300/40'
      : 'text-amber-700 border-amber-600/40 bg-amber-50';

  return (
    <div
      role="status"
      className={`type text-[10px] uppercase tracking-widest flex items-center gap-2 border px-2 py-1 rounded ${cls}`}
    >
      <WifiOff size={12} aria-hidden="true" />
      <span>
        {t('offline.chip')} · {when}
      </span>
    </div>
  );
}
