/* SNOF live farm dashboard.
 *
 * Reads the mirror the Home Assistant add-on writes and renders it as an app:
 * Overview -> Areas -> one area -> its devices. Sensors are read-only; lights,
 * switches and fans can be operated, which happens by appending a command to
 * /farms/<farm>/commands. The bridge on the NUC is the only thing that can act
 * on it — this page never talks to farm hardware directly, and RTDB rules let
 * a client write nothing else anywhere in the tree.
 */
'use strict';

const FARM = 'snof';
const STALE_FACTOR = 2.5;    // heartbeats missed before we call the bridge stale
const NATURAL = { numeric: true, sensitivity: 'base' };   // "Zone 2" before "Zone 10"
const CMD_TIMEOUT_MS = 12000;

/* Domains this page offers controls for. Deliberately excludes cover, lock and
 * alarm_control_panel: opening a gate or unlocking a door from a browser tab is
 * a different risk conversation, and the bridge refuses them regardless. */
const CONTROLLABLE = new Set(['switch', 'light', 'fan', 'input_boolean']);
const ON_STATES = new Set(['on', 'open', 'opening', 'home', 'playing', 'unlocked', 'detected']);
const OFF_STATES = new Set(['off', 'closed', 'closing', 'not_home', 'idle', 'standby', 'locked']);
const BAD_STATES = new Set(['unavailable', 'unknown']);

const el = (id) => document.getElementById(id);
const humanDomain = (d) => String(d).replace(/_/g, ' ');

let state = { meta: {}, areas: {}, entities: {} };
let canControl = false;
let currentUser = null;
let search = '';
let domainFilter = null;
let statusFilter = 'all';   // all | active | offline
let refs = [];
let clockSkewMs = 0;
let statusTimer = null;
let firstSnapshot = false;
const prevStates = new Map();
const pending = new Map();   // entity_id -> { want, timer } while a command is in flight
/* A farm this chatty re-renders roughly once a second. Replacing the view out
 * from under someone who is dragging a slider loses the drag, so live updates
 * are held while a control is in use and applied the moment it is let go. */
let interacting = false;
let viewDirty = false;

/* ================= theme ================= */

const applyTheme = (t) => {
  if (t) document.documentElement.setAttribute('data-theme', t);
  else document.documentElement.removeAttribute('data-theme');
  const dark = t ? t === 'dark'
    : !window.matchMedia('(prefers-color-scheme: light)').matches;
  document.querySelector('meta[name=theme-color]')?.setAttribute('content', dark ? '#111111' : '#f4f4f3');
};
applyTheme(localStorage.getItem('snof-theme'));

el('theme-btn').onclick = () => {
  const dark = !document.documentElement.matches('[data-theme=light]') &&
    (document.documentElement.matches('[data-theme=dark]') ||
     !window.matchMedia('(prefers-color-scheme: light)').matches);
  const next = dark ? 'light' : 'dark';
  localStorage.setItem('snof-theme', next);
  applyTheme(next);
};

/* ================= auth ================= */

const setView = (v) => { document.body.dataset.view = v; };

el('signin').onclick = () => {
  const provider = new firebase.auth.GoogleAuthProvider();
  provider.setCustomParameters({ prompt: 'select_account' });
  firebase.auth().signInWithPopup(provider).catch((err) => {
    el('gate-msg').textContent = err.message;
  });
};
const doSignOut = () => firebase.auth().signOut();
el('signout').onclick = doSignOut;
el('signout-menu').onclick = doSignOut;
el('signout-gate').onclick = doSignOut;

function detach() {
  refs.forEach(({ ref, ev, cb }) => ref.off(ev, cb));
  refs = [];
  if (statusTimer) { clearInterval(statusTimer); statusTimer = null; }
}

function leave() {
  detach();
  state = { meta: {}, areas: {}, entities: {} };
  canControl = false; currentUser = null; firstSnapshot = false;
  statusFilter = 'all'; domainFilter = null;
  interacting = false; viewDirty = false;
  prevStates.clear(); pending.clear();
  setView('gate');
  el('signin').hidden = false;
  el('signout-gate').hidden = true;
  el('gate-msg').textContent = 'Sign in with the Google account on the farm allowlist.';
}

