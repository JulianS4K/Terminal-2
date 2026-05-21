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
      return 'bg-green-100 text-green-700';
    case 'degraded':
      return 'bg-amber-100 text-amber-700';
    case 'down':
      return 'bg-red-100 text-red-700';
    default:
      return 'bg-slate-100 text-slate-500';
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
    <div className="max-w-4xl mx-auto px-4 py-20">
      <button
        onClick={() => navigate(-1)}
        className="flex items-center text-slate-400 hover:text-slate-900 mb-12 transition-colors font-bold uppercase tracking-widest text-[10px]"
      >
        <ArrowLeft className="w-4 h-4 mr-2" aria-hidden="true" />
        Back
      </button>

      <div className="bg-white p-12 md:p-20 rounded-[3rem] border border-slate-100 shadow-xl">
        <div className="flex items-center justify-between mb-12">
          <div className="flex items-center space-x-4">
            <div
              className={`w-12 h-12 rounded-2xl flex items-center justify-center ${
                overallDown ? 'bg-red-50' : overallDegraded ? 'bg-amber-50' : 'bg-green-50'
              }`}
            >
              <Activity
                className={`w-6 h-6 ${
                  overallDown ? 'text-red-500' : overallDegraded ? 'text-amber-500' : 'text-green-500'
                }`}
                aria-hidden="true"
              />
            </div>
            <div>
              <h1 className="text-4xl font-bold tracking-tight text-slate-900 italic">Core Systems</h1>
              <p
                className={`font-bold uppercase tracking-widest text-[10px] mt-1 ${
                  overallDown ? 'text-red-500' : overallDegraded ? 'text-amber-500' : 'text-green-500'
                }`}
              >
                {overallDown ? 'Outage Detected' : overallDegraded ? 'Degraded Performance' : 'All Systems Operational'}
              </p>
            </div>
          </div>
          <div className="hidden md:block text-right">
            <p className="text-slate-400 font-bold uppercase tracking-widest text-[10px]">Last Checked</p>
            <p className="text-slate-900 font-bold italic">
              {lastChecked ? lastChecked.toLocaleTimeString() : '—'}
            </p>
          </div>
        </div>

        <div className="space-y-6">
          {SERVICES.map((service) => {
            const res = results[service.name];
            const outcome: ProbeOutcome = res?.outcome ?? 'unknown';
            return (
              <div
                key={service.name}
                className="flex items-center justify-between p-6 bg-slate-50 rounded-2xl border border-slate-100"
              >
                <div className="flex items-center space-x-4">
                  {outcome === 'unknown' ? (
                    <Loader2 className="w-5 h-5 text-slate-400 animate-spin" aria-hidden="true" />
                  ) : outcome === 'down' ? (
                    <AlertTriangle className="w-5 h-5 text-red-500" aria-hidden="true" />
                  ) : outcome === 'degraded' ? (
                    <AlertTriangle className="w-5 h-5 text-amber-500" aria-hidden="true" />
                  ) : (
                    <CheckCircle2 className="w-5 h-5 text-green-500" aria-hidden="true" />
                  )}
                  <div>
                    <h3 className="font-bold text-slate-900">{service.name}</h3>
                    <div className="flex items-center space-x-2">
                      <Clock className="w-3 h-3 text-slate-400" aria-hidden="true" />
                      <span className="text-[10px] text-slate-400 font-medium uppercase tracking-widest leading-none">
                        {service.description}
                        {res?.latencyMs !== undefined ? ` // ${res.latencyMs}ms` : ''}
                        {res?.detail ? ` // ${res.detail}` : ''}
                      </span>
                    </div>
                  </div>
                </div>
                <span
                  className={`text-[10px] font-black uppercase tracking-widest px-3 py-1 rounded-lg ${outcomeBadge(outcome)}`}
                >
                  {outcomeLabel(outcome)}
                </span>
              </div>
            );
          })}
        </div>

        <button
          onClick={runChecks}
          disabled={refreshing}
          className="mt-10 w-full md:w-auto bg-slate-900 text-white px-6 py-3 rounded-2xl font-bold uppercase tracking-widest text-[10px] hover:bg-slate-800 transition-all disabled:opacity-50"
        >
          {refreshing ? 'Checking...' : 'Re-check Now'}
        </button>
      </div>
    </div>
  );
}
