import { describe, it, expect } from 'vitest';
import { activePhase, formatRemaining, type CountdownPhase } from './TicketPhaseCountdown';

const at = (iso: string): Date => new Date(iso);
const NOW = at('2026-08-01T12:00:00Z').getTime();

const phases: CountdownPhase[] = [
  { key: 'reveal', label: 'Unlocks in', at: at('2026-08-01T10:00:00Z') }, // past
  { key: 'doors', label: 'Doors open in', at: at('2026-08-01T18:00:00Z') },
  { key: 'start', label: 'Show starts in', at: at('2026-08-01T19:00:00Z') },
];

describe('activePhase', () => {
  it('returns the first future phase', () => {
    expect(activePhase(phases, NOW)?.key).toBe('doors');
  });

  it('advances as milestones pass', () => {
    const afterDoors = at('2026-08-01T18:30:00Z').getTime();
    expect(activePhase(phases, afterDoors)?.key).toBe('start');
  });

  it('sorts out-of-order phases before choosing', () => {
    const scrambled = [phases[2], phases[0], phases[1]];
    expect(activePhase(scrambled, NOW)?.key).toBe('doors');
  });

  it('returns null once every phase is past', () => {
    const afterAll = at('2026-08-02T00:00:00Z').getTime();
    expect(activePhase(phases, afterAll)).toBeNull();
  });

  it('ignores phases with invalid dates', () => {
    const withBad = [{ key: 'bad', label: 'x', at: new Date('nope') }, ...phases];
    expect(activePhase(withBad, NOW)?.key).toBe('doors');
  });
});

describe('formatRemaining', () => {
  it('shows d/h when a day or more out', () => {
    expect(formatRemaining((2 * 86400 + 4 * 3600) * 1000)).toBe('2d 4h');
  });
  it('shows h/m under a day', () => {
    expect(formatRemaining((3 * 3600 + 12 * 60) * 1000)).toBe('3h 12m');
  });
  it('ticks mm:ss under an hour', () => {
    expect(formatRemaining((7 * 60 + 4) * 1000)).toBe('7:04');
  });
  it('never goes negative', () => {
    expect(formatRemaining(-5000)).toBe('0:00');
  });
});