function gateWith(html) {
  detach();
  setView('gate');
  el('signin').hidden = true;
  el('signout-gate').hidden = false;
  el('gate-msg').innerHTML = html;
}

function denied(user) {
  // Surfacing the address turns "access denied" into a one-command fix.
  const who = escapeHtml(user.email || 'This account');
  gateWith(`<strong>${who}</strong> is not on the dashboard allowlist.<br><br>` +
    `Ask the farm owner to run:<br><code>npm run grant -- ${escapeHtml(user.email || '')}</code>`);
}

function enter(user) {
  // Hosting injects databaseURL only once an RTDB instance exists. Without this
  // guard firebase.database() throws an opaque "Can't determine URL" error.
  if (!firebase.app().options.databaseURL) {
    gateWith('No Realtime Database yet.<br><br>Create the default instance in the ' +
             'Firebase console, then reload this page. No redeploy needed.');
    return;
  }

  currentUser = user;
  setView('app');
  const name = user.displayName || (user.email || '').split('@')[0] || 'Signed in';
  el('acct-name').textContent = name;
  el('acct-initial').textContent = (name[0] || '·');
  el('acct-email').textContent = user.email || '';

  const db = firebase.database();
  // Server time offset lets us judge heartbeat staleness without trusting the
  // viewer's clock, which on a wall tablet is often wrong.
  const skewRef = db.ref('.info/serverTimeOffset');
  const skewCb = skewRef.on('value', (s) => { clockSkewMs = s.val() || 0; });
  refs.push({ ref: skewRef, ev: 'value', cb: skewCb });

  // A viewer sees everything; a controller may also operate devices. Two tiers,
  // so handing someone the dashboard is not the same as handing them the pumps.
  const ctlRef = db.ref(`acl/controllers/${user.uid}`);
  const ctlCb = ctlRef.on('value',
    (s) => { canControl = s.val() === true; setRole(); render(); },
    () => { canControl = false; setRole(); });
  refs.push({ ref: ctlRef, ev: 'value', cb: ctlCb });

  const watch = (path, key) => {
    const ref = db.ref(`farms/${FARM}/${path}`);
    const cb = ref.on('value',
      (snap) => { state[key] = snap.val() || {}; if (key === 'entities') firstSnapshot = true; render(); },
      (err) => { if (err.code === 'PERMISSION_DENIED') denied(user); else console.error(err); });
    refs.push({ ref, ev: 'value', cb });
  };
  watch('meta', 'meta');
  watch('areas', 'areas');
  watch('entities', 'entities');

  statusTimer = setInterval(renderBridgeStatus, 5000);
  render();
}

const setRole = () => { el('acct-role').textContent = canControl ? 'Controller' : 'Viewer'; };

/* ================= data helpers ================= */

function flatEntities() {
  const out = [];
  for (const [domain, objs] of Object.entries(state.entities || {})) {
    for (const [objectId, node] of Object.entries(objs || {})) {
      if (node && typeof node === 'object') {
        out.push({ ...node, domain, objectId, key: `${domain}.${objectId}`, area: node.area || 'unassigned' });
      }
    }
  }
  return out;
}

const areaName = (id) => (id === 'unassigned' ? 'Unassigned' : state.areas?.[id]?.name || id);
const isOn = (e) => ON_STATES.has(e.state);
const isBad = (e) => e.state == null || e.state === '' || BAD_STATES.has(e.state);

function matches(ent) {
  if (!search) return true;
  return `${ent.name} ${ent.entity_id} ${ent.state} ${areaName(ent.area)}`.toLowerCase().includes(search);
}

function groupByArea(ents) {
  const map = new Map();
  for (const e of ents) {
    if (!map.has(e.area)) map.set(e.area, []);
    map.get(e.area).push(e);
  }
  return [...map.entries()].sort((a, b) => {
    if (a[0] === 'unassigned') return 1;
    if (b[0] === 'unassigned') return -1;
    return areaName(a[0]).localeCompare(areaName(b[0]), undefined, NATURAL);
  });
}

const byName = (a, b) => (a.name || a.key).localeCompare(b.name || b.key, undefined, NATURAL);

/* ================= commands ================= */

