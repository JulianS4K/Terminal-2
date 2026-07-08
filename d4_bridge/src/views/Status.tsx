import { useEffect, useState } from 'react';
import { Activity, CheckCircle2, AlertTriangle, ArrowLeft, Clock, Loader2 } from 'lucide-react';
import { useNavigate } from 'react-router-dom';

// Probe targets. Each one is a real HTTP request; latency and result are
// shown to the user verbatim. No fictional "Operational" labels.
//
// To extend: add a new entry whose `probe` returns a Response. Anything
// non-2xx is reported as Down; >2s response is reported as Degraded.
type ProbeOutcome = 'unknown' | 'up' | 'degraded' | 'down';
interface ProbeResult {
  outcome: ProbeOutcome;
  latencyMs?: number;
  detail?: string;
}

const DEGRADED_THRESHOLD_MS = 2000;

async function probeHealthz(): Promise<ProbeResult> {
  const started = performance.now();
  try {
    const res = await fetch('/healthz', { method: 'GET' });
    const latency = Math.round(performance.now() - started);
    if (!res.ok) {
      return { outcome: 'down', latencyMs: latency, detail: `HTTP ${res.status}` };
    }
    if (latency > DEGRADED_THRESHOLD_MS) {
      return { outcome: 'degraded', latencyMs: latency };
    }
    return { outcome: 'up', latencyMs: latency };
  } catch (err) {
    return {
      outcome: 'down',
      detail: err instanceof Error ? err.message : 'Request failed',
    };
  }
}

interface ServiceCheck {
  name: string;
  description: string;
  probe: () => Promise<ProbeResult>;
}

const SERVICES: ServiceCheck[] = [
  {
    name: 'API',
    description: 'Core Exos backend',
    probe: probeHealthz,
  },
];

function outcomeLabel(o: ProbeOutcome): string {
  switch (o) {
    case 'up':
      return 'Operational';
    case 'degraded':
      return 'Degraded';
    case 'down':
      return 'Down';
    default:
      return 'Checking';
  }
}

function outcomeBadge(o: ProbeOutcome): string {
  switch (o) {
    case 'up':
      return 'neon';
    case 'degraded':
      return 'text-amber-400';
    case 'down':
      return 'text-brand-accent';
    default:
      return 'text-white/40';
  }
}

export default function Status() {
  const navigate = useNavigate();
  const [results, setResults] = useState<Record<string, ProbeResult>>({});
  const [lastChecked, setLastChecked] = useState<Date | null>(null);
  const [refreshing, setRefreshing] = useState(false);

  const runChecks = async () => {
    setRefreshing(true);
    const entries = await Promise.all(
      SERVICES.map(async (s) => [s.name, await s.probe()] as const),
    );
    setResults(Object.fromEntries(entries));
    setLastChecked(new Date());
    setRefreshing(false);
  };

  useEffect(() => {
    runChecks();
    // Auto-refresh every 30s while the page is visible. Skip when hidden so
    // we don't burn requests for a backgrounded tab.
    const interval = setInterval(() => {
      if (document.visibilityState === 'visible') runChecks();
    }, 30000);
    return () => clearInterval(interval);
  }, []);

  const overallDown = SERVICES.some((s) => results[s.name]?.outcome === 'down');
  const overallDegraded = SERVICES.some(
    (s) => results[s.name]?.outcome === 'degraded',
  );

  return (
    <div className="max-w-4xl mx-auto px-4 sm:px-6 py-14">
      <button
        onClick={() => navigate(-1)}
        className="type inline-flex items-center text-white/40 hover:text-brand-primary mb-10 transition-colors uppercase tracking-[0.3em] text-[11px]"
      >
        <ArrowLeft className="w-4 h-4 mr-2" aria-hidden="true" />
        Back
      </button>

      <p className="type text-brand-primary text-[12px] uppercase tracking-[0.3em] mb-3">// status</p>
      <div className="flex items-center gap-4 mb-2">
        <Activity
          className={`w-5 h-5 animate-pulse shrink-0 ${
            overallDown ? 'text-brand-accent' : overallDegraded ? 'text-amber-400' : 'text-brand-primary'
          }`}
          aria-hidden="true"
        />
        <h1 className="disp text-5xl md:text-6xl tracking-tight" style={{ transform: 'skewX(-4deg)' }}>
          CORE SYSTEMS{' '}
          <span className={overallDown ? 'text-brand-accent' : overallDegraded ? 'text-amber-400' : 'neon'}>
            {overallDown ? 'DOWN' : overallDegraded ? 'DEGRADED' : 'LIVE'}
          </span>
        </h1>
      </div>
      <p className="type text-white/50 text-sm mb-2">
        {overallDown ? 'Outage Detected' : overallDegraded ? 'Degraded Performance' : 'All Systems Operational'}
      </p>
      <p className="type text-white/40 text-sm mb-10">
        Last checked {lastChecked ? lastChecked.toLocaleTimeString() : '—'}
      </p>

      <div className="border border-white/10 divide-y divide-white/10">
        {SERVICES.map((service) => {
          const res = results[service.name];
          const outcome: ProbeOutcome = res?.outcome ?? 'unknown';
          return (
            <div
              key={service.name}
              className="flex items-center justify-between px-5 py-4 bg-[#0a0a0a]"
            >
              <div className="flex items-center gap-4">
                {outcome === 'unknown' ? (
                  <Loader2 className="w-5 h-5 text-white/40 animate-spin shrink-0" aria-hidden="true" />
                ) : outcome === 'down' ? (
                  <AlertTriangle className="w-5 h-5 text-brand-accent shrink-0" aria-hidden="true" />
                ) : outcome === 'degraded' ? (
                  <AlertTriangle className="w-5 h-5 text-amber-400 shrink-0" aria-hidden="true" />
                ) : (
                  <CheckCircle2 className="w-5 h-5 text-brand-primary shrink-0" aria-hidden="true" />
                )}
                <div>
                  <h3 className="type text-sm text-white/80 uppercase tracking-wide">{service.name}</h3>
                  <div className="flex items-center gap-2 mt-0.5">
                    <Clock className="w-3 h-3 text-white/30" aria-hidden="true" />
                    <span className="type text-[10px] text-white/40 uppercase tracking-widest leading-none">
                      {service.description}
                      {res?.latencyMs !== undefined ? ` // ${res.latencyMs}ms` : ''}
                      {res?.detail ? ` // ${res.detail}` : ''}
                    </span>
                  </div>
                </div>
              </div>
              <span className={`type text-[11px] uppercase tracking-widest ${outcomeBadge(outcome)}`}>
                {outcomeLabel(outcome)}
              </span>
            </div>
          );
        })}
      </div>

      <button
        onClick={runChecks}
        disabled={refreshing}
        className="type mt-10 w-full md:w-auto bg-brand-primary text-black px-6 py-3 uppercase tracking-[0.2em] text-[11px] font-bold hover:bg-white transition-all disabled:opacity-50"
      >
        {refreshing ? 'Checking...' : 'Re-check Now'}
      </button>
    </div>
  );
}
