// "More dates" — sibling occurrences of a series on the event page (customer
// side of D4-OPS-27). Reads exos_public_events by series_id (anon-readable
// columns), so it works for signed-out browsers too. Renders nothing for a
// standalone event or when no other upcoming date exists.

import { useEffect, useState } from 'react';
import { Link } from 'react-router-dom';
import { CalendarRange } from 'lucide-react';
import { listPublicSeriesEvents } from '../lib/events';
import { seriesSiblings } from '../lib/seriesGroups';
import { formatInTz } from '../lib/datetime';
import { useT } from '../context/LanguageContext';
import type { Event } from '../types';

export default function SeriesDates({ event }: { event: Event }) {
  const t = useT();
  const [siblings, setSiblings] = useState<Event[]>([]);
  const [failed, setFailed] = useState(false);

  useEffect(() => {
    if (!event.seriesId) {
      setSiblings([]);
      return undefined;
    }
    let cancelled = false;
    listPublicSeriesEvents(event.seriesId)
      .then((members) => {
        if (!cancelled) setSiblings(seriesSiblings(event, members));
      })
      .catch((err) => {
        console.warn('SeriesDates: could not load series members', err);
        if (!cancelled) setFailed(true);
      });
    return () => {
      cancelled = true;
    };
  }, [event.id, event.seriesId]);

  if (!event.seriesId || (siblings.length === 0 && !failed)) return null;

  return (
    <div className="border border-white/10 bg-[#111] p-6 mb-14">
      <div className="flex items-center gap-2 mb-1">
        <CalendarRange className="w-4 h-4 text-brand-primary" aria-hidden="true" />
        <p className="type text-[10px] text-white/30 uppercase tracking-widest">{t('series.moreDates')}</p>
      </div>
      {failed ? (
        <p className="type text-[12px] text-white/40">{t('series.loadFailed')}</p>
      ) : (
        <ul className="divide-y divide-white/5">
          {siblings.slice(0, 12).map((s) => (
            <li key={s.id}>
              <Link
                to={`/event/${s.id}`}
                className="flex items-center justify-between py-2.5 group hover:text-brand-primary transition-colors"
              >
                <span className="disp text-lg tracking-wide">
                  {s.date ? formatInTz(s.date.toDate(), s.timezone, { weekday: 'short', month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' }) : s.title}
                </span>
                <span className="type text-[10px] uppercase tracking-widest text-white/30 group-hover:text-brand-primary">
                  {s.ticketsSold >= s.totalTickets && s.totalTickets > 0 ? t('event.soldOut') : t('series.pick')}
                </span>
              </Link>
            </li>
          ))}
          {siblings.length > 12 && (
            <li className="type text-[10px] uppercase tracking-widest text-white/30 pt-2">{t('series.andMore', { n: siblings.length - 12 })}</li>
          )}
        </ul>
      )}
    </div>
  );
}