/* One write, one path, one shape. RTDB rules reject anything else, and the
 * bridge additionally refuses domains outside its own allow-list — so a bug
 * here cannot become a bug at the relay. */
function sendCommand(ent, service, data = {}) {
  if (!canControl) { toast('err', 'Your account can view, but not control.'); return; }
  const [domain] = ent.key.split('.');
  const ref = firebase.database().ref(`farms/${FARM}/commands`).push();
  return ref.set({
    entity_id: ent.entity_id || ent.key,
    domain,
    service,
    data,
    uid: currentUser.uid,
    at: firebase.database.ServerValue.TIMESTAMP,
  }).catch((err) => {
    clearPending(ent.key);
    toast('err', err.code === 'PERMISSION_DENIED'
      ? 'The database refused that command.'
      : `Could not send: ${err.message}`);
    render();
  });
}

/* Optimistic UI with a deadline. The control snaps to the requested position
 * immediately, and if the farm has not confirmed within CMD_TIMEOUT_MS we put
 * it back and say so, rather than leaving a toggle lying about the world. */
function markPending(key, want) {
  clearPending(key);
  pending.set(key, {
    want,
    timer: setTimeout(() => {
      pending.delete(key);
      toast('err', 'No response from the farm — the control was reset.');
      render();
    }, CMD_TIMEOUT_MS),
  });
}
function clearPending(key) {
  const p = pending.get(key);
  if (p) { clearTimeout(p.timer); pending.delete(key); }
}

function onToggle(ent) {
  const want = !isOn(ent);
  markPending(ent.key, want ? 'on' : 'off');
  render();
  sendCommand(ent, want ? 'turn_on' : 'turn_off');
}

function onLevel(ent, pct) {
  const [domain] = ent.key.split('.');
  if (domain === 'fan') sendCommand(ent, 'set_percentage', { percentage: pct });
  // HA takes 0-255 for brightness; the slider speaks percent.
  else sendCommand(ent, 'turn_on', { brightness: Math.round((pct / 100) * 255) });
}

/* ================= toasts ================= */

function toast(kind, message) {
  const node = document.createElement('div');
  node.className = `toast ${kind}`;
  node.innerHTML = `<svg class="ico"><use href="#i-${kind === 'ok' ? 'check' : 'alert'}"/></svg>` +
                   `<span>${escapeHtml(message)}</span>`;
  el('toasts').appendChild(node);
  setTimeout(() => {
    node.classList.add('out');
    node.addEventListener('animationend', () => node.remove(), { once: true });
  }, 4200);
}

/* ================= router ================= */

const route = () => {
  const h = (location.hash || '#/').slice(1);
  const [, head, arg] = h.match(/^\/([^/]*)\/?(.*)$/) || [, '', ''];
  return { name: head || 'overview', arg: decodeURIComponent(arg || '') };
};
window.addEventListener('hashchange', () => { render(); el('view').focus(); closeNav(); });

/* ================= chrome ================= */

el('search').oninput = (e) => { search = e.target.value.trim().toLowerCase(); render(); };

const openNav = () => { document.body.classList.add('nav-open'); el('scrim').hidden = false; };
const closeNav = () => { document.body.classList.remove('nav-open'); el('scrim').hidden = true; };
el('nav-open').onclick = openNav;
el('nav-close').onclick = closeNav;
el('scrim').onclick = closeNav;

el('acct-btn').onclick = (e) => {
  e.stopPropagation();
  const open = el('acct-menu').hidden;
  el('acct-menu').hidden = !open;
  el('acct-btn').setAttribute('aria-expanded', String(open));
};
document.addEventListener('click', () => {
  if (!el('acct-menu').hidden) {
    el('acct-menu').hidden = true;
    el('acct-btn').setAttribute('aria-expanded', 'false');
  }
});
document.addEventListener('keydown', (e) => {
  if (e.key !== 'Escape') return;
  closeNav();
  el('acct-menu').hidden = true;
  el('acct-btn').setAttribute('aria-expanded', 'false');
});

/* ================= render ================= */

/** Identify the focused control well enough to find it again after a rebuild,
 *  so a keyboard user is not dropped back to <body> by a sensor update. */
