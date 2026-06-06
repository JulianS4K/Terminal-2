// alerts.js — shared "Alerts" tab module for the D0 terminal.
// Mounted by event.js / performer.js / venue.js on first activation of their
// Alerts tab. One subscription = one trigger on this scope. The trigger picker
// is data-driven from get_alert_metric_catalog() so any tracked dataset the
// backend exposes becomes alertable with no FE change.
//
// Backend: mig 20260603180000 (get_alert_metric_catalog / list_user_alerts /
// create_user_alert / set_user_alert_active / delete_user_alert). Phase 1 =
// create/manage only; delivery (Phase 2) is gated.
(function () {
  'use strict';

  const OPERATOR_LABELS = {
    drop_pct:     'drops by',
    rise_pct:     'rises by',
    below:        'falls below',
    above:        'rises above',
    available:    'becomes available',
    any_change:   'changes',
    crosses_into: 'triggers',
  };
  const COOLDOWNS = [
    [15, '15 min'], [60, '1 hour'], [360, '6 hours'], [720, '12 hours'], [1440, '24 hours'],
  ];
  const needsThreshold = (op) => ['drop_pct', 'rise_pct', 'below', 'above'].includes(op);
  const PARAM_LABEL = { zone: 'Zone', section: 'Section', city: 'City' };

  function rpc(name, args) {
    const Auth = window.TerminalAuth;
    if (!Auth || !Auth.client || !Auth.getAccessToken || !Auth.getAccessToken()) {
      return Promise.resolve({ error: { message: 'sign in to use alerts (no auth in localhost dev)' } });
    }
    return Auth.client.rpc(name, args);
  }

  function el(tag, attrs, ...kids) {
    const n = document.createElement(tag);
    if (attrs) for (const k in attrs) {
      if (k === 'class') n.className = attrs[k];
      else if (k === 'text') n.textContent = attrs[k];
      else if (k.startsWith('on') && typeof attrs[k] === 'function') n.addEventListener(k.slice(2), attrs[k]);
      else if (attrs[k] != null) n.setAttribute(k, attrs[k]);
    }
    for (const kid of kids) if (kid != null) n.append(kid.nodeType ? kid : document.createTextNode(kid));
    return n;
  }

  function unitFor(metric, op) {
    if (op === 'drop_pct' || op === 'rise_pct') return '%';
    return metric.threshold_unit || '';
  }

  function alertSummary(a, catalog) {
    const m = catalog[a.metric_key];
    const label = m ? m.label : a.metric_key;
    const opLabel = OPERATOR_LABELS[a.operator] || a.operator;
    let s = `${label} ${opLabel}`;
    if (needsThreshold(a.operator) && a.threshold != null) {
      const unit = unitFor(m || {}, a.operator);
      if (unit === '$') s += ` $${a.threshold}`;
      else if (unit === '%') s += ` ${a.threshold}%`;
      else s += unit ? ` ${a.threshold} ${unit}` : ` ${a.threshold}`;
    }
    const pk = m && m.param_kind;
    if (pk && a.params && a.params[pk]) s += ` (${PARAM_LABEL[pk] || pk}: ${a.params[pk]})`;
    const chans = (a.channels || []).join(' + ');
    const cd = (COOLDOWNS.find((c) => c[0] === a.cooldown_minutes) || [null, `${a.cooldown_minutes}m`])[1];
    return `${s} · ${chans} · every ${cd}`;
  }

  // ---- create form -----------------------------------------------------------
  function buildForm(ctx, metrics, onCreated) {
    const byKey = ctx.catalog;

    const metricSel = el('select', { class: 'alert-input', id: ctx.uid('metric') });
    metrics.forEach((m) => metricSel.append(el('option', { value: m.metric_key }, m.label)));

    const opSel        = el('select', { class: 'alert-input', id: ctx.uid('op') });
    const thrWrap      = el('label', { class: 'alert-field', hidden: '' });
    const thrInput     = el('input', { class: 'alert-input', type: 'number', step: 'any', min: '0', placeholder: '0' });
    const thrUnit      = el('span', { class: 'alert-unit muted' });
    thrWrap.append(el('span', { class: 'alert-flabel', text: 'Threshold' }), el('span', { class: 'row' }, thrInput, thrUnit));

    const paramWrap    = el('label', { class: 'alert-field', hidden: '' });
    const paramInput   = el('input', { class: 'alert-input', type: 'text', placeholder: '' });
    const paramLabel   = el('span', { class: 'alert-flabel' });
    paramWrap.append(paramLabel, paramInput);

    function syncMetric() {
      const m = byKey[metricSel.value];
      opSel.innerHTML = '';
      (m.allowed_operators || []).forEach((op) =>
        opSel.append(el('option', { value: op }, OPERATOR_LABELS[op] || op)));
      opSel.value = m.default_operator && m.allowed_operators.includes(m.default_operator)
        ? m.default_operator : (m.allowed_operators[0] || '');
      // param field
      if (m.param_kind) {
        paramWrap.hidden = false;
        paramLabel.textContent = PARAM_LABEL[m.param_kind] || m.param_kind;
        paramInput.placeholder = m.param_kind === 'city' ? 'e.g. New York' : 'e.g. 100 Level';
      } else { paramWrap.hidden = true; paramInput.value = ''; }
      syncOp();
    }
    function syncOp() {
      const m = byKey[metricSel.value];
      const op = opSel.value;
      if (needsThreshold(op)) {
        thrWrap.hidden = false;
        const u = unitFor(m, op);
        thrUnit.textContent = u;
        thrInput.placeholder = (op === 'drop_pct' || op === 'rise_pct') ? '15' : '';
      } else { thrWrap.hidden = true; thrInput.value = ''; }
    }
    metricSel.addEventListener('change', syncMetric);
    opSel.addEventListener('change', syncOp);

    // channels
    const prefillEmail = (window.TerminalAuth && window.TerminalAuth.user && window.TerminalAuth.user.email) || '';
    const emailCb   = el('input', { type: 'checkbox', checked: '' });
    const emailIn   = el('input', { class: 'alert-input', type: 'email', placeholder: 'you@example.com', value: prefillEmail });
    const smsCb     = el('input', { type: 'checkbox' });
    const smsIn     = el('input', { class: 'alert-input', type: 'tel', placeholder: '+1 555 123 4567', hidden: '' });
    smsCb.addEventListener('change', () => { smsIn.hidden = !smsCb.checked; });
    emailCb.addEventListener('change', () => { emailIn.hidden = !emailCb.checked; });

    const cdSel = el('select', { class: 'alert-input' });
    COOLDOWNS.forEach(([v, lbl]) => cdSel.append(el('option', { value: v }, lbl)));
    cdSel.value = '720';

    const err = el('div', { class: 'alert-err', hidden: '' });
    const createBtn = el('button', { class: 'alert-btn', type: 'button' }, 'Create alert');

    createBtn.addEventListener('click', async () => {
      err.hidden = true;
      const m = byKey[metricSel.value];
      const op = opSel.value;
      const channels = [];
      if (emailCb.checked) channels.push('email');
      if (smsCb.checked) channels.push('sms');
      if (!channels.length) { err.hidden = false; err.textContent = 'Pick at least one channel.'; return; }
      const params = {};
      if (m.param_kind && paramInput.value.trim()) params[m.param_kind] = paramInput.value.trim();
      createBtn.disabled = true; createBtn.textContent = 'Creating…';
      const res = await rpc('create_user_alert', {
        p_scope_type: ctx.scopeType,
        p_scope_id: ctx.scopeId,
        p_metric_key: m.metric_key,
        p_operator: op,
        p_threshold: needsThreshold(op) && thrInput.value !== '' ? Number(thrInput.value) : null,
        p_params: params,
        p_channels: channels,
        p_notify_email: emailCb.checked ? emailIn.value.trim() : null,
        p_notify_phone: smsCb.checked ? smsIn.value.trim() : null,
        p_cooldown_minutes: Number(cdSel.value),
        p_scope_label: ctx.scopeLabel || null,
      });
      createBtn.disabled = false; createBtn.textContent = 'Create alert';
      if (res.error) { err.hidden = false; err.textContent = res.error.message || 'Could not create alert.'; return; }
      onCreated(res.data);
    });

    syncMetric();

    const fields = el('div', { class: 'alert-form-grid' },
      el('label', { class: 'alert-field' }, el('span', { class: 'alert-flabel', text: 'Alert me when' }), metricSel),
      el('label', { class: 'alert-field' }, el('span', { class: 'alert-flabel', text: 'Condition' }), opSel),
      thrWrap,
      paramWrap,
      el('div', { class: 'alert-field' },
        el('span', { class: 'alert-flabel', text: 'Notify via' }),
        el('div', { class: 'alert-channels' },
          el('label', { class: 'alert-chan' }, emailCb, ' Email'), emailIn,
          el('label', { class: 'alert-chan' }, smsCb, ' SMS'), smsIn)),
      el('label', { class: 'alert-field' }, el('span', { class: 'alert-flabel', text: 'At most once per' }), cdSel),
    );
    return el('div', { class: 'alert-create' },
      el('div', { class: 'panel-title', text: 'CREATE ALERT' }), fields, err, createBtn);
  }

  // ---- existing list ---------------------------------------------------------
  function renderList(ctx, listEl, alerts) {
    listEl.innerHTML = '';
    if (!alerts.length) {
      listEl.append(el('div', { class: 'empty', text: 'No alerts yet for this ' + ctx.scopeType + '.' }));
      return;
    }
    alerts.forEach((a) => listEl.append(rowFor(ctx, a)));
  }
  function rowFor(ctx, a) {
    const summary = el('span', { class: 'alert-row-summary' + (a.active ? '' : ' off') }, alertSummary(a, ctx.catalog));
    const toggle = el('button', { class: 'alert-mini', type: 'button' }, a.active ? 'Pause' : 'Resume');
    const del    = el('button', { class: 'alert-mini danger', type: 'button' }, 'Delete');
    const row = el('div', { class: 'alert-row' }, summary, el('span', { class: 'alert-row-actions' }, toggle, del));
    toggle.addEventListener('click', async () => {
      toggle.disabled = true;
      const res = await rpc('set_user_alert_active', { p_id: a.id, p_active: !a.active });
      toggle.disabled = false;
      if (res.error) return;
      a.active = res.data.active;
      summary.classList.toggle('off', !a.active);
      toggle.textContent = a.active ? 'Pause' : 'Resume';
    });
    del.addEventListener('click', async () => {
      del.disabled = true;
      const res = await rpc('delete_user_alert', { p_id: a.id });
      if (res.error) { del.disabled = false; return; }
      row.remove();
    });
    return row;
  }

  // ---- public API ------------------------------------------------------------
  async function mount(scopeType, scopeId, scopeLabel, rootEl) {
    if (!rootEl || rootEl.__alertsMounted) return;
    rootEl.__alertsMounted = true;
    let seq = 0;
    const ctx = {
      scopeType, scopeId: Number(scopeId), scopeLabel, catalog: {},
      uid: (s) => `alrt_${scopeType}_${s}_${++seq}`,
    };
    rootEl.innerHTML = '<div class="empty">Loading alerts…</div>';

    const [cat, list] = await Promise.all([
      rpc('get_alert_metric_catalog', { p_scope_type: scopeType }),
      rpc('list_user_alerts', { p_scope_type: scopeType, p_scope_id: ctx.scopeId }),
    ]);
    if (cat.error) {
      rootEl.innerHTML = '';
      rootEl.append(el('div', { class: 'empty', text: cat.error.message || 'Alerts unavailable.' }));
      rootEl.__alertsMounted = false;
      return;
    }
    const metrics = cat.data || [];
    metrics.forEach((m) => { ctx.catalog[m.metric_key] = m; });

    const listEl = el('div', { class: 'alert-list' });
    const form = buildForm(ctx, metrics, (created) => {
      // prepend the new alert
      const existing = listEl.querySelector('.empty');
      if (existing) existing.remove();
      listEl.prepend(rowFor(ctx, created));
    });

    rootEl.innerHTML = '';
    rootEl.append(form, el('div', { class: 'alert-existing' },
      el('div', { class: 'panel-title', text: 'YOUR ALERTS' }), listEl));
    renderList(ctx, listEl, (list && list.data) || []);
  }

  window.TerminalAlerts = { mount };
})();
