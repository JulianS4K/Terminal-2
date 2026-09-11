// Group sales / comp allocations — PURE model (types + list parsing + result
// summary). No Supabase import so it unit-tests without a client; the RPC
// wrappers live in ./comps.ts.

export type CompOutcome = 'issued' | 'invited' | 'sold-out' | 'invalid';

export interface CompBatchRow {
  email: string;
  outcome: CompOutcome;
  ticketIds: string[];
  detail: string | null;
}

/** Split a pasted list (commas, semicolons, whitespace, newlines) into raw
 *  candidates. Validation + dedupe happen server-side; this only tokenises. */
export function parseEmailList(text: string): string[] {
  return text
    .split(/[\s,;]+/)
    .map((s) => s.trim())
    .filter(Boolean);
}

export function summarizeCompBatch(rows: CompBatchRow[]): Record<CompOutcome, number> {
  const out: Record<CompOutcome, number> = { issued: 0, invited: 0, 'sold-out': 0, invalid: 0 };
  for (const r of rows) out[r.outcome] = (out[r.outcome] ?? 0) + 1;
  return out;
}