function focusToken() {
  const a = document.activeElement;
  if (!a || !el('view').contains(a)) return null;
  if (a.dataset.domain) return { domain: a.dataset.domain };
  const owner = a.closest('[data-key]');
  if (owner && a.dataset.act) return { key: owner.dataset.key, act: a.dataset.act };
  return null;
}

function restoreFocus(token) {
  if (!token) return;
  const sel = token.domain
    ? `.chip[data-domain="${CSS.escape(token.domain)}"]`
    : `[data-key="${CSS.escape(token.key)}"] [data-act="${CSS.escape(token.act)}"]`;
  el('view').querySelector(sel)?.focus();
}

const beginInteract = () => { interacting = true; };
const endInteract = () => {
  interacting = false;
  if (viewDirty) { viewDirty = false; render(); }
};

function render() {
  if (document.body.dataset.view !== 'app') return;
  const all = flatEntities();
  const r = route();

  const farmName = state.meta?.name || 'SNOF';
  document.title = `${farmName} · Live`;
  document.querySelector('.side-brand-sub').textContent =
    farmName.replace(/^Sibhi\s*/i, '').replace(/\s*and Farms$/i, '') || 'Live farm state';

  const areas = groupByArea(all);
  el('nav-areas-n').textContent = areas.length || '';
  el('nav-devices-n').textContent = all.length || '';
  document.querySelectorAll('.nav-item[data-nav]').forEach((n) =>
    n.classList.toggle('on', n.dataset.nav === (r.name === 'area' ? 'areas' : r.name)));

  renderBridgeStatus();
  reconcilePending(all);

  // Chrome above stays live regardless; only the view body is held back.
  if (interacting) {
    viewDirty = true;
  } else {
    const view = el('view');
    const token = focusToken();
    if (!firstSnapshot) view.innerHTML = skeletonView();
    else if (r.name === 'areas') view.innerHTML = areasView(all);
    else if (r.name === 'area') view.innerHTML = areaView(all, r.arg);
    else if (r.name === 'devices') view.innerHTML = devicesView(all);
    else view.innerHTML = overviewView(all, areas);
    wire(all);
    restoreFocus(token);
  }

  el('stats').textContent = all.length
    ? `${all.length} entities · ${areas.length} areas · updated ${new Date().toLocaleTimeString()}`
    : 'Waiting for the bridge to publish its first snapshot…';

  flashChanged(all);
}

/* ---- views ---- */

const head = (title, sub, right = '') =>
  `<div class="page-head"><div><h1 class="page-title">${escapeHtml(title)}</h1>` +
  `<p class="page-sub">${escapeHtml(sub)}</p></div><div class="spacer"></div>${right}</div>`;

const sectionHead = (symbol, title) =>
  `<div class="section-head"><svg class="ico"><use href="#${symbol}"/></svg>` +
  `<span class="section-title">${escapeHtml(title)}</span><span class="section-rule"></span></div>`;

function skeletonView() {
  return head('Overview', 'Connecting to the farm…') +
    `<div class="sk-grid">${'<div class="sk-card"></div>'.repeat(8)}</div>`;
}

function statTiles(ents) {
  const on = ents.filter(isOn).length;
  const bad = ents.filter(isBad).length;
  const areas = new Set(ents.map((e) => e.area)).size;
  // "698 live entities" is a lie when 373 of them are not reporting. Lead with
  // how many are actually answering, and keep the total as context.
  return `<div class="stats">
    <div class="stat"><span class="stat-label">Reporting</span>
      <span class="stat-value">${ents.length - bad}</span>
      <span class="stat-note">of ${ents.length} mirrored entities</span></div>
    <div class="stat"><span class="stat-label">Areas</span>
      <span class="stat-value">${areas}</span><span class="stat-note">rooms and zones</span></div>
    <div class="stat stat-on"><span class="stat-label">Active now</span>
      <span class="stat-value">${on}</span><span class="stat-note">on, open or running</span></div>
    <div class="stat stat-bad${bad ? '' : ' is-clear'}"><span class="stat-label">Needs a look</span>
      <span class="stat-value">${bad}</span><span class="stat-note">${bad ? 'unavailable or unknown' : 'everything reporting'}</span></div>
  </div>`;
}

