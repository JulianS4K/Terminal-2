import { describe, it, expect } from 'vitest';
import { csvCell, toCsv, csvFileName } from './csv';

describe('csvCell', () => {
  it('passes plain values through and blanks null/undefined', () => {
    expect(csvCell('abc')).toBe('abc');
    expect(csvCell(12)).toBe('12');
    expect(csvCell(true)).toBe('true');
    expect(csvCell(null)).toBe('');
    expect(csvCell(undefined)).toBe('');
  });

  it('quotes commas, quotes and newlines per RFC 4180', () => {
    expect(csvCell('a,b')).toBe('"a,b"');
    expect(csvCell('say "hi"')).toBe('"say ""hi"""');
    expect(csvCell('line1\nline2')).toBe('"line1\nline2"');
  });

  it('serializes dates as ISO and blanks invalid ones', () => {
    expect(csvCell(new Date('2026-09-11T10:00:00Z'))).toBe('2026-09-11T10:00:00.000Z');
    expect(csvCell(new Date('nope'))).toBe('');
  });

  it('neutralises spreadsheet formula injection', () => {
    expect(csvCell('=HYPERLINK("x")')).toBe(`"'=HYPERLINK(""x"")"`);
    expect(csvCell('+1')).toBe("'+1");
    expect(csvCell('-5')).toBe("'-5");
    expect(csvCell('@cmd')).toBe("'@cmd");
    // A negative NUMBER is data, not a formula — only strings get the guard.
    expect(csvCell(-5)).toBe('-5');
  });
});

describe('toCsv', () => {
  it('joins header + rows with CRLF', () => {
    const csv = toCsv(['id', 'name'], [['1', 'Al'], ['2', 'Bo, Jr']]);
    expect(csv).toBe('id,name\r\n1,Al\r\n2,"Bo, Jr"');
  });

  it('handles an empty row set (header only)', () => {
    expect(toCsv(['a', 'b'], [])).toBe('a,b');
  });
});

describe('csvFileName', () => {
  it('slugs the parts and appends the date', () => {
    const d = new Date('2026-09-11T23:59:00Z');
    expect(csvFileName(['Attendees', 'Big Show!!', undefined], d)).toBe('attendees-big-show-2026-09-11.csv');
  });

  it('falls back to "export" when nothing usable is given', () => {
    const d = new Date('2026-09-11T00:00:00Z');
    expect(csvFileName([null, '!!!'], d)).toBe('export-2026-09-11.csv');
  });
});
