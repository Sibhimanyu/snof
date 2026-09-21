/* SNOF live farm dashboard.
 *
 * Reads the mirror the Home Assistant add-on writes, groups entities by area and
 * re-renders on every RTDB delta. Read-only by design: the rules deny client
 * writes outright, so there is no path from this page to farm hardware.
 */
'use strict';

const FARM = 'snof';
const STALE_FACTOR = 2.5;   // heartbeats missed before we call the bridge stale
// "Zone 2" sorts before "Zone 10"; plain localeCompare puts 10 first.
const NATURAL = { numeric: true, sensitivity: 'base' };
// HA domains are slugs ("binary_sensor"); people read words.
const humanDomain = (d) => String(d).replace(/_/g, ' ');

const el = (id) => document.getElementById(id);
const gate = el('gate'), app = el('app');

let state = { meta: {}, areas: {}, entities: {} };
let filters = { text: '', domain: null };
let prevStates = new Map();
let refs = [];
let clockSkewMs = 0;

/* ---------- auth ---------- */

firebase.auth().onAuthStateChanged((user) => {
  if (user) enter(user); else leave();
});

el('signin').onclick = () => {
  const provider = new firebase.auth.GoogleAuthProvider();
  provider.setCustomParameters({ prompt: 'select_account' });
  firebase.auth().signInWithPopup(provider).catch((err) => {
    el('gate-msg').textContent = err.message;
  });
};
const doSignOut = () => firebase.auth().signOut();
el('signout').onclick = doSignOut;
el('signout-gate').onclick = doSignOut;

function leave() {
  refs.forEach(({ ref, cb }) => ref.off('value', cb));
  refs = [];
  state = { meta: {}, areas: {}, entities: {} };
  prevStates.clear();
  app.hidden = true;
  gate.hidden = false;
  el('signin').hidden = false;
  el('signout-gate').hidden = true;
  el('gate-msg').textContent = 'Sign in to view live farm state.';
}

function denied(user) {
  // Surfacing the UID turns "access denied" into a one-command fix:
  //   cd tools && npm run grant -- <email>
  refs.forEach(({ ref, cb }) => ref.off('value', cb));
  refs = [];
  app.hidden = true;
  gate.hidden = false;
  el('signin').hidden = true;
  el('signout-gate').hidden = false;
  el('gate-msg').innerHTML =
    `<strong>${escapeHtml(user.email || 'This account')}</strong> is not on the ` +
    `dashboard allowlist.<br><br>Ask the farm owner to run:<br>` +
    `<code style="display:inline-block;margin-top:6px;font-size:11px;opacity:.8">` +
    `npm run grant -- ${escapeHtml(user.email || '')}</code>`;
}

function enter(user) {
  // Hosting injects databaseURL only once an RTDB instance exists. Without this
  // guard firebase.database() throws an opaque "Can't determine URL" error.
  if (!firebase.app().options.databaseURL) {
    gate.hidden = false;
    app.hidden = true;
    el('signin').hidden = true;
    el('signout-gate').hidden = false;
    el('gate-msg').innerHTML =
      'No Realtime Database yet.<br><br>Create the default instance in the ' +
      'Firebase console, then reload this page. No redeploy needed.';
    return;
  }

  gate.hidden = true;
  app.hidden = false;

  const db = firebase.database();
  // Server time offset lets us judge heartbeat staleness without trusting the
  // viewer's clock, which on a wall tablet is often wrong.
  db.ref('.info/serverTimeOffset').on('value', (s) => { clockSkewMs = s.val() || 0; });

  const watch = (path, key) => {
    const ref = db.ref(`farms/${FARM}/${path}`);
    const cb = ref.on('value',
      (snap) => { state[key] = snap.val() || {}; render(); },
      (err) => { if (err.code === 'PERMISSION_DENIED') denied(user); else console.error(err); }
    );
    refs.push({ ref, cb });
  };
  watch('meta', 'meta');
  watch('areas', 'areas');
  watch('entities', 'entities');

  setInterval(renderBridgeStatus, 5000);
}

/* ---------- filtering ---------- */

el('search').oninput = (e) => { filters.text = e.target.value.trim().toLowerCase(); render(); };

function flatEntities() {
  const out = [];
  for (const [domain, objs] of Object.entries(state.entities || {})) {
    for (const [objectId, node] of Object.entries(objs || {})) {
      if (node && typeof node === 'object') out.push({ ...node, domain, objectId, key: `${domain}.${objectId}` });
    }
  }
  return out;
}

function matches(ent, areaName) {
  if (filters.domain && ent.domain !== filters.domain) return false;
  if (!filters.text) return true;
  const hay = `${ent.name} ${ent.entity_id} ${ent.state} ${areaName}`.toLowerCase();
  return hay.includes(filters.text);
}

/* ---------- render ---------- */