function overviewView(all, areas) {
  // An unavailable device in a *control* panel is a dead switch. They belong in
  // the breakdown below, never here.
  const operable = all.filter((e) => CONTROLLABLE.has(e.domain) && !isBad(e)).sort(byName);
  const quick = operable.filter(isOn).concat(operable.filter((e) => !isOn(e))).slice(0, 8);
  const offline = all.filter(isBad);
  const controllableTotal = all.filter((e) => CONTROLLABLE.has(e.domain)).length;

  const areaCards = areas.slice(0, 8).map(([id, list]) => areaCard(id, list)).join('');
  const more = operable.length - quick.length;

  return head(state.meta?.name || 'SNOF', 'Everything the farm is doing, right now.') +
    statTiles(all) +
    sectionHead('i-switch', canControl ? 'Quick controls' : 'Controllable devices') +
    (quick.length
      ? `<div class="dev-grid">${quick.map(deviceCard).join('')}</div>` +
        (more > 0 ? `<p class="more-note">${more} more operable ${more === 1 ? 'device' : 'devices'} — ` +
          `<a href="#/devices" data-act="filter" data-status="active">see all</a></p>` : '')
      : emptyBlock('Nothing to operate right now',
          controllableTotal
            ? `All ${controllableTotal} switches, lights and fans are currently unavailable.`
            : 'No switches, lights or fans are exposed by Home Assistant yet.')) +
    (offline.length ? sectionHead('i-alert', 'Not reporting') + offlineBreakdown(offline) : '') +
    sectionHead('n-areas', 'Areas') +
    (areaCards ? `<div class="grid">${areaCards}</div>`
               : emptyBlock('No areas yet', 'Assign entities to an area in Home Assistant and they will group themselves here.'));
}

/** 373 unavailable entities listed alphabetically is noise. Grouped by domain it
 *  is a to-do list: which integration died, and how much of it. */
function offlineBreakdown(offline) {
  const tally = new Map();
  for (const e of offline) tally.set(e.domain, (tally.get(e.domain) || 0) + 1);
  const rows = [...tally.entries()].sort((a, b) => b[1] - a[1]).slice(0, 8);
  const total = offline.length;
  return `<p class="more-note">${total} ${total === 1 ? 'entity is' : 'entities are'} ` +
    `unavailable or unknown. Most likely a handful of integrations, not ${total} separate faults.</p>` +
    `<div class="breakdown">` + rows.map(([domain, n]) => `
      <button class="brk" data-act="filter" data-status="offline" data-domain="${escapeHtml(domain)}">
        <span class="brk-icon"><svg class="ico ico-sm"><use href="#i-${iconName(domain)}"/></svg></span>
        <span class="brk-text">
          <span class="brk-name">${escapeHtml(humanDomain(domain))}</span>
          <span class="brk-sub">not reporting</span>
        </span>
        <span class="brk-n">${n}</span>
      </button>`).join('') + `</div>`;
}

function areasView(all) {
  const areas = groupByArea(all.filter(matches));
  if (!areas.length) return head('Areas', 'Nothing matches that search.') + noMatch();
  return head('Areas', `${areas.length} areas · ${all.length} entities`) +
    `<div class="grid">${areas.map(([id, list]) => areaCard(id, list)).join('')}</div>`;
}

function areaCard(id, list) {
  const on = list.filter(isOn).length;
  const bad = list.filter(isBad).length;
  return `<a class="area-card" href="#/area/${encodeURIComponent(id)}">
    <div class="area-top">
      <span class="area-icon"><svg class="ico"><use href="#i-${iconForArea(list)}"/></svg></span>
      <svg class="ico ico-chevron"><use href="#i-chevron"/></svg>
    </div>
    <div>
      <div class="area-name">${escapeHtml(areaName(id))}</div>
      <div class="area-meta">
        <span class="area-count">${list.length} ${list.length === 1 ? 'device' : 'devices'}</span>
        ${on ? `<span class="tag tag-on">${on} active</span>` : ''}
        ${bad ? `<span class="tag tag-bad">${bad} offline</span>` : ''}
      </div>
    </div>
  </a>`;
}

