import { describe, it, expect } from 'vitest';
import { parseEmailList, summarizeCompBatch } from './compsModel';

describe('parseEmailList', () => {
  it('splits on commas, semicolons, whitespace and newlines', () => {
    expect(parseEmailList('a@x.com, b@x.com;c@x.com\nd@x.com   e@x.com')).toEqual([
      'a@x.com', 'b@x.com', 'c@x.com', 'd@x.com', 'e@x.com',
    ]);
  });
  it('drops empties but keeps junk for the server to flag', () => {
    expect(parseEmailList('  , nope ,, a@x.com ')).toEqual(['nope', 'a@x.com']);
  });
});

describe('summarizeCompBatch', () => {
  it('counts every outcome, including zeros', () => {
    expect(
      summarizeCompBatch([
        { email: 'a', outcome: 'issued', ticketIds: ['1'], detail: null },
        { email: 'b', outcome: 'invited', ticketIds: ['2'], detail: 'x' },
        { email: 'c', outcome: 'invited', ticketIds: ['3'], detail: 'x' },
        { email: 'd', outcome: 'invalid', ticketIds: [], detail: null },
      ]),
    ).toEqual({ issued: 1, invited: 2, 'sold-out': 0, invalid: 1 });
  });
});
