// CSV building + browser download (organizer exports).
//
// One implementation for every export surface (event report attendees /
// summary, check-in registry, scan-reject audit) — the previous inline builder
// in OrganizerCheckIn is retired in favour of this. RFC 4180 quoting: a cell is
// wrapped in double quotes when it contains a comma, quote, CR or LF, and inner
// quotes are doubled. Rows are joined with CRLF and the file is prefixed with a
// UTF-8 BOM so Excel opens accented names correctly.
//
// Formula injection: a cell that starts with one of = + - @ (or a tab / CR) is
// prefixed with a single quote so a spreadsheet never evaluates attendee-supplied
// text (a promoter code of "=HYPERLINK(...)" is user input).

export type CsvCell = string | number | boolean | null | undefined | Date;

const NEEDS_QUOTE = /[",\r\n]/;
const FORMULA_LEAD = /^[=+\-@\t\r]/;

export function csvCell(v: CsvCell): string {
  let s: string;
  if (v === null || v === undefined) s = '';
  else if (v instanceof Date) s = Number.isNaN(v.getTime()) ? '' : v.toISOString();
  else s = String(v);
  // Only free text can carry a formula; a negative number is data.
  if (typeof v === 'string' && FORMULA_LEAD.test(s)) s = `'${s}`;
  return NEEDS_QUOTE.test(s) ? `"${s.replace(/"/g, '""')}"` : s;
}

/** Build a CSV document from a header row + data rows. */
export function toCsv(header: string[], rows: CsvCell[][]): string {
  return [header, ...rows].map((r) => r.map(csvCell).join(',')).join('\r\n');
}

/** Filesystem-safe, lower-case slug for a download name. */
export function csvFileName(parts: Array<string | undefined | null>, date = new Date()): string {
  const slug = parts
    .filter((p): p is string => !!p)
    .map((p) => p.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, ''))
    .filter(Boolean)
    .join('-');
  return `${slug || 'export'}-${date.toISOString().slice(0, 10)}.csv`;
}

/** Trigger a browser download of `csv` as `fileName`. No-op outside a DOM. */
export function downloadCsv(fileName: string, csv: string): void {
  if (typeof document === 'undefined' || typeof URL === 'undefined') return;
  const blob = new Blob(['﻿', csv], { type: 'text/csv;charset=utf-8' });
  const url = URL.createObjectURL(blob);
  const a = document.createElement('a');
  a.href = url;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  a.remove();
  setTimeout(() => URL.revokeObjectURL(url), 0);
}