function areaView(all, id) {
  const inArea = all.filter((e) => e.area === id);
  const list = inArea.filter(matches);
  const back = `<a class="back" href="#/areas"><svg class="ico ico-sm"><use href="#i-back"/></svg>All areas</a>`;
  if (!list.length) {
    // An area that is empty and an area whose contents the search hid are
    // different problems, and only one of them is the user's to fix.
    return inArea.length
      ? head(areaName(id), 'Nothing here matches that search.', back) + noMatch()
      : head(areaName(id), 'No devices here yet.', back) +
        emptyBlock('This area is empty',
                   'Nothing in Home Assistant is assigned to this area yet.');
  }
  const on = list.filter(isOn).length;
  const byDomain = new Map();
  for (const e of list) {
    if (!byDomain.has(e.domain)) byDomain.set(e.domain, []);
    byDomain.get(e.domain).push(e);
  }
  // Operable domains first: the reason to open a room is usually to do something.
  const order = [...byDomain.keys()].sort((a, b) => {
    const ca = CONTROLLABLE.has(a) ? 0 : 1, cb = CONTROLLABLE.has(b) ? 0 : 1;
    return ca - cb || a.localeCompare(b);
  });

  return head(areaName(id), `${list.length} devices · ${on} active`, back) +
    order.map((d) => {
      const items = byDomain.get(d).sort(byName);
      return sectionHead(`i-${iconName(d)}`, humanDomain(d)) + (CONTROLLABLE.has(d)
        ? `<div class="dev-grid">${items.map(deviceCard).join('')}</div>`
        : `<div class="list${items.length > 8 ? ' cols' : ''}">${items.map(row).join('')}</div>`);
    }).join('');
}

function devicesView(all) {
  const byStatus = (e) => statusFilter === 'all' ? true
    : statusFilter === 'active' ? !isBad(e) : isBad(e);
  const scoped = all.filter(byStatus);
  const domains = [...new Set(scoped.map((e) => e.domain))].sort();
  const list = scoped.filter((e) => matches(e) && (!domainFilter || e.domain === domainFilter)).sort(byName);

  const counts = { all: all.length, active: all.filter((e) => !isBad(e)).length,
                   offline: all.filter(isBad).length };
  const seg = `<div class="seg" role="group" aria-label="Filter by status">` +
    [['all', 'All'], ['active', 'Reporting'], ['offline', 'Not reporting']].map(([k, label]) =>
      `<button data-act="status" data-status="${k}" aria-pressed="${statusFilter === k}">` +
      `${label} <span class="n">${counts[k]}</span></button>`).join('') + `</div>`;

  const chips = domains.length > 1 ? `<div class="chips">` + domains.map((d) => {
    const n = scoped.filter((e) => e.domain === d).length;
    return `<button class="chip${domainFilter === d ? ' on' : ''}" aria-pressed="${domainFilter === d}" ` +
      `data-domain="${escapeHtml(d)}">${escapeHtml(humanDomain(d))}<span class="n">${n}</span></button>`;
  }).join('') + `</div>` : '';

  return head('All devices', `${list.length} shown of ${all.length} entities`) +
    `<div class="toolbar-row">${seg}</div>` + chips +
    (list.length ? `<div class="list${list.length > 8 ? ' cols' : ''}">${list.map((e) => row(e, true)).join('')}</div>`
                 : noMatch());
}

/* ---- pieces ---- */

function deviceCard(ent) {
  const want = pending.get(ent.key)?.want;
  const on = want ? want === 'on' : isOn(ent);
  const bad = isBad(ent);
  const level = levelOf(ent);
  const cls = bad ? 'is-bad' : on ? 'is-on' : '';
  const canOperate = canControl && !bad;

  return `<div class="dev-card ${cls}" data-key="${escapeHtml(ent.key)}">
    <div class="dev-top">
      <span class="dev-icon"><svg class="ico"><use href="#i-${iconFor(ent)}"/></svg></span>
      <span class="dev-text">
        <span class="dev-name" title="${escapeHtml(ent.name || ent.entity_id)}">${escapeHtml(ent.name || ent.entity_id)}</span>
        <span class="dev-meta">${escapeHtml(humanDomain(ent.domain))}${subtitle(ent)}</span>
      </span>
      ${canControl
        ? `<button class="toggle${want ? ' busy' : ''}" role="switch" aria-checked="${on}" ` +
          `aria-label="${escapeHtml(ent.name || ent.entity_id)}" data-act="toggle"${canOperate ? '' : ' disabled'}></button>`
        : `<span class="dev-state ${stateClass(ent)}">${escapeHtml(formatState(ent))}</span>`}
    </div>
    ${level !== null && canControl ? `<div class="ctl-row">
      <span class="ctl-label">${ent.domain === 'fan' ? 'Speed' : 'Bright'}</span>
      <input type="range" min="0" max="100" step="1" value="${level}" style="--fill:${level}%"
             aria-label="${escapeHtml(ent.name || '')} level" data-act="level"${canOperate ? '' : ' disabled'}>
      <span class="ctl-val">${level}%</span>
    </div>` : ''}
    <div class="dev-foot">
      <span>${escapeHtml(areaName(ent.area))}</span>
      ${canControl ? `<span>${escapeHtml(formatState(ent))}</span>` : ''}
    </div>
  </div>`;
}

