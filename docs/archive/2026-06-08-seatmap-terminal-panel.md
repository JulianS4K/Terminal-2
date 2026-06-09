# Seat-map terminal panel — ready-to-apply (2026-06-08, D0)

Step 5 UI for the `venue_section_map` crosswalk. **Not applied to a branch** because
the terminal event-page panel infrastructure (`loadSgZonesSplits`, `rpcOrNull`, the
Overview-pane `<section class="panel">` pattern) lives on the **unmerged terminal-redesign
branch**, not `origin/main`. Apply this once that redesign lands. Data layer (the
`get_event_section_map` RPC, mig `20260608140000`) is already on prod + in this PR.

Validated: JS syntax-checked (`node --check`); RPC tested (event 3091415 → 447 sections,
380 mapped). Panel hides itself on empty/error.

## 1. `static/terminal/event.html` — add after the `#zones` `<section>`:

```html
    <!-- SEAT MAP — venue_section_map crosswalk (config-aware). Loader
         loadEventSectionMap() → get_event_section_map RPC; hides on empty/error. -->
    <section id="seatmap" hidden>
      <div class="panel-title row">
        <span>SEAT MAP — VENUE COVERAGE</span>
        <span class="muted small" id="seatmapSubtitle"></span>
      </div>
      <div id="seatmapBody"></div>
    </section>
```

## 2. `static/terminal/event.js` — add the call next to the other fire-and-forget loaders (by `loadSgZonesSplits(eventId).catch(...)`):

```js
    loadEventSectionMap(eventId).catch(e => console.error('[eventSectionMap]', e));
```

## 3. `static/terminal/event.js` — add the loader (e.g. after `loadSgZonesSplits`):

```js
  // ---------- Seat map — venue_section_map crosswalk (config-aware) ----------
  async function loadEventSectionMap(eventId) {
    const sec  = document.getElementById('seatmap');
    const body = document.getElementById('seatmapBody');
    const sub  = document.getElementById('seatmapSubtitle');
    if (!sec || !body) return;
    const res = await rpcOrNull('get_event_section_map', { p_event_id: eventId });
    const rows = (res && !res.error && Array.isArray(res.data)) ? res.data : [];
    if (rows.length === 0) { sec.hidden = true; return; }

    const esc = s => String(s == null ? '' : s).replace(/[&<>"]/g, c =>
      ({ '&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;' }[c]));
    const cfg = rows[0].configuration_id;
    const byPlat = {};
    rows.forEach(r => {
      const p = (byPlat[r.platform] || (byPlat[r.platform] = { total: 0, mapped: 0 }));
      p.total++; if (r.match_method !== 'unmatched') p.mapped++;
    });
    const summary = Object.keys(byPlat).sort().map(p => {
      const s = byPlat[p];
      return `${p.toUpperCase()} ${s.mapped}/${s.total} (${Math.round(100 * s.mapped / s.total)}%)`;
    }).join(' · ');
    if (sub) sub.textContent = `config ${cfg === 0 ? 'union' : cfg} · ${summary}`;

    const tier = m => m === 'exact' ? '#46d369'
                    : m === 'token' ? '#9ad36b'
                    : m === 'token_base' ? '#d3c46b'
                    : (m === 'token_ambiguous' || m === 'token_base_ambiguous') ? '#d39a6b'
                    : '#888';
    const mappedRows = rows.filter(r => r.match_method !== 'unmatched');
    const shown = mappedRows
      .sort((a, b) => (a.platform + a.section_raw).localeCompare(b.platform + b.section_raw))
      .slice(0, 150);
    const trs = shown.map(r =>
      `<tr>` +
      `<td class="mono small">${esc(r.platform)}</td>` +
      `<td class="mono small">${esc(r.section_raw)}</td>` +
      `<td class="small">${esc(r.seatmap_key || '—')}</td>` +
      `<td class="small" style="color:${tier(r.match_method)}">${esc(r.match_method)}</td>` +
      `</tr>`).join('');
    const more = shown.length < mappedRows.length
      ? `<div class="muted small" style="margin-top:4px">…showing first ${shown.length} mapped sections</div>` : '';
    body.innerHTML =
      `<div style="max-height:300px;overflow-y:auto">` +
      `<table class="data" style="width:100%"><thead><tr>` +
      `<th>src</th><th>section</th><th>seat-map section</th><th>match</th>` +
      `</tr></thead><tbody>${trs}</tbody></table></div>${more}`;
    sec.hidden = false;
  }
```

## Future: true polygon highlighting
This panel is a coverage **list**. Interactive polygon highlighting needs TEvo's seatmap
widget (`fanvenues_key` / `seatmaps-client.js`) — there is WIP under `static/store/vendor/
tevo-seatmaps.js` + `static/store/test/seatmap_probe.*`. Once that widget is wired, feed it
`seatmap_key` per section from `get_event_section_map` to colour polygons by price/coverage.
