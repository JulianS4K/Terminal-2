// WHY hunter #1: NOAA NWS active weather alerts.
// Free, no key. Pulls active alerts (severe weather, flood, snow, heat) for
// every distinct US state where we have upcoming events. Maps to per-event
// signals with scope='event', signal_kind='weather_alert'.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

async function noaaActiveByState(state: string): Promise<any[]> {
  const r = await fetch(`https://api.weather.gov/alerts/active?area=${state}`, {
    headers: { 'User-Agent': 's4k-terminal2 (julian@s4kent.com)', 'Accept': 'application/geo+json' }
  });
  if (!r.ok) throw new Error(`NWS ${r.status} for state=${state}`);
  const j = await r.json();
  return j.features ?? [];
}

function severityToSignal(severity: string, eventType: string): { value: number; label: string } {
  const sev = (severity ?? '').toLowerCase();
  const ev = (eventType ?? '').toLowerCase();
  let value = 0;
  if (sev === 'extreme')  value = -0.8;
  else if (sev === 'severe')   value = -0.5;
  else if (sev === 'moderate') value = -0.25;
  else if (sev === 'minor')    value = -0.1;
  if (/tornado|hurricane|blizzard|ice storm/.test(ev)) value = Math.min(value, -0.7);
  if (/flood|wind/.test(ev)) value = Math.min(value, -0.3);
  if (/heat|cold/.test(ev) && value === 0) value = -0.2;
  return { value, label: `${eventType} (${severity})` };
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('POST only', { status: 405 });
  const t0 = Date.now();
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  const { data: states } = await db.from('events').select('venue_location')
    .not('venue_location', 'is', null)
    .gte('occurs_at_local', new Date().toISOString().slice(0,10))
    .limit(1000);
  const stateSet = new Set<string>();
  for (const r of states ?? []) {
    const parts = String(r.venue_location).split(',').map((s:string)=>s.trim());
    if (parts.length >= 2 && /^[A-Z]{2}$/.test(parts[1])) stateSet.add(parts[1]);
  }

  let stats = { states_checked: 0, alerts_fetched: 0, signals_inserted: 0, events_affected: 0, errors: 0, errs: [] as any[] };
  const eventScope = new Map<number, { value: number; label: string }>();

  for (const state of stateSet) {
    try {
      const alerts = await noaaActiveByState(state);
      stats.states_checked++;
      stats.alerts_fetched += alerts.length;
      if (!alerts.length) continue;

      for (const alert of alerts) {
        const props = alert.properties ?? {};
        const onset = props.onset ?? props.effective ?? null;
        const ends = props.ends ?? props.expires ?? null;
        if (!onset || !ends) continue;
        const sig = severityToSignal(props.severity, props.event);
        if (sig.value === 0) continue;

        const { data: matchedEvents } = await db.from('events')
          .select('id, venue_location, occurs_at_local')
          .ilike('venue_location', `%, ${state}`)
          .gte('occurs_at_local', onset)
          .lte('occurs_at_local', ends);
        for (const ev of matchedEvents ?? []) {
          const cur = eventScope.get(ev.id);
          if (!cur || sig.value < cur.value) eventScope.set(ev.id, sig);
        }
      }
    } catch (e) { stats.errors++; stats.errs.push({ state, error: String((e as Error).message) }); }
    await new Promise(r => setTimeout(r, 300));
  }

  for (const [eventId, sig] of eventScope) {
    try {
      await db.from('why_signals').insert({
        scope: 'event',
        scope_id: eventId,
        signal_kind: 'weather_alert',
        signal_value: sig.value,
        signal_label: sig.label,
        weight: 0.9,
        source: 'noaa',
        expires_at: new Date(Date.now() + 3 * 60 * 60 * 1000).toISOString()
      });
      stats.signals_inserted++;
    } catch (e) { stats.errors++; }
  }
  stats.events_affected = eventScope.size;
  return new Response(JSON.stringify({ ...stats, elapsed_ms: Date.now() - t0 }, null, 2),
    { headers: { 'content-type': 'application/json' } });
});