function row(ent, withArea = false) {
  return `<div class="row ${isBad(ent) ? 'is-bad' : isOn(ent) ? 'is-on' : ''}" data-key="${escapeHtml(ent.key)}">
    <span class="row-icon"><svg class="ico ico-sm"><use href="#i-${iconFor(ent)}"/></svg></span>
    <span class="row-main">
      <span class="row-name" title="${escapeHtml(ent.name || ent.entity_id)}">${escapeHtml(ent.name || ent.entity_id)}</span>
      <span class="row-meta">${escapeHtml(withArea ? areaName(ent.area) : humanDomain(ent.domain))}${subtitle(ent)}</span>
    </span>
    <span class="dev-state ${stateClass(ent)}">${escapeHtml(formatState(ent))}</span>
  </div>`;
}

const emptyBlock = (title, body) => `<div class="empty">
  <span class="empty-mark"><svg class="ico"><use href="#i-search"/></svg></span>
  <h3>${escapeHtml(title)}</h3><p>${escapeHtml(body)}</p></div>`;

const noMatch = () => emptyBlock('Nothing matches', 'Try a different search term, or clear the filter.');

/* ---- event wiring (delegated once per render) ---- */

function wire(all) {
  const index = new Map(all.map((e) => [e.key, e]));
  const view = el('view');

  view.querySelectorAll('[data-act="toggle"]').forEach((btn) => {
    btn.onclick = () => {
      const ent = index.get(btn.closest('[data-key]').dataset.key);
      if (ent) onToggle(ent);
    };
  });

  view.querySelectorAll('[data-act="level"]').forEach((input) => {
    input.onpointerdown = beginInteract;
    input.onkeydown = beginInteract;
    input.oninput = () => {
      input.style.setProperty('--fill', `${input.value}%`);
      input.parentElement.querySelector('.ctl-val').textContent = `${input.value}%`;
    };
    input.onchange = () => {
      const ent = index.get(input.closest('[data-key]').dataset.key);
      if (ent) onLevel(ent, Number(input.value));
    };
    // Whichever of these ends the gesture, the held update lands right after.
    input.onpointerup = endInteract;
    input.onpointercancel = endInteract;
    input.onkeyup = endInteract;
    input.onblur = endInteract;
  });

  view.querySelectorAll('[data-act="status"]').forEach((btn) => {
    btn.onclick = () => { statusFilter = btn.dataset.status; domainFilter = null; render(); };
  });

  // A breakdown row is a query: show me exactly these, on the devices page.
  view.querySelectorAll('[data-act="filter"]').forEach((node) => {
    node.onclick = (e) => {
      e.preventDefault();
      statusFilter = node.dataset.status || 'all';
      domainFilter = node.dataset.domain || null;
      location.hash = '#/devices';
      render();
    };
  });

  view.querySelectorAll('.chip[data-domain]').forEach((chip) => {
    chip.onclick = () => {
      domainFilter = domainFilter === chip.dataset.domain ? null : chip.dataset.domain;
      render();
    };
  });
}

/* ---- formatting ---- */

function iconName(domain) {
  return document.getElementById(`i-${domain}`) ? domain : 'default';
}
function iconFor(ent) {
  return ent ? iconName(ent.domain) : 'default';
}

