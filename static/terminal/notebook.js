// D0 Terminal — NOTEBOOK tab. open-notebook port UI over /api/notebook/*.
// Notebooks · sources (text/URL/PDF) · RAG ask · context chat · transformations
// · podcasts. Vanilla JS, reuses window.Terminal (API_BASE + auth headers) and
// TermRender.escapeHtml. No framework/bundler (matches the terminal surface).

(function () {
  'use strict';

  const esc = (window.TermRender && window.TermRender.escapeHtml) ||
    (s => String(s == null ? '' : s).replace(/[&<>"']/g, c =>
      ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c])));

  const T = window.Terminal || {};
  const API_BASE = T.API_BASE || '';
  const setStatus = T.setStatus || function (m) { const el = document.getElementById('status'); if (el) el.textContent = m; };

  const state = { notebooks: [], current: null, session: null, transforms: [], config: null, selectedPerformer: null };

  // ---------- fetch helpers ----------
  function authHeaders() { return (T.getAuthHeader ? T.getAuthHeader() : {}); }

  async function apiFetch(path, opts) {
    opts = opts || {};
    const headers = Object.assign({ Accept: 'application/json' }, authHeaders());
    if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
    const res = await fetch(API_BASE + path, {
      method: opts.method || 'GET',
      headers,
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
      credentials: API_BASE ? 'omit' : 'same-origin',
      mode: API_BASE ? 'cors' : 'same-origin',
    });
    if (res.status === 401) throw new Error('401 — sign in with an @s4kent.com account');
    if (res.status === 403) throw new Error('403 — account not in the allowlist');
    if (!res.ok) {
      let detail = res.statusText;
      try { const j = await res.json(); detail = j.detail || detail; } catch (_) {}
      throw new Error(`${res.status} — ${detail}`);
    }
    if (res.status === 204) return null;
    return res.json();
  }

  const el = id => document.getElementById(id);
  function setHTML(node, html) { if (typeof node === 'string') node = el(node); if (node) node.innerHTML = html; }

  // ============================================================ NOTEBOOKS
  async function loadNotebooks() {
    try {
      const data = await apiFetch('/api/notebook/notebooks');
      state.notebooks = data.items || [];
      renderNotebookList();
      setStatus(`${state.notebooks.length} notebook${state.notebooks.length === 1 ? '' : 's'}`, 'ok');
    } catch (e) {
      setStatus(e.message, 'err');
      setHTML('nbList', `<div class="nb-empty">${esc(e.message)}</div>`);
    }
  }

  function renderNotebookList() {
    const box = el('nbList');
    if (!state.notebooks.length) { box.innerHTML = '<div class="nb-empty">No notebooks yet.<br>Click <b>+ New</b>.</div>'; return; }
    box.innerHTML = state.notebooks.map(nb => `
      <div class="nb-nb ${state.current && state.current.id === nb.id ? 'active' : ''}" data-id="${esc(nb.id)}">
        <div class="nm">${esc(nb.name)}</div>
        ${nb.description ? `<div class="ds">${esc(nb.description)}</div>` : ''}
      </div>`).join('');
    box.querySelectorAll('.nb-nb').forEach(node =>
      node.addEventListener('click', () => selectNotebook(node.dataset.id)));
  }

  async function selectNotebook(id) {
    const nb = state.notebooks.find(n => n.id === id);
    if (!nb) return;
    state.current = nb; state.session = null;
    renderNotebookList();
    el('nbTitle').textContent = nb.name;
    el('nbDesc').textContent = nb.description || '';
    el('nbTabs').hidden = false;
    activateTab('sources');
  }

  async function createNotebook() {
    const name = prompt('Notebook name:');
    if (!name || !name.trim()) return;
    const description = prompt('Description (optional):') || null;
    try {
      const nb = await apiFetch('/api/notebook/notebooks', { method: 'POST', body: { name: name.trim(), description } });
      await loadNotebooks();
      selectNotebook(nb.id);
    } catch (e) { setStatus(e.message, 'err'); }
  }

  async function createPerformerNotebook() {
    // Yankees-first: default the prompt to New York Yankees; any performer name works.
    const name = prompt('Performer name (SQL digest → notebook):', 'New York Yankees');
    if (!name || !name.trim()) return;
    try {
      setStatus('resolving performer + building digest…', 'ok');
      const res = await apiFetch('/api/notebook/performers/notebook', { method: 'POST', body: { name: name.trim() } });
      await loadNotebooks();
      selectNotebook(res.notebook.id);
      // the digest ingests in the background — reflect status once done
      pollPerformerSource(res.source.id);
    } catch (e) { setStatus(e.message, 'err'); }
  }

  async function bulkMlbNotebooks() {
    if (!confirm('Generate a performer notebook for every MLB team? (Teams that already have one are skipped.)')) return;
    try {
      setStatus('force-running MLB teams…', 'ok');
      const res = await apiFetch('/api/notebook/performers/bulk', { method: 'POST', body: { league: 'MLB' } });
      setStatus(`MLB: ${res.created_count} created, ${res.skipped_count} already existed`, 'ok');
      await loadNotebooks();
    } catch (e) { setStatus(e.message, 'err'); }
  }

  async function pollPerformerSource(id, tries) {
    tries = tries || 0;
    if (tries > 40) return;
    try {
      const s = await apiFetch(`/api/notebook/sources/${id}/status`);
      if (s.status === 'done' || s.status === 'error') {
        setStatus(s.status === 'done' ? 'performer digest ready' : ('digest failed: ' + (s.error || '')), s.status === 'done' ? 'ok' : 'err');
        if (state.current) activateTab('sources');
        return;
      }
    } catch (_) {}
    setTimeout(() => pollPerformerSource(id, tries + 1), 2500);
  }

  // ============================================================ TABS
  function activateTab(tab) {
    document.querySelectorAll('.nb-tab').forEach(b => b.classList.toggle('active', b.dataset.tab === tab));
    document.querySelectorAll('.nb-panel').forEach(p => {
      const on = p.dataset.panel === tab;
      p.classList.toggle('active', on);
      p.style.display = on ? (tab === 'chat' ? 'flex' : 'block') : 'none';
    });
    const renderers = {
      sources: renderSources, notes: renderNotes, ask: renderAsk,
      chat: renderChat, podcasts: renderPodcasts,
      transformations: renderTransforms, settings: renderSettings,
    };
    if (renderers[tab]) renderers[tab]();
  }

  // ============================================================ SOURCES
  async function renderSources() {
    const p = el('panelSources');
    p.innerHTML = `
      <div class="nb-card">
        <div class="nb-form">
          <div class="nb-row">
            <select class="nb-in" id="srcKind" style="max-width:160px">
              <option value="performer">Performer (SQL)</option>
              <option value="text">Text</option>
              <option value="url">URL</option>
              <option value="pdf">PDF</option>
            </select>
            <input class="nb-in" id="srcTitle" placeholder="Title (optional)" style="flex:1" />
          </div>
          <div id="srcInput"></div>
          <div class="nb-row between">
            <span class="nb-note">Sources are extracted, chunked, and embedded in the background.</span>
            <button class="nb-btn" id="srcAdd">Add source</button>
          </div>
        </div>
      </div>
      <div id="srcList"><div class="nb-empty">Loading…</div></div>`;
    el('srcKind').addEventListener('change', renderSourceInput);
    renderSourceInput();
    el('srcAdd').addEventListener('click', addSource);
    await loadSources();
  }

  function renderSourceInput() {
    const kind = el('srcKind').value;
    const box = el('srcInput');
    state.selectedPerformer = null;
    if (kind === 'performer') {
      box.innerHTML = `
        <div class="nb-perf-wrap">
          <input class="nb-in" id="srcPerformer" placeholder="Search performers (EVO)…" autocomplete="off" spellcheck="false" />
          <div class="nb-perf-suggest" id="srcPerfSuggest" hidden></div>
        </div>
        <div class="nb-note" id="srcPerfPick">Type a performer name, then pick a match from EVO search.</div>`;
      wirePerformerSearch();
    } else if (kind === 'text') {
      box.innerHTML = '<textarea class="nb-in" id="srcText" placeholder="Paste text…"></textarea>';
    } else if (kind === 'url') {
      box.innerHTML = '<input class="nb-in" id="srcUrl" placeholder="https://example.com/article" />';
    } else {
      box.innerHTML = '<input type="file" id="srcFile" accept="application/pdf" class="nb-in" />';
    }
  }

  // Typeahead over the EVO/TEvo performer search (/api/performers?q=). Picking a
  // result captures its tevo_performer_id so the source is added by id (no
  // server-side name guessing).
  function wirePerformerSearch() {
    const input = el('srcPerformer');
    const sugg = el('srcPerfSuggest');
    const pick = el('srcPerfPick');
    let debounce = 0;
    input.addEventListener('input', () => {
      state.selectedPerformer = null;
      pick.textContent = 'Type a performer name, then pick a match from EVO search.';
      clearTimeout(debounce);
      const q = input.value.trim();
      if (q.length < 2) { sugg.hidden = true; sugg.innerHTML = ''; return; }
      debounce = setTimeout(() => runPerformerSearch(q, sugg, input, pick), 250);
    });
    document.addEventListener('click', (e) => {
      if (!sugg.contains(e.target) && e.target !== input) { sugg.hidden = true; }
    });
  }

  async function runPerformerSearch(q, sugg, input, pick) {
    sugg.hidden = false;
    sugg.innerHTML = '<div class="nb-perf-row muted">searching EVO…</div>';
    try {
      const data = await apiFetch('/api/performers?fuzzy=true&q=' + encodeURIComponent(q));
      const results = (data && data.performers) || [];
      if (!results.length) { sugg.innerHTML = '<div class="nb-perf-row muted">no EVO matches</div>'; return; }
      sugg.innerHTML = results.slice(0, 12).map(p => {
        const cat = (p.category && (p.category.name || (p.category.parent && p.category.parent.name))) || '';
        return `<div class="nb-perf-row" data-id="${esc(p.id)}" data-name="${esc(p.name)}">
          <span>${esc(p.name)}</span><span class="muted small">${esc(cat)}</span></div>`;
      }).join('');
      sugg.querySelectorAll('.nb-perf-row[data-id]').forEach(row => row.addEventListener('click', () => {
        state.selectedPerformer = { id: Number(row.dataset.id), name: row.dataset.name };
        input.value = row.dataset.name;
        pick.innerHTML = `Selected: <b>${esc(row.dataset.name)}</b> <span class="muted">(EVO id ${esc(row.dataset.id)})</span>`;
        sugg.hidden = true;
      }));
    } catch (e) { sugg.innerHTML = `<div class="nb-perf-row muted">${esc(e.message)}</div>`; }
  }

  async function addSource() {
    const kind = el('srcKind').value;
    const title = el('srcTitle').value.trim() || null;
    const body = { kind, title };
    try {
      if (kind === 'performer') {
        if (state.selectedPerformer) {
          body.performer_id = state.selectedPerformer.id;
          body.performer_name = state.selectedPerformer.name;
        } else {
          // no pick from the EVO dropdown — fall back to resolving the typed text
          body.performer_name = el('srcPerformer').value.trim();
          if (!body.performer_name) return setStatus('search and pick a performer', 'err');
        }
      } else if (kind === 'text') {
        body.text = el('srcText').value;
        if (!body.text.trim()) return setStatus('text required', 'err');
      } else if (kind === 'url') {
        body.url = el('srcUrl').value.trim();
        if (!body.url) return setStatus('url required', 'err');
      } else {
        const f = el('srcFile').files[0];
        if (!f) return setStatus('choose a PDF', 'err');
        body.data = await fileToBase64(f);
        body.filename = f.name;
      }
      el('srcAdd').disabled = true;
      const res = await apiFetch(`/api/notebook/notebooks/${state.current.id}/sources`, { method: 'POST', body });
      setStatus('source queued — extracting…', 'ok');
      await loadSources();
      pollSource(res.source.id);
    } catch (e) { setStatus(e.message, 'err'); }
    finally { el('srcAdd').disabled = false; }
  }

  function fileToBase64(file) {
    return new Promise((resolve, reject) => {
      const r = new FileReader();
      r.onload = () => resolve(String(r.result).split(',', 2)[1] || '');
      r.onerror = reject;
      r.readAsDataURL(file);
    });
  }

  async function loadSources() {
    try {
      const data = await apiFetch(`/api/notebook/notebooks/${state.current.id}/sources`);
      const items = data.items || [];
      const box = el('srcList');
      if (!items.length) { box.innerHTML = '<div class="nb-empty">No sources yet.</div>'; return; }
      box.innerHTML = items.map(s => `
        <div class="nb-card" data-src="${esc(s.id)}">
          <div class="nb-row between">
            <div class="t">${esc(s.title || '(untitled)')} <span class="nb-badge ${esc(s.status)}">${esc(s.status)}</span></div>
            <div class="nb-row">
              <button class="nb-btn ghost" data-act="insights" data-id="${esc(s.id)}">Insights</button>
              <button class="nb-btn danger" data-act="del" data-id="${esc(s.id)}">Delete</button>
            </div>
          </div>
          ${s.error ? `<div class="m" style="color:var(--neg)">${esc(s.error)}</div>` : ''}
          ${s.full_text ? `<div class="m">${esc(s.full_text.slice(0, 220))}${s.full_text.length > 220 ? '…' : ''}</div>` : ''}
          <div class="nb-insights" id="ins-${esc(s.id)}"></div>
        </div>`).join('');
      box.querySelectorAll('button[data-act]').forEach(b => b.addEventListener('click', () => {
        if (b.dataset.act === 'del') deleteSource(b.dataset.id);
        else toggleInsights(b.dataset.id);
      }));
    } catch (e) { setStatus(e.message, 'err'); }
  }

  async function pollSource(id, tries) {
    tries = tries || 0;
    if (tries > 40) return;
    try {
      const s = await apiFetch(`/api/notebook/sources/${id}/status`);
      if (s.status === 'done' || s.status === 'error') { await loadSources(); return; }
    } catch (_) {}
    setTimeout(() => pollSource(id, tries + 1), 2500);
  }

  async function deleteSource(id) {
    if (!confirm('Delete this source?')) return;
    try { await apiFetch(`/api/notebook/sources/${id}`, { method: 'DELETE' }); await loadSources(); }
    catch (e) { setStatus(e.message, 'err'); }
  }

  async function toggleInsights(id) {
    const box = el('ins-' + id);
    if (!box) return;
    if (box.dataset.open === '1') { box.innerHTML = ''; box.dataset.open = '0'; return; }
    box.dataset.open = '1';
    box.innerHTML = '<div class="nb-note">Loading insights…</div>';
    try {
      const data = await apiFetch(`/api/notebook/sources/${id}/insights`);
      const items = data.items || [];
      const opts = state.transforms.length
        ? `<div class="nb-row" style="margin-top:6px">
             <select class="nb-in" id="tf-${esc(id)}" style="max-width:200px">
               ${state.transforms.map(t => `<option value="${esc(t.id)}">${esc(t.title || t.name)}</option>`).join('')}
             </select>
             <button class="nb-btn ghost" data-run="${esc(id)}">Run transformation</button>
           </div>` : '<div class="nb-note">No transformations defined (see the Transformations panel).</div>';
      box.innerHTML = (items.length
        ? items.map(i => `<div class="nb-passage"><b>${esc(i.insight_type)}</b><br>${esc(i.content)}</div>`).join('')
        : '<div class="nb-note">No insights yet.</div>') + opts;
      const btn = box.querySelector('button[data-run]');
      if (btn) btn.addEventListener('click', () => runTransformation(id, el('tf-' + id).value));
    } catch (e) { box.innerHTML = `<div class="nb-note">${esc(e.message)}</div>`; }
  }

  async function runTransformation(sourceId, transformationId) {
    try {
      setStatus('running transformation…', 'ok');
      await apiFetch(`/api/notebook/sources/${sourceId}/insights`, { method: 'POST', body: { transformation_id: transformationId } });
      const box = el('ins-' + sourceId); if (box) box.dataset.open = '0';
      await toggleInsights(sourceId);
      setStatus('insight added', 'ok');
    } catch (e) { setStatus(e.message, 'err'); }
  }

  // ============================================================ NOTES
  async function renderNotes() {
    const p = el('panelNotes');
    p.innerHTML = `
      <div class="nb-card"><div class="nb-form">
        <input class="nb-in" id="noteTitle" placeholder="Note title (optional)" />
        <textarea class="nb-in" id="noteBody" placeholder="Write a note…"></textarea>
        <div class="nb-row between"><span></span><button class="nb-btn" id="noteAdd">Add note</button></div>
      </div></div>
      <div id="noteList"><div class="nb-empty">Loading…</div></div>`;
    el('noteAdd').addEventListener('click', addNote);
    await loadNotes();
  }

  async function addNote() {
    const content = el('noteBody').value.trim();
    if (!content) return setStatus('note body required', 'err');
    try {
      await apiFetch(`/api/notebook/notebooks/${state.current.id}/notes`, { method: 'POST', body: { title: el('noteTitle').value.trim() || null, content } });
      el('noteBody').value = ''; el('noteTitle').value = '';
      await loadNotes();
    } catch (e) { setStatus(e.message, 'err'); }
  }

  async function loadNotes() {
    try {
      const data = await apiFetch(`/api/notebook/notebooks/${state.current.id}/notes`);
      const items = data.items || [];
      const box = el('noteList');
      box.innerHTML = items.length ? items.map(n => `
        <div class="nb-card">
          <div class="nb-row between">
            <div class="t">${esc(n.title || '(untitled note)')} ${n.note_type === 'ai' ? '<span class="nb-badge">ai</span>' : ''}</div>
            <button class="nb-btn danger" data-del="${esc(n.id)}">Delete</button>
          </div>
          <div class="bd" style="white-space:pre-wrap; color:var(--text); font-size:13px; margin-top:6px">${esc(n.content || '')}</div>
        </div>`).join('') : '<div class="nb-empty">No notes yet.</div>';
      box.querySelectorAll('button[data-del]').forEach(b => b.addEventListener('click', async () => {
        if (!confirm('Delete note?')) return;
        try { await apiFetch(`/api/notebook/notes/${b.dataset.del}`, { method: 'DELETE' }); await loadNotes(); }
        catch (e) { setStatus(e.message, 'err'); }
      }));
    } catch (e) { setStatus(e.message, 'err'); }
  }

  // ============================================================ ASK (RAG)
  function renderAsk() {
    const p = el('panelAsk');
    p.innerHTML = `
      <div class="nb-card"><div class="nb-form">
        <input class="nb-in" id="askQ" placeholder="Ask a question grounded in this notebook's sources…" />
        <div class="nb-row between">
          <span class="nb-note">Decomposes the question → vector-searches your sources → synthesizes a cited answer.</span>
          <button class="nb-btn" id="askBtn">Ask</button>
        </div>
      </div></div>
      <div id="askOut"></div>`;
    const go = () => doAsk();
    el('askBtn').addEventListener('click', go);
    el('askQ').addEventListener('keydown', e => { if (e.key === 'Enter') go(); });
  }

  async function doAsk() {
    const q = el('askQ').value.trim();
    if (!q) return;
    el('askBtn').disabled = true;
    setHTML('askOut', '<div class="nb-note">Thinking…</div>');
    try {
      const r = await apiFetch('/api/notebook/search/ask', { method: 'POST', body: { question: q, notebook_id: state.current.id } });
      const passages = (r.passages || []).map(p =>
        `<div class="nb-passage">[${esc(p.index)}] <span class="nb-badge">${esc(p.kind || '')}</span> ${esc((p.content || '').slice(0, 300))}${(p.content || '').length > 300 ? '…' : ''}</div>`).join('');
      setHTML('askOut', `
        <div class="nb-card"><div class="t">Answer</div>
          <div class="bd" style="white-space:pre-wrap;color:var(--text);font-size:13px;margin-top:6px">${esc(r.answer || '')}</div></div>
        <div class="nb-note">Retrieval: ${esc(r.mode || 'text')}${r.mode === 'text' ? ' (full-text — set OPENAI_API_KEY for vector search)' : ''}</div>
        ${r.queries && r.queries.length ? `<div class="nb-note">Sub-queries: ${r.queries.map(esc).join(' · ')}</div>` : ''}
        ${passages ? `<div class="nb-card"><div class="t">Retrieved passages</div>${passages}</div>` : ''}`);
    } catch (e) { setHTML('askOut', `<div class="nb-hint">${esc(e.message)}</div>`); }
    finally { el('askBtn').disabled = false; }
  }

  // ============================================================ CHAT
  async function renderChat() {
    const p = el('panelChat');
    p.innerHTML = `
      <div class="nb-chatlog" id="chatLog"><div class="nb-empty">Starting a chat session…</div></div>
      <div class="nb-chatform">
        <input class="nb-in" id="chatIn" placeholder="Message — grounded in the whole notebook context…" />
        <button class="nb-btn" id="chatSend">Send</button>
      </div>`;
    el('chatSend').addEventListener('click', sendChat);
    el('chatIn').addEventListener('keydown', e => { if (e.key === 'Enter') sendChat(); });
    try {
      if (!state.session) {
        const s = await apiFetch(`/api/notebook/notebooks/${state.current.id}/chat/sessions`, { method: 'POST', body: {} });
        state.session = s.id;
      }
      await loadChat();
    } catch (e) { setHTML('chatLog', `<div class="nb-hint">${esc(e.message)}</div>`); }
  }

  async function loadChat() {
    const data = await apiFetch(`/api/notebook/chat/sessions/${state.session}/messages`);
    const items = data.items || [];
    const log = el('chatLog');
    log.innerHTML = items.length ? items.map(renderMsg).join('') : '<div class="nb-empty">No messages yet — say hello.</div>';
    log.scrollTop = log.scrollHeight;
  }

  function renderMsg(m) {
    return `<div class="nb-msg ${m.role === 'user' ? 'user' : ''}"><div class="who">${esc(m.role)}</div><div class="bd">${esc(m.content)}</div></div>`;
  }

  async function sendChat() {
    const input = el('chatIn');
    const msg = input.value.trim();
    if (!msg || !state.session) return;
    input.value = '';
    const log = el('chatLog');
    if (log.querySelector('.nb-empty')) log.innerHTML = '';
    log.insertAdjacentHTML('beforeend', renderMsg({ role: 'user', content: msg }));
    const assistant = document.createElement('div');
    assistant.className = 'nb-msg';
    assistant.innerHTML = '<div class="who">assistant</div><div class="bd"></div>';
    log.appendChild(assistant);
    const bd = assistant.querySelector('.bd');
    log.scrollTop = log.scrollHeight;
    el('chatSend').disabled = true;
    try {
      await streamChat(msg, chunk => { bd.textContent += chunk; log.scrollTop = log.scrollHeight; });
    } catch (e) { bd.innerHTML = `<span class="nb-hint">${esc(e.message)}</span>`; }
    finally { el('chatSend').disabled = false; }
  }

  // SSE via fetch reader (EventSource can't send the Authorization header).
  async function streamChat(message, onDelta) {
    const headers = Object.assign({ Accept: 'text/event-stream', 'Content-Type': 'application/json' }, authHeaders());
    const res = await fetch(`${API_BASE}/api/notebook/chat/sessions/${state.session}/messages`, {
      method: 'POST', headers, body: JSON.stringify({ message }),
      credentials: API_BASE ? 'omit' : 'same-origin', mode: API_BASE ? 'cors' : 'same-origin',
    });
    if (!res.ok || !res.body) {
      let d = res.statusText; try { const j = await res.json(); d = j.detail || d; } catch (_) {}
      throw new Error(`${res.status} — ${d}`);
    }
    const reader = res.body.getReader();
    const dec = new TextDecoder();
    let buf = '';
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let idx;
      while ((idx = buf.indexOf('\n\n')) !== -1) {
        const line = buf.slice(0, idx).trim(); buf = buf.slice(idx + 2);
        if (!line.startsWith('data:')) continue;
        let ev; try { ev = JSON.parse(line.slice(5).trim()); } catch (_) { continue; }
        if (ev.delta) onDelta(ev.delta);
        else if (ev.error) throw new Error(ev.error);
      }
    }
  }

  // ============================================================ PODCASTS
  async function renderPodcasts() {
    const p = el('panelPodcasts');
    p.innerHTML = `
      <div class="nb-card"><div class="nb-form">
        <div class="t">Generate a podcast from this notebook</div>
        <input class="nb-in" id="podName" placeholder="Episode name" />
        <textarea class="nb-in" id="podBrief" placeholder="Briefing / angle (optional)"></textarea>
        <div class="nb-split">
          <div>
            <div class="nb-note">Segments</div>
            <input class="nb-in" id="podSegs" type="number" value="4" min="2" max="12" />
          </div>
          <div>
            <div class="nb-note">Speakers (comma-separated)</div>
            <input class="nb-in" id="podSpeakers" placeholder="Alex, Sam" value="Alex, Sam" />
          </div>
        </div>
        <div class="nb-row between">
          <span class="nb-note">Outline → transcript → OpenAI TTS. Runs in the background; needs OpenAI + Anthropic keys.</span>
          <button class="nb-btn" id="podGen">Generate</button>
        </div>
      </div></div>
      <div class="nb-card"><div class="nb-form">
        <div class="t">Narrate text → shareable mp3</div>
        <textarea class="nb-in" id="narrText" placeholder="Paste text to read aloud (a note, an answer, anything)…"></textarea>
        <div class="nb-split">
          <div>
            <div class="nb-note">Episode name</div>
            <input class="nb-in" id="narrName" placeholder="Narration" />
          </div>
          <div>
            <div class="nb-note">Voice</div>
            <select class="nb-in" id="narrVoice">
              <option>alloy</option><option>echo</option><option>fable</option>
              <option>onyx</option><option>nova</option><option>shimmer</option>
            </select>
          </div>
        </div>
        <div class="nb-row between">
          <span class="nb-note">Single voice, no transcript. Produces a shareable mp3 link; needs an OpenAI key.</span>
          <button class="nb-btn" id="narrGen">Narrate</button>
        </div>
      </div></div>
      <div id="podList"><div class="nb-empty">Loading episodes…</div></div>`;
    el('podGen').addEventListener('click', genPodcast);
    el('narrGen').addEventListener('click', genNarration);
    await loadEpisodes();
  }

  async function genNarration() {
    const text = el('narrText').value.trim();
    if (!text) { setStatus('enter some text to narrate', 'err'); return; }
    const body = {
      text,
      name: el('narrName').value.trim() || 'Narration',
      voice: el('narrVoice').value || 'alloy',
    };
    try {
      el('narrGen').disabled = true;
      const res = await apiFetch(`/api/notebook/notebooks/${state.current.id}/narrate`, { method: 'POST', body });
      setStatus('narration queued — generating mp3…', 'ok');
      el('narrText').value = '';
      await loadEpisodes();
      pollEpisode(res.episode.id);
    } catch (e) { setStatus(e.message, 'err'); }
    finally { el('narrGen').disabled = false; }
  }

  async function genPodcast() {
    const name = el('podName').value.trim() || 'Untitled episode';
    const speakers = el('podSpeakers').value.split(',').map(s => s.trim()).filter(Boolean);
    const body = {
      name,
      briefing: el('podBrief').value.trim() || null,
      episode_profile: { num_segments: parseInt(el('podSegs').value, 10) || 4 },
      speaker_profile: { speakers: speakers.map(n => ({ name: n })) },
    };
    try {
      el('podGen').disabled = true;
      const res = await apiFetch(`/api/notebook/notebooks/${state.current.id}/podcasts`, { method: 'POST', body });
      setStatus('podcast queued — generating…', 'ok');
      await loadEpisodes();
      pollEpisode(res.episode.id);
    } catch (e) { setStatus(e.message, 'err'); }
    finally { el('podGen').disabled = false; }
  }

  async function loadEpisodes() {
    try {
      const data = await apiFetch('/api/notebook/episodes');
      const items = (data.items || []).filter(e => !state.current || e.notebook_id === state.current.id || !e.notebook_id);
      const box = el('podList');
      box.innerHTML = items.length ? items.map(e => `
        <div class="nb-card" data-ep="${esc(e.id)}">
          <div class="nb-row between">
            <div class="t">${esc(e.name)} <span class="nb-badge ${esc(e.status)}">${esc(e.status)}</span></div>
            <button class="nb-btn danger" data-delep="${esc(e.id)}">Delete</button>
          </div>
          ${e.error ? `<div class="m" style="color:${e.status === 'done' ? 'var(--accent)' : 'var(--neg)'}">${esc(e.error)}</div>` : ''}
          ${e.audio_url ? `<audio controls preload="none" style="width:100%;margin-top:8px" src="${esc(e.audio_url)}"></audio>
          <div class="nb-row" style="gap:8px;margin-top:6px">
            <button class="nb-btn" data-copyep="${esc(e.audio_url)}">Copy link</button>
            <a class="nb-btn" href="${esc(e.audio_url)}" download target="_blank" rel="noopener">Download</a>
          </div>` : ''}
          ${e.status === 'done' && e.content ? `<pre class="nb-transcript" style="white-space:pre-wrap;margin-top:8px;max-height:260px;overflow:auto;font-size:12px;line-height:1.5">${esc(e.content)}</pre>` : ''}
        </div>`).join('') : '<div class="nb-empty">No episodes yet.</div>';
      box.querySelectorAll('button[data-delep]').forEach(b => b.addEventListener('click', async () => {
        if (!confirm('Delete episode?')) return;
        try { await apiFetch(`/api/notebook/episodes/${b.dataset.delep}`, { method: 'DELETE' }); await loadEpisodes(); }
        catch (e) { setStatus(e.message, 'err'); }
      }));
      box.querySelectorAll('button[data-copyep]').forEach(b => b.addEventListener('click', async () => {
        const url = b.dataset.copyep;
        try {
          if (navigator.clipboard && navigator.clipboard.writeText) await navigator.clipboard.writeText(url);
          else { const t = document.createElement('textarea'); t.value = url; document.body.appendChild(t); t.select(); document.execCommand('copy'); t.remove(); }
          setStatus('audio link copied', 'ok');
        } catch (_) { setStatus('copy failed — link: ' + url, 'err'); }
      }));
    } catch (e) { setStatus(e.message, 'err'); }
  }

  async function pollEpisode(id, tries) {
    tries = tries || 0;
    if (tries > 60) return;
    try {
      const e = await apiFetch(`/api/notebook/episodes/${id}`);
      if (e.status === 'done' || e.status === 'error') { await loadEpisodes(); return; }
    } catch (_) {}
    setTimeout(() => pollEpisode(id, tries + 1), 4000);
  }

  // ============================================================ TRANSFORMATIONS
  async function renderTransforms() {
    el('nbTabs').hidden = false;
    activatePanelOnly('transformations');
    el('nbTitle').textContent = 'Transformations';
    el('nbDesc').textContent = 'Reusable prompts run over a source to produce insights.';
    const p = el('panelTransforms');
    p.innerHTML = `
      <div class="nb-card"><div class="nb-form">
        <div class="nb-row"><input class="nb-in" id="tfName" placeholder="Name (e.g. summary)" style="flex:1" />
          <label class="nb-note"><input type="checkbox" id="tfDefault" /> auto-run on ingest</label></div>
        <input class="nb-in" id="tfTitle" placeholder="Display title (optional)" />
        <textarea class="nb-in" id="tfPrompt" placeholder="Instruction, e.g. 'Summarize the key points as bullets.'"></textarea>
        <div class="nb-row between"><span></span><button class="nb-btn" id="tfAdd">Add transformation</button></div>
      </div></div>
      <div id="tfList"><div class="nb-empty">Loading…</div></div>`;
    el('tfAdd').addEventListener('click', addTransform);
    await loadTransforms();
  }

  async function loadTransforms() {
    try {
      const data = await apiFetch('/api/notebook/transformations');
      state.transforms = data.items || [];
      const box = el('tfList');
      if (!box) return;
      box.innerHTML = state.transforms.length ? state.transforms.map(t => `
        <div class="nb-card">
          <div class="nb-row between">
            <div class="t">${esc(t.title || t.name)} ${t.apply_default ? '<span class="nb-badge done">default</span>' : ''}</div>
            <button class="nb-btn danger" data-delt="${esc(t.id)}">Delete</button>
          </div>
          <div class="m">${esc(t.prompt)}</div>
        </div>`).join('') : '<div class="nb-empty">No transformations yet.</div>';
      box.querySelectorAll('button[data-delt]').forEach(b => b.addEventListener('click', async () => {
        try { await apiFetch(`/api/notebook/transformations/${b.dataset.delt}`, { method: 'DELETE' }); await loadTransforms(); }
        catch (e) { setStatus(e.message, 'err'); }
      }));
    } catch (e) { const box = el('tfList'); if (box) box.innerHTML = `<div class="nb-hint">${esc(e.message)}</div>`; }
  }

  async function addTransform() {
    const name = el('tfName').value.trim();
    const promptTxt = el('tfPrompt').value.trim();
    if (!name || !promptTxt) return setStatus('name and prompt required', 'err');
    try {
      await apiFetch('/api/notebook/transformations', { method: 'POST', body: {
        name, prompt: promptTxt, title: el('tfTitle').value.trim() || null, apply_default: el('tfDefault').checked,
      } });
      el('tfName').value = ''; el('tfPrompt').value = ''; el('tfTitle').value = ''; el('tfDefault').checked = false;
      await loadTransforms();
    } catch (e) { setStatus(e.message, 'err'); }
  }

  // ============================================================ SETTINGS
  async function renderSettings() {
    activatePanelOnly('settings');
    el('nbTitle').textContent = 'Settings';
    el('nbDesc').textContent = 'Provider status for the notebook AI features.';
    const p = el('panelSettings');
    p.innerHTML = '<div class="nb-note">Loading…</div>';
    try {
      const cfg = await apiFetch('/api/notebook/config');
      state.config = cfg;
      const pr = cfg.providers || {};
      const row = (label, ok, extra) => `<div class="nb-row between" style="padding:6px 0;border-bottom:1px solid var(--line,#1c1c1c)">
        <span>${esc(label)}</span><span class="nb-badge ${ok ? 'done' : 'error'}">${ok ? 'configured' : 'missing key'}${extra ? ' · ' + esc(extra) : ''}</span></div>`;
      p.innerHTML = `<div class="nb-card">
        ${row('Chat / transform / RAG (Anthropic)', pr.chat, pr.chat_model)}
        ${row('Embeddings (OpenAI)', pr.embeddings, pr.embed_model)}
        ${row('Transcription (OpenAI Whisper)', pr.transcription)}
        ${row('Text-to-speech (OpenAI)', pr.tts)}
        <div class="nb-note" style="margin-top:10px">Set <code>ANTHROPIC_API_KEY</code> and <code>OPENAI_API_KEY</code> on the server to enable AI features. CRUD and text search work without any keys.</div>
      </div>`;
    } catch (e) { p.innerHTML = `<div class="nb-hint">${esc(e.message)}</div>`; }
  }

  function activatePanelOnly(panel) {
    document.querySelectorAll('.nb-tab').forEach(b => b.classList.remove('active'));
    document.querySelectorAll('.nb-panel').forEach(p => {
      const on = p.dataset.panel === panel;
      p.classList.toggle('active', on);
      p.style.display = on ? 'block' : 'none';
    });
  }

  // ============================================================ INIT
  function wire() {
    el('nbNew').addEventListener('click', createNotebook);
    el('nbPerformer').addEventListener('click', createPerformerNotebook);
    el('nbBulkMlb').addEventListener('click', bulkMlbNotebooks);
    el('nbTransforms').addEventListener('click', renderTransforms);
    el('nbSettings').addEventListener('click', renderSettings);
    document.querySelectorAll('.nb-tab').forEach(b => b.addEventListener('click', () => {
      if (!state.current) return setStatus('select a notebook first', 'err');
      el('nbTitle').textContent = state.current.name;
      el('nbDesc').textContent = state.current.description || '';
      activateTab(b.dataset.tab);
    }));
  }

  async function start() {
    wire();
    // Load transformations once so the Sources panel can offer them.
    try { const d = await apiFetch('/api/notebook/transformations'); state.transforms = d.items || []; } catch (_) {}
    await loadNotebooks();
  }

  function boot() {
    if (window.TerminalAuth && window.TerminalAuth.ready) {
      window.TerminalAuth.ready.then(start).catch(start);
    } else { start(); }
  }

  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', boot);
  else boot();
})();