function render() {
  const ents = flatEntities();
  renderFilters(ents);
  renderBridgeStatus();

  const farmName = state.meta?.name || 'SNOF';
  el('farm-name').textContent = farmName;
  el('farm-sub').textContent = `${ents.length} entities in ${Object.keys(state.areas || {}).length} areas`;
  document.title = `${farmName} · Live`;

  const areaName = (id) => state.areas?.[id]?.name || 'Unassigned';
  const byArea = new Map();
  let shown = 0;
  for (const ent of ents) {
    const area = ent.area || 'unassigned';
    if (!matches(ent, areaName(area))) continue;
    if (!byArea.has(area)) byArea.set(area, []);
    byArea.get(area).push(ent);
    shown++;
  }

  const order = [...byArea.keys()].sort((a, b) => {
    if (a === 'unassigned') return 1;
    if (b === 'unassigned') return -1;
    return areaName(a).localeCompare(areaName(b), undefined, NATURAL);
  });

  const root = el('rooms');
  root.innerHTML = order.map((area) => {
    const list = byArea.get(area).sort((a, b) => (a.name || '').localeCompare(b.name || '', undefined, NATURAL));
    return `<section class="room">
      <div class="room-head">
        <span class="room-name">${escapeHtml(areaName(area))}</span>
        <span class="room-count">${list.length}</span>
      </div>
      ${list.map(renderEntity).join('')}
    </section>`;
  }).join('');

  el('empty').hidden = shown > 0 || ents.length === 0;
  el('stats').textContent = ents.length
    ? `Showing ${shown} of ${ents.length} entities · updated ${new Date().toLocaleTimeString()}`
    : 'Waiting for the bridge to publish its first snapshot…';

  flashChanged(ents);
}

function renderEntity(ent) {
  const cls = stateClass(ent.state);
  return `<div class="ent" data-key="${escapeHtml(ent.key)}">
    <div class="ent-main">
      <div class="ent-name">${escapeHtml(ent.name || ent.entity_id)}</div>
      <div class="ent-meta">${escapeHtml(humanDomain(ent.domain))}${subtitle(ent)}</div>
    </div>
    <div class="ent-state ${cls}">${escapeHtml(formatState(ent))}</div>
  </div>`;
}

function subtitle(ent) {
  const a = ent.attrs || {};
  const bits = [];
  if (a.device_class) bits.push(a.device_class);
  if (a.battery_level != null) bits.push(`${a.battery_level}% battery`);
  // One separator per line: domain, then the rest comma-joined.
  return bits.length ? ' · ' + escapeHtml(bits.join(', ')) : '';
}

function formatState(ent) {
  const s = ent.state;
  if (s == null || s === '') return '-';
  const unit = ent.attrs?.unit_of_measurement;
  if (unit) return `${s} ${unit}`;
  if (s === 'on' || s === 'off') return s.toUpperCase();
  return String(s);
}

function stateClass(s) {
  if (s === 'unavailable' || s === 'unknown' || s == null) return 'unavail';
  if (s === 'on' || s === 'open' || s === 'home' || s === 'playing') return 'on';
  if (s === 'off' || s === 'closed' || s === 'not_home' || s === 'idle') return 'off';
  return '';
}

function renderFilters(ents) {
  const domains = [...new Set(ents.map((e) => e.domain))].sort();
  const box = el('domain-filters');
  const wanted = domains.join(',') + '|' + filters.domain;
  if (box.dataset.sig === wanted) return;
  box.dataset.sig = wanted;
  // Rebuilding the row destroys the focused button; remember it so a keyboard
  // user toggling a filter is not dropped back to <body>.
  const active = document.activeElement;
  const focused = active && active.classList.contains('chip') ? active.dataset.domain : null;
  box.innerHTML = domains.map((d) =>
    `<button class="chip ${filters.domain === d ? 'on' : ''}" aria-pressed="${filters.domain === d}" ` +
    `data-domain="${escapeHtml(d)}">${escapeHtml(humanDomain(d))}</button>`
  ).join('');
  box.querySelectorAll('.chip').forEach((chip) => {
    chip.onclick = () => {
      filters.domain = filters.domain === chip.dataset.domain ? null : chip.dataset.domain;
      render();
    };
  });
  if (focused) {
    const again = box.querySelector(`.chip[data-domain="${CSS.escape(focused)}"]`);
    if (again) again.focus();
  }
}

function renderBridgeStatus() {
  const pill = el('bridge-pill'), text = el('bridge-text');
  const hb = state.meta?.bridge;
  pill.className = 'pill pill-unknown';

  if (!hb || !hb.lastSeen) { text.textContent = 'no bridge data'; return; }
  if (hb.status === 'offline') { pill.className = 'pill pill-offline'; text.textContent = 'bridge offline'; return; }

  const ageSec = (Date.now() + clockSkewMs - hb.lastSeen) / 1000;
  const budget = (hb.heartbeatSeconds || 30) * STALE_FACTOR;
  if (ageSec > budget) {
    pill.className = 'pill pill-stale';
    text.textContent = `stale ${humanAge(ageSec)}`;
  } else {
    pill.className = 'pill pill-online';
    text.textContent = 'live';
  }
}

function flashChanged(ents) {
  for (const ent of ents) {
    const before = prevStates.get(ent.key);
    if (before !== undefined && before !== ent.state) {
      const node = document.querySelector(`.ent[data-key="${CSS.escape(ent.key)}"]`);
      if (node) { node.classList.remove('flash'); void node.offsetWidth; node.classList.add('flash'); }
    }
    prevStates.set(ent.key, ent.state);
  }
}

/* ---------- utils ---------- */

function humanAge(sec) {
  if (sec < 90) return `${Math.round(sec)}s`;
  if (sec < 5400) return `${Math.round(sec / 60)}m`;
  return `${Math.round(sec / 3600)}h`;
}

function escapeHtml(v) {
  return String(v ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}