/** The icon for a room is its most common domain — a shed full of sensors
 *  should not be labelled by the one light that happened to sort first. */
function iconForArea(list) {
  const tally = new Map();
  for (const e of list) tally.set(e.domain, (tally.get(e.domain) || 0) + 1);
  let best = null, bestN = -1;
  for (const [domain, n] of tally) {
    // Ties go to a controllable domain: it is the more useful thing to show.
    const score = n * 2 + (CONTROLLABLE.has(domain) ? 1 : 0);
    if (score > bestN) { bestN = score; best = domain; }
  }
  return best ? iconName(best) : 'default';
}

function subtitle(ent) {
  const a = ent.attrs || {};
  const bits = [];
  if (a.device_class) bits.push(a.device_class);
  if (a.battery_level != null) bits.push(`${a.battery_level}% battery`);
  return bits.length ? ' · ' + bits.join(', ') : '';
}

/** Slider position in percent, or null when the entity has no level to set. */
function levelOf(ent) {
  const a = ent.attrs || {};
  if (ent.domain === 'fan') return a.percentage != null ? Math.round(a.percentage) : null;
  if (ent.domain === 'light') return a.brightness != null ? Math.round((a.brightness / 255) * 100) : null;
  return null;
}

function formatState(ent) {
  const s = ent.state;
  if (s == null || s === '') return '—';
  const unit = ent.attrs?.unit_of_measurement;
  if (unit === '%') return `${s}%`;              // "34.2%", but "31.4 °C"
  if (unit) return `${s} ${unit}`;
  if (s === 'on' || s === 'off') return s.toUpperCase();
  return String(s);
}

function stateClass(ent) {
  if (isBad(ent)) return 'unavail';
  if (isOn(ent)) return 'on';
  if (OFF_STATES.has(ent.state)) return 'off';
  return '';
}

function renderBridgeStatus() {
  const pill = el('bridge-pill'), text = el('bridge-text');
  const hb = state.meta?.bridge;
  pill.className = 'pill pill-unknown';

  if (!hb || !hb.lastSeen) { text.textContent = 'no bridge data'; return; }
  if (hb.status === 'offline') { pill.className = 'pill pill-offline'; text.textContent = 'bridge offline'; return; }

  const ageSec = (Date.now() + clockSkewMs - hb.lastSeen) / 1000;
  if (ageSec > (hb.heartbeatSeconds || 30) * STALE_FACTOR) {
    pill.className = 'pill pill-stale';
    text.textContent = `stale ${humanAge(ageSec)}`;
  } else {
    pill.className = 'pill pill-online';
    text.textContent = 'live';
  }
}

/** Settle any in-flight command the farm has now agreed with. Runs before the
 *  view is drawn, so a confirmed control is never painted as still busy.
 *  Checked every render rather than only on a transition: if the entity already
 *  reports what we asked for, waiting for an edge that will never arrive would
 *  time out and blame the farm for our own bookkeeping. */
function reconcilePending(ents) {
  for (const ent of ents) {
    const want = pending.get(ent.key)?.want;
    if (want && ((want === 'on') === isOn(ent))) clearPending(ent.key);
  }
}

function flashChanged(ents) {
  for (const ent of ents) {
    const before = prevStates.get(ent.key);
    if (before !== undefined && before !== ent.state) {
      const node = document.querySelector(`[data-key="${CSS.escape(ent.key)}"]`);
      if (node) { node.classList.remove('flash'); void node.offsetWidth; node.classList.add('flash'); }
    }
    prevStates.set(ent.key, ent.state);
  }
}

/* ---- utils ---- */

function humanAge(sec) {
  if (sec < 90) return `${Math.round(sec)}s`;
  if (sec < 5400) return `${Math.round(sec / 60)}m`;
  return `${Math.round(sec / 3600)}h`;
}

function escapeHtml(v) {
  return String(v ?? '').replace(/[&<>"']/g, (c) =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

/* ================= start ================= */

/* Registered last, deliberately. onAuthStateChanged can fire synchronously, and
 * enter()/leave() touch handlers and helpers defined throughout this file — so
 * everything above has to exist before auth is allowed to resolve. */
firebase.auth().onAuthStateChanged((user) => { if (user) enter(user); else leave(); });
