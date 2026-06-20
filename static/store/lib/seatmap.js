// store/lib/seatmap.js — interactive TEvo seat map widget for the D1 storefront.
// Self-contained (D1 lane: static/store/* only). Exposes window.StoreSeatmap.mount().
//
// Colors each venue section by the cheapest available listing price and lets a
// shopper click a section to filter the listings. Uses the vendored Tevomaps UMD
// bundle (window.Tevomaps) + the SAME section→manifest matcher proven on the D0
// terminal (numeric / suffix / family / zone / name tiers). Mirrors the matcher in
// static/terminal/event.js — kept in sync by hand (no shared module yet).
(function () {
  'use strict';

  // ----- parking / non-seated filter (matches terminal) -----
  function isParking(section) {
    var s = section || '';
    if (/parking|garage|valet|\blot\b|\blot[\s.\-]?[a-z0-9]|min walk|mi from venue|shuttle|tailgate/i.test(s)) return true;
    if (/^\s*\d[\d\s.,/&–-]*\s+\S.*\b(st|street|ave|avenue|blvd|boulevard|dr|drive|rd|road|pkwy|pkway|parkway|hwy|highway|ln|lane|ct|court|pl|place|plz|plaza|cir|circle|way)\b\.?/i.test(s)) return true;
    if (/^\s*\d+\s+[nsew]\b\.?\s+[a-z0-9]/i.test(s)) return true;
    return false;
  }

  // ----- section → manifest matcher (mirrors static/terminal/event.js) -----
  var ZONES = {
    fd: 'field box', rs: 'reserve', lg: 'loge box', td: 'top deck',
    dg: 'dugout', pl: 'pavilion', pr: 'pavilion', bl: 'baseline', mvp: 'mvp',
    m: 'middle mezzanine', mez: 'middle mezzanine', mezz: 'middle mezzanine',
    mezzanine: 'middle mezzanine', drm: 'middle mezzanine', flga: 'floor', flrga: 'floor',
  };
  var PREMIUM = /suite|club|diamond|dugout|founders|mvp|legend|champion|hall|vista|porch|all\s*star|gold\s*glove|rookie|silver|platinum|party|\bpass\b/i;

  function norm(s) {
    return String(s == null ? '' : s).toLowerCase().replace(/[^a-z0-9 ]/g, ' ').replace(/\s+/g, ' ').trim();
  }
  // Light key for matching listing sections against venue_section_map.section_raw
  // (both are raw EVO section strings) — case/whitespace-insensitive, punctuation
  // PRESERVED (unlike norm) so "104A" vs "104 a" stay distinct in the crosswalk.
  function nkey(s) {
    return String(s == null ? '' : s).trim().toLowerCase().replace(/\s+/g, ' ');
  }
  function parse(s) {
    var n = norm(s);
    var numM = n.match(/\d+/);
    if (!numM) return { num: null, suf: '', fam: n };
    var num = String(parseInt(numM[0], 10));
    var sufM = n.match(/\d([a-h])$/);
    var suf = sufM ? sufM[1] : '';
    var nf = suf ? n.replace(/([a-h])$/, '') : n;
    var fam = [];
    (nf.match(/[a-z]+/g) || []).forEach(function (t) {
      if (ZONES[t]) Array.prototype.push.apply(fam, ZONES[t].split(' '));
      else if (t === 'clubhouse') fam.push('club', 'house');
      else if (/^(sec|section|ga)$/.test(t)) { /* generic */ }
      else fam.push(t);
    });
    return { num: num, suf: suf, fam: fam.join(' ') };
  }
  function buildIndex(keys) {
    var byNumSuf = {}, byNum = {}, named = [];
    keys.forEach(function (k) {
      var p = parse(k);
      if (p.num == null) { var nm = norm(k); named.push({ key: k, norm: nm, toks: nm.split(' ').filter(Boolean) }); return; }
      var rec = { key: k, fam: p.fam, suf: p.suf };
      var ek = p.num + '|' + p.suf;
      (byNumSuf[ek] = byNumSuf[ek] || []).push(rec);
      (byNum[p.num] = byNum[p.num] || []).push(rec);
    });
    return { byNumSuf: byNumSuf, byNum: byNum, named: named, cache: {} };
  }
  function pick(p, cands) {
    var lt = p.fam ? p.fam.split(' ').filter(Boolean) : [];
    if (lt.length) {
      var best = null, bs = 0;
      cands.forEach(function (c) {
        var s = c.fam.split(' ').filter(function (t) { return lt.indexOf(t) >= 0; }).length;
        if (s > bs) { bs = s; best = c; }
      });
      if (best) return best.key;
    }
    var bowl = cands.filter(function (c) { return !PREMIUM.test(c.key); });
    if (bowl.length === 1) return bowl[0].key;
    return null;
  }
  function matchSection(section, idx) {
    if (!idx) return null;
    if (Object.prototype.hasOwnProperty.call(idx.cache, section)) return idx.cache[section];
    var p = parse(section), key = null;
    if (p.num == null) {
      var nm = norm(section), hit = null;
      for (var i = 0; i < idx.named.length; i++) { if (idx.named[i].norm === nm) { hit = idx.named[i]; break; } }
      if (!hit && idx.named.length) {
        var lt = nm.split(' ').filter(Boolean), best = null, bs = 0;
        idx.named.forEach(function (x) {
          var ov = x.toks.filter(function (t) { return lt.indexOf(t) >= 0; }).length;
          if (ov > bs) { bs = ov; best = x; }
        });
        hit = best;
      }
      key = hit ? hit.key : null;
    } else {
      var ex = idx.byNumSuf[p.num + '|' + p.suf] || [];
      if (ex.length === 1) key = ex[0].key;
      else if (ex.length > 1) key = pick(p, ex);
      else {
        var no = idx.byNum[p.num] || [];
        if (no.length === 1) key = no[0].key;
        else if (no.length > 1) key = pick(p, no);
      }
    }
    idx.cache[section] = key;
    return key;
  }

  // ----- public mount -----
  // opts: { host: Element, venueId, configurationId, listings: [{section, retail_price}],
  //         onSelect: function(listingSections[]) }
  // Returns a promise resolving to { mapped, total } or null on failure.
  async function mount(opts) {
    var host = opts.host;
    if (!host || !window.Tevomaps || !window.Tevomaps.SeatmapFactory) return null;
    if (opts.venueId == null || opts.configurationId == null) return null;

    // manifest → matcher index (for price-coloring). Fetched through our OWN
    // origin (/api/store/seatmap/.../manifest.json) — the TEvo maps CDN is origin-
    // gated and 403s / omits CORS for the storefront host, so fetching it
    // directly here silently failed on EVERY event and the map fell back to the
    // static image. The manifest is OPTIONAL: when it can't load we still build
    // the (uncolored) interactive map — matching the D0 terminal, which never
    // hard-gated the build on the manifest — instead of showing the static jpg.
    var idx = null;
    try {
      var resp = await fetch('/api/store/seatmap/' + opts.venueId + '/' + opts.configurationId + '/manifest.json',
                             { headers: { 'Accept': 'application/json' } });
      if (resp.ok) {
        var manifest = await resp.json();
        idx = buildIndex(Object.keys((manifest && manifest.sections) || {}));
      } else {
        console.warn('[StoreSeatmap] manifest HTTP ' + resp.status + ' (venue ' + opts.venueId +
                     '/config ' + opts.configurationId + ') — rendering map without price coloring');
      }
    } catch (e) {
      console.warn('[StoreSeatmap] manifest fetch error:', (e && e.message) || e);
    }

    // AUTHORITATIVE section → seatmap-key crosswalk (public.venue_section_map,
    // surfaced by /api/store/seatmap/.../section-map). This is the SAME server-side
    // mapper D0's terminal reads via get_event_section_map — built with
    // exact/token/token_base tiers, far more complete than the JS heuristic below.
    // It's the primary resolver; the heuristic (matchSection) only fills sections
    // the crosswalk hasn't mapped, so coverage strictly improves. Optional: if it
    // can't load we fall back entirely to the heuristic.
    var crosswalk = {};  // nkey(section_raw) → seatmap_key
    try {
      var cwResp = await fetch('/api/store/seatmap/' + opts.venueId + '/' + opts.configurationId + '/section-map',
                               { headers: { 'Accept': 'application/json' } });
      if (cwResp.ok) {
        var cwBody = await cwResp.json();
        var secs = (cwBody && cwBody.sections) || {};
        Object.keys(secs).forEach(function (raw) { crosswalk[nkey(raw)] = secs[raw]; });
      } else {
        console.warn('[StoreSeatmap] section-map HTTP ' + cwResp.status + ' — heuristic-only matching');
      }
    } catch (e) {
      console.warn('[StoreSeatmap] section-map fetch error:', (e && e.message) || e);
    }
    var hasCrosswalk = Object.keys(crosswalk).length > 0;

    // cheapest listing per matched manifest section + reverse map (key → listing
    // sections). Built when we have EITHER the crosswalk OR the manifest index;
    // skipped only when both are unavailable — the map still builds, just without
    // price coloring or section→listing click-through.
    var floorByKey = {}, listingsByKey = {};
    if (hasCrosswalk || idx) {
      (opts.listings || []).forEach(function (l) {
        var sec = (l.section || '').trim();
        if (!sec || isParking(sec)) return;
        var price = Number(l.retail_price);
        if (!isFinite(price) || price <= 0) return;
        var key = crosswalk[nkey(sec)] || (idx ? matchSection(sec, idx) : null);
        if (!key) return;
        if (floorByKey[key] == null || price < floorByKey[key]) floorByKey[key] = price;
        (listingsByKey[key] = listingsByKey[key] || []);
        if (listingsByKey[key].indexOf(sec) < 0) listingsByKey[key].push(sec);
      });
    }
    var ticketGroups = Object.keys(floorByKey).map(function (key) {
      return { tevo_section_name: key, retail_price: floorByKey[key] };
    });

    host.innerHTML = '';
    var api;
    try {
      var factory = new window.Tevomaps.SeatmapFactory({
        venueId: String(opts.venueId),
        configurationId: String(opts.configurationId),
        // Route the bundle's internal map.svg + manifest.json fetches through
        // our same-origin proxy (app.py /api/store/seatmap/...). configFilePath
        // inside the bundle is `${mapsDomain}/${venueId}/${configurationId}`, so
        // it then GETs `${mapsDomain}/<venue>/<config>/map.svg` (and manifest.json)
        // from us instead of cross-origin to maps.ticketevolution.com — which
        // omits CORS for the storefront host, rejecting build() and forcing the
        // static fallback on every event.
        mapsDomain: '/api/store/seatmap',
        ticketGroups: ticketGroups,
        showLegend: true,
        showControls: true,
        mouseControlEnabled: true,
        onSelection: function (sections) {
          // selected manifest names → the listing sections they came from
          var out = [];
          (sections || []).forEach(function (name) {
            var k = (idx ? matchSection(name, idx) : null) || name;   // selection echoes a manifest key
            var direct = listingsByKey[name] || listingsByKey[k];
            if (direct) direct.forEach(function (s) { if (out.indexOf(s) < 0) out.push(s); });
          });
          if (typeof opts.onSelect === 'function') opts.onSelect(out);
        },
      });
      api = await factory.build(host.id);
    } catch (e) {
      console.warn('[StoreSeatmap] factory build failed:', (e && e.message) || e);
      return null;
    }
    return { api: api, mapped: ticketGroups.length };
  }

  window.StoreSeatmap = { mount: mount, isParking: isParking };
})();
