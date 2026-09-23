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

let state = { meta: {}, areas: {}, entities: {}, irrigation: {}, irrigation_reports: {}, acl: {} };
let canControl = false;
let isAdmin = false;
let aclRef = null;
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
  irrWaiters.forEach(({ ref, cb, timer }) => { clearTimeout(timer); ref.off('value', cb); });
  irrWaiters.clear();
  state = { meta: {}, areas: {}, entities: {}, irrigation: {}, acl: {} };
  canControl = false; isAdmin = false; aclRef = null; currentUser = null; firstSnapshot = false;
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
  // Surfacing the address turns "access denied" into a one-step fix: an
  // admin adds it from the dashboard's Admin page, no terminal involved.
  const who = escapeHtml(user.email || 'This account');
  gateWith(`<strong>${who}</strong> is not on the dashboard allowlist.<br><br>` +
    `Ask a farm admin to add you from the dashboard's Admin page.`);
}

// RTDB keys cannot contain '.', so an invite is keyed by the lowercased
// email with '.' swapped for ',' - database.rules.json does the same swap
// (via auth.token.email) to let the invited person read and claim only
// their own invite before they have a uid to match on.
const emailToInviteKey = (email) => (email || '').trim().toLowerCase().replace(/\./g, ',');
const inviteKeyToEmail = (key) => (key || '').replace(/,/g, '.');

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

  // Self-registered so an admin can resolve this uid to an email from the
  // dashboard, without the Admin SDK. Fire-and-forget: it costs nothing to
  // skip on a flaky connection, and runs again next sign-in.
  db.ref(`acl/directory/${user.uid}`).set({
    email: user.email || '',
    name: user.displayName || '',
    at: firebase.database.ServerValue.TIMESTAMP,
  }).catch(() => {});

  // If an admin pre-authorized this email (acl/invites), claim it now: set
  // view (and control, if invited for that) on this uid, then remove the
  // invite so it cannot be claimed twice. Rules enforce the same shape from
  // the server side; this just means a first-time sign-in does not need a
  // reload to pick up access that was granted a moment before it.
  const inviteKey = emailToInviteKey(user.email);
  if (inviteKey) {
    db.ref(`acl/invites/${inviteKey}`).get().then((snap) => {
      const invite = snap.val();
      if (!invite) return;
      const viewRef = db.ref(`acl/viewers/${user.uid}`);
      const ctlRef = db.ref(`acl/controllers/${user.uid}`);
      const claim = invite.tier === 'control'
        ? viewRef.set(true).then(() => ctlRef.set(true))
        : viewRef.set(true);
      return claim.then(() => db.ref(`acl/invites/${inviteKey}`).remove());
    }).catch(() => {});
  }

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

  // A third tier on top of controllers: an admin may grant or revoke the
  // other two for anyone else, from the dashboard's Admin page. Only the
  // service account can hand this one out (tools/grant-access.js --admin).
  // Once true, it also unlocks a read of the whole acl subtree (RTDB rules
  // cascade that from admins == true), which the Admin page needs to list
  // everyone in one shot rather than probing uid by uid.
  const adminRef = db.ref(`acl/admins/${user.uid}`);
  const adminCb = adminRef.on('value',
    (s) => {
      isAdmin = s.val() === true;
      setRole();
      if (isAdmin && !aclRef) {
        aclRef = db.ref('acl');
        const aclCb = aclRef.on('value',
          (snap) => { state.acl = snap.val() || {}; render(); },
          () => { state.acl = {}; render(); });
        refs.push({ ref: aclRef, ev: 'value', cb: aclCb });
      }
      render();
    },
    () => { isAdmin = false; setRole(); });
  refs.push({ ref: adminRef, ev: 'value', cb: adminCb });

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
  // The irrigation cache is whatever the last report left behind; the
  // reports list is the last 20 results, newest last from RTDB.
  watch('irrigation', 'irrigation');
  {
    const repRef = db.ref(`farms/${FARM}/irrigation_reports`).limitToLast(20);
    const repCb = repRef.on('value',
      (snap) => { state.irrigation_reports = snap.val() || {}; render(); },
      (err) => { if (err.code === 'PERMISSION_DENIED') denied(user); else console.error(err); });
    refs.push({ ref: repRef, ev: 'value', cb: repCb });
  }

  statusTimer = setInterval(renderBridgeStatus, 5000);
  render();
}

const setRole = () => {
  el('acct-role').textContent = isAdmin ? 'Admin' : canControl ? 'Controller' : 'Viewer';
};

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
  node.innerHTML = `<svg viewBox="0 0 24 24" class="ico"><use href="#i-${kind === 'ok' ? 'check' : 'alert'}"/></svg>` +
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
  el('nav-irrig-n').textContent = irrigRunning() || '';
  document.querySelectorAll('.nav-admin').forEach((n) => { n.hidden = !isAdmin; });
  document.querySelectorAll('[data-nav]').forEach((n) =>
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
    else if (r.name === 'irrigation') view.innerHTML = irrigationView();
    else if (r.name === 'admin') view.innerHTML = isAdmin ? adminView()
      : head('Admin', 'Grant or revoke dashboard access.') +
        emptyBlock('Admins only', 'Your account does not have admin access.');
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

const sectionHead = (symbol, title, link = null) =>
  `<div class="section-head"><svg viewBox="0 0 24 24" class="ico"><use href="#${symbol}"/></svg>` +
  `<span class="section-title">${escapeHtml(title)}</span><span class="section-rule"></span>` +
  (link ? `<a class="section-link" href="${link[0]}">See all <svg viewBox="0 0 24 24" class="ico ico-sm"><use href="#i-chevron"/></svg></a>` : '') + `</div>`;

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
    sectionHead('i-switch', canControl ? 'Quick controls' : 'Controllable devices', ['#/devices']) +
    (quick.length
      ? `<div class="dev-grid">${quick.map(deviceCard).join('')}</div>` +
        (more > 0 ? `<p class="more-note">${more} more operable ${more === 1 ? 'device' : 'devices'} — ` +
          `<a href="#/devices" data-act="filter" data-status="active">see all</a></p>` : '')
      : emptyBlock('Nothing to operate right now',
          controllableTotal
            ? `All ${controllableTotal} switches, lights and fans are currently unavailable.`
            : 'No switches, lights or fans are exposed by Home Assistant yet.')) +
    (offline.length ? sectionHead('i-alert', 'Not reporting', ['#/devices']) + offlineBreakdown(offline) : '') +
    sectionHead('n-areas', 'Areas', ['#/areas']) +
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
        <span class="brk-icon"><svg viewBox="0 0 24 24" class="ico ico-sm"><use href="#i-${iconName(domain)}"/></svg></span>
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
      <span class="area-icon"><svg viewBox="0 0 24 24" class="ico"><use href="#i-${iconForArea(list)}"/></svg></span>
      <svg viewBox="0 0 24 24" class="ico ico-chevron"><use href="#i-chevron"/></svg>
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
  const back = `<a class="back" href="#/areas"><svg viewBox="0 0 24 24" class="ico ico-sm"><use href="#i-back"/></svg>All areas</a>`;
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

/* ---- irrigation (vendor motor/valve mirror, read-only) ---- */

/* ---- irrigation reports (vendor motors/valves, on demand) ---- */

/* Nothing on this page is polled. Each report below answers a user pressing
 * Generate: the dashboard appends a request to
 * /farms/<farm>/irrigation_requests, the bridge on the NUC executes that
 * one vendor call with its stored credentials, and writes the sanitized
 * result to /farms/<farm>/irrigation_reports. This page renders requests
 * and results and nothing else: it never sees a vendor credential and
 * cannot operate a pump. Valve/pump control is deliberately not built —
 * that is a security decision of the same order as cover/lock, not a config
 * tweak, and would arrive through the /commands queue, never as a direct
 * vendor call from a browser tab. */
const IRR_TYPES = [
  // Combined pulls first: they answer a question that spans two vendor calls
  // (which motors are running, did pressure hold while the valves were open)
  // and are what most people want. The single-source pulls below stay for
  // asking one vendor exactly one thing — and for telling which one is down.
  { type: 'motors', label: 'Motors — river and wells', needs: 'live', group: 'Combined' },
  { type: 'conditions', label: 'Controller and field conditions', needs: 'live', group: 'Combined' },
  { type: 'live_readings', label: 'Power and pressure now', needs: 'live', group: 'Combined' },
  { type: 'session_log', label: 'Irrigation session log', needs: 'range', group: 'Combined' },
  { type: 'performance', label: 'Valve runtime against pressure', needs: 'range', group: 'Combined' },
  { type: 'river_status', label: 'River motor status', needs: 'live', group: 'Single source' },
  { type: 'well_status', label: 'Well motor status', needs: 'live', group: 'Single source' },
  { type: 'controller', label: 'Controller dashboard', needs: 'live', group: 'Single source' },
  { type: 'weather', label: 'Field weather', needs: 'live', group: 'Single source' },
  { type: 'electricity', label: 'Electricity snapshot', needs: 'live', group: 'Single source' },
  { type: 'pressure', label: 'Pressure snapshot', needs: 'live', group: 'Single source' },
  { type: 'valves', label: 'Valve runtime', needs: 'range', group: 'Single source' },
  { type: 'timer_log', label: 'Timer log', needs: 'range', group: 'Single source' },
  { type: 'motor_log', label: 'Motor log', needs: 'range', group: 'Single source' },
  { type: 'pressure_range', label: 'Pressure range', needs: 'range', group: 'Single source' },
];
const IRR_TIMEOUT_MS = 60000;
// Builder selections survive re-renders (a sensor update mid-form must not
// wipe the dates), and one waiter per outstanding request resolves it.
let irrType = 'motors', irrFrom = '', irrTo = '';
const irrWaiters = new Map();   // reqKey -> { ref, cb, timer }

const irrig = () => state.irrigation || {};
const irrReports = () => Object.entries(state.irrigation_reports || {})
  .filter(([, r]) => r && typeof r === 'object')
  .sort((a, b) => (a[1].at || 0) - (b[1].at || 0));

const irrNeedsRange = (t) => (IRR_TYPES.find((x) => x.type === t) || {}).needs === 'range';

function irrDefaultDates() {
  const today = new Date(), past = new Date(Date.now() - 2 * 864e5);
  const iso = (d) => d.toISOString().slice(0, 10);
  return { from: iso(past), to: iso(today) };
}

function sendReportRequest() {
  if (!canControl) { toast('err', 'Your account can view, but not run reports.'); return; }
  const range = irrNeedsRange(irrType);
  const from = irrFrom.trim(), to = irrTo.trim();
  if (range && (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to))) {
    toast('err', 'Pick a from and to date for this report.');
    return;
  }
  if (range && to < from) {
    toast('err', 'The to date is before the from date.');
    return;
  }
  const payload = {
    type: irrType,
    uid: currentUser.uid,
    at: firebase.database.ServerValue.TIMESTAMP,
  };
  if (range) { payload.from = from; payload.to = to; }
  const ref = firebase.database().ref(`farms/${FARM}/irrigation_requests`).push();
  const key = ref.key;
  const child = firebase.database().ref(`farms/${FARM}/irrigation_reports/${key}`);
  const done = (ok, msg) => {
    const w = irrWaiters.get(key);
    if (!w) return;
    clearTimeout(w.timer);
    child.off('value', w.cb);
    irrWaiters.delete(key);
    if (!ok) toast('err', msg);
    render();
  };
  const cb = (snap) => {
    const rep = snap.val();
    if (rep) {
      done(true);
      toast(rep.status === 'ok' ? 'ok' : 'err',
        rep.status === 'ok' ? 'Report ready.' : `Report failed: ${rep.error || 'vendor error'}`);
    }
  };
  const timer = setTimeout(() => done(false, 'No answer from the bridge yet — it will appear below when it lands.'), IRR_TIMEOUT_MS);
  irrWaiters.set(key, { ref: child, cb, timer });
  child.on('value', cb);
  ref.set(payload, (err) => {
    if (err) {
      done(false, err.code === 'PERMISSION_DENIED'
        ? 'The database refused that request.'
        : `Could not send: ${err.message}`);
    } else {
      toast('ok', 'Report requested — the bridge is pulling it now.');
      render();
    }
  });
}

/* ---- inline report charts ----
 * Inspired by the DCON app's power/pressure/fertigation-duration charts,
 * redrawn in this app's own near-monochrome system: one accent hue for a
 * magnitude series (never a new palette), the existing on/off green-vs-grey
 * for valve status. Hand-rolled inline SVG — no chart library, matching the
 * "no framework, no build step" constraint the rest of the dashboard keeps.
 * Both degrade to nothing rather than guessing when the shape doesn't fit,
 * the same way vendors.py degrades an unrecognised vendor field. */

const parseReading = (v) => { const n = parseFloat(v); return Number.isFinite(n) ? n : null; };

function sparkChart(rows, unit) {
  const pts = rows.map((r) => ({ at: r.at, v: parseReading(r.value) })).filter((p) => p.v != null);
  if (pts.length < 2) return '';
  const W = 100, H = 32, PAD = 3;
  const vals = pts.map((p) => p.v);
  const min = Math.min(...vals), max = Math.max(...vals);
  const span = max - min || 1;
  const x = (i) => PAD + (i / (pts.length - 1)) * (W - PAD * 2);
  const y = (v) => H - PAD - ((v - min) / span) * (H - PAD * 2);
  const line = pts.map((p, i) => `${i ? 'L' : 'M'}${x(i).toFixed(1)},${y(p.v).toFixed(1)}`).join(' ');
  const area = `M${x(0).toFixed(1)},${(H - PAD).toFixed(1)} ` +
    pts.map((p, i) => `L${x(i).toFixed(1)},${y(p.v).toFixed(1)}`).join(' ') +
    ` L${x(pts.length - 1).toFixed(1)},${(H - PAD).toFixed(1)} Z`;
  const fmt = (v) => `${v}${unit ? ' ' + unit : ''}`;
  // Native <title> tooltips: the hover layer a static SVG can offer for
  // free, without hand-rolling a crosshair for a card-sized widget.
  const dots = pts.map((p, i) =>
    `<circle cx="${x(i).toFixed(1)}" cy="${y(p.v).toFixed(1)}" r="1.6" class="spark-dot">` +
    `<title>${escapeHtml([p.at, fmt(p.v)].filter(Boolean).join(' · '))}</title></circle>`).join('');
  const last = pts[pts.length - 1];
  return `<div class="spark">
    <svg viewBox="0 0 ${W} ${H}" class="spark-svg" preserveAspectRatio="none" aria-hidden="true">
      <path d="${area}" class="spark-area"/>
      <path d="${line}" class="spark-line"/>
      ${dots}
    </svg>
    <div class="spark-labels">
      <span>${escapeHtml(fmt(min))} min</span>
      <span class="spark-last">${escapeHtml(fmt(last.v))} latest</span>
      <span>${escapeHtml(fmt(max))} max</span>
    </div>
  </div>`;
}

function parseRuntimeMinutes(v) {
  const s = String(v ?? '');
  const h = /(\d+)\s*h/i.exec(s), m = /(\d+)\s*m/i.exec(s);
  if (h || m) return (h ? parseInt(h[1], 10) * 60 : 0) + (m ? parseInt(m[1], 10) : 0);
  const n = parseFloat(s);
  return Number.isFinite(n) ? n : 0;
}
const fmtMinutes = (m) => m >= 60 ? `${Math.floor(m / 60)}h${m % 60 ? ` ${m % 60}m` : ''}` : `${m}m`;

function barChart(items) {
  const rows = items.filter((r) => r.minutes > 0);
  if (!rows.length) return '';
  const max = Math.max(...rows.map((r) => r.minutes));
  const bars = rows.map((r) => `<div class="bar-row">
    <span class="bar-label">${escapeHtml(r.name)}</span>
    <span class="bar-track"><span class="bar-fill${r.status === 'on' ? ' is-on' : ''}" ` +
      `style="width:${Math.max(4, Math.round((r.minutes / max) * 100))}%"></span></span>
    <span class="bar-value">${escapeHtml(fmtMinutes(r.minutes))}</span>
  </div>`).join('');
  return `<div class="bars">${bars}</div>`;
}

/* Pre-sections reports carry raw vendor runtime strings, so those still get
 * parsed here; a current report arrives with the minutes already worked out. */
function valveBars(rows) {
  return barChart(rows.map((r) => ({
    name: r.name || (r.id ? `Valve ${r.id}` : 'Valve'),
    minutes: parseRuntimeMinutes(r.runtime), status: r.status,
  })));
}

/* ---- report sections ----
 * A report arrives as a list of sections, each declaring the *kind* of thing
 * it is — metrics, status, series, bars, timeline, facts — and the bridge
 * decides that, not this file. The dashboard draws by kind and never sniffs
 * shapes: a vendor returning something unexpected loses one section rather
 * than producing a chart of nonsense, and a kind this build does not know is
 * skipped, so the bridge can add one without breaking an open tab.
 * Reports written before sections existed still carry `rows`; irrLegacyBody()
 * renders those the old way. */

const IRR_ROW_CAP = 8;

const moreNote = (total, shown, what) => total > shown
  ? `<p class="rep-note">${total - shown} more ${what} in this report.</p>` : '';

function irrMetrics(rows) {
  const tiles = rows
    .filter((r) => r && r.value !== undefined && r.value !== null && r.value !== '')
    .map((r) => `<div class="tile">
      <span class="tile-label">${escapeHtml(r.label || '')}</span>
      <span class="tile-value">${escapeHtml(String(r.value))}` +
        `${r.unit ? `<span class="tile-unit">${escapeHtml(r.unit)}</span>` : ''}</span>
      ${r.note ? `<span class="tile-note">${escapeHtml(r.note)}</span>` : ''}
    </div>`).join('');
  return tiles ? `<div class="tiles">${tiles}</div>` : '';
}

function irrStatusRows(rows) {
  const shown = rows.slice(0, IRR_ROW_CAP).map((r) => irrigRow(
    r.source === 'dcon' ? 'i-valve' : 'i-water_heater',
    r.name || 'Motor', r.meta || '', irrigStatusTag(r.status))).join('');
  return shown ? `<div class="list">${shown}</div>` +
    moreNote(rows.length, IRR_ROW_CAP, 'rows') : '';
}

function irrSeries(rows, sec) {
  const unit = sec.unit || (rows.find((r) => r && r.unit) || {}).unit || '';
  const chart = sparkChart(rows, unit);
  if (chart) return chart;
  // One reading is not a curve. Show it as a reading rather than a flat line.
  const shown = rows.slice(0, IRR_ROW_CAP).map((r) => irrigRow('i-menu',
    [r.value, r.unit].filter(Boolean).join(' ') || '—', r.at || '', '')).join('');
  return shown ? `<div class="list">${shown}</div>` : '';
}

function irrBars(rows) {
  // Runtime is already minutes here: the bridge parsed "1h 20m" once, so the
  // browser never has to guess at a vendor's spelling.
  return barChart(rows.map((r) => ({
    name: r.name || 'Valve',
    minutes: Number(r.value) || 0,
    status: r.status,
  })));
}

function irrFacts(rows) {
  const items = rows.filter((r) => r && r.value !== undefined && r.value !== '')
    .map((r) => `<div class="fact"><span class="fact-label">${escapeHtml(r.label || '')}</span>` +
      `<span class="fact-value">${escapeHtml(String(r.value))}</span></div>`).join('');
  return items ? `<div class="facts">${items}</div>` : '';
}

function irrTimeline(rows) {
  const shown = rows.slice(0, IRR_ROW_CAP);
  let day = '';
  const items = shown.map((r) => {
    const at = String(r.at || '');
    const stamp = /^\d{4}-\d{2}-\d{2}/.test(at)
      ? { day: at.slice(0, 10), time: at.slice(11, 16) } : { day: '', time: at };
    const head = stamp.day && stamp.day !== day
      ? `<div class="tl-day">${escapeHtml(stamp.day)}</div>` : '';
    if (stamp.day) day = stamp.day;
    const source = r.source
      ? `<span class="chip">${escapeHtml(r.source)}</span>` : '';
    return head + `<div class="tl-row">
      <span class="tl-at">${escapeHtml(stamp.time || '—')}</span>
      <span class="tl-main"><span class="row-name">${escapeHtml(r.detail || r.event || 'entry')}</span>
        ${r.detail && r.event ? `<span class="row-meta">${escapeHtml(r.event)}</span>` : ''}</span>
      ${source}
    </div>`;
  }).join('');
  return items ? `<div class="tl">${items}</div>` +
    moreNote(rows.length, IRR_ROW_CAP, 'entries') : '';
}

const IRR_SECTION_DRAW = {
  metrics: irrMetrics, status: irrStatusRows, series: irrSeries,
  bars: irrBars, timeline: irrTimeline, facts: irrFacts,
};

function irrSection(sec, withTitle) {
  const draw = IRR_SECTION_DRAW[sec && sec.kind];
  if (!draw) return '';
  const rows = Array.isArray(sec.rows) ? sec.rows : [];
  const head = withTitle && sec.title
    ? `<div class="sec-title">${escapeHtml(sec.title)}` +
      `${sec.source ? `<span class="sec-src">${escapeHtml(sec.source)}</span>` : ''}</div>`
    : '';
  if (sec.status === 'error') {
    return `<div class="rep-sec">${head}<p class="rep-note rep-err">` +
      `${escapeHtml(sec.error || 'this part of the report did not come back')}</p></div>`;
  }
  const body = draw(rows, sec);
  const note = sec.note ? `<p class="rep-note">${escapeHtml(sec.note)}</p>` : '';
  if (!body && !note) return '';
  return `<div class="rep-sec">${head}${body}${note}</div>`;
}

/* Reports written before sections existed: the old shape-sniffing render,
 * kept so history on the page stays readable. New reports never reach it. */
function irrLegacyBody(rep, label) {
  const rows = Array.isArray(rep.rows) ? rep.rows : [];
  const isReadings = rows.length >= 2 &&
    rows.every((r) => r && typeof r === 'object' && 'value' in r);
  const chart = rep.status !== 'ok' ? ''
    : rep.type === 'valves' ? valveBars(rows)
    : isReadings ? sparkChart(rows, rows[0] && rows[0].unit) : '';
  const shown = rows.slice(0, 6).map((r) => {
    const name = r.name || r.event || r.id || label;
    const meta = [r.status, r.detail, r.runtime,
      [r.value, r.unit].filter(Boolean).join(' '), r.at]
      .filter(Boolean).join(' · ');
    return irrigRow('i-menu', name, meta || label, '');
  }).join('');
  return chart + (shown ? `<div class="list">${shown}</div>` +
    moreNote(rows.length, 6, 'rows') : '');
}

function irrReportCard(key, rep) {
  const label = rep.label || rep.type || 'Report';
  const when = rep.at ? new Date(rep.at).toLocaleString() : '';
  const params = [rep.params && rep.params.from, rep.params && rep.params.to]
    .filter(Boolean).join(' → ');
  // Three outcomes, three tags: a report where one vendor answered and one
  // did not is not "Ready", and must not read as if it were.
  const statusTag = rep.status === 'ok' ? `<span class="tag tag-on">Ready</span>`
    : rep.status === 'partial' ? `<span class="tag tag-warn">Partly ready</span>`
    : rep.status === 'error' ? `<span class="tag tag-bad">Failed</span>`
    : `<span class="tag">Working…</span>`;
  const sections = Array.isArray(rep.sections) ? rep.sections : [];
  const withTitles = sections.filter((s) => IRR_SECTION_DRAW[s && s.kind]).length > 1;
  const body = sections.length
    ? sections.map((s) => irrSection(s, withTitles)).join('')
    : irrLegacyBody(rep, label);
  return `<div class="rep-card" data-rep="${escapeHtml(key)}">
    <div class="rep-head">
      <span class="rep-title">${escapeHtml(label)}</span>${statusTag}
      <span class="rep-when">${escapeHtml([params, when].filter(Boolean).join(' · '))}</span>
    </div>
    ${rep.summary ? `<p class="rep-summary">${escapeHtml(rep.summary)}</p>` : ''}
    ${rep.status === 'error' && rep.error ? `<p class="rep-summary rep-err">${escapeHtml(rep.error)}</p>` : ''}
    ${body}
  </div>`;
}

function irrigRunning() {
  const n = irrig();
  const running = [...(n.motors || []), ...(n.controllers || [])]
    .filter((m) => m && m.status === 'on').length;
  return running;
}

const irrigStatusTag = (s) =>
  s === 'on' ? `<span class="tag tag-on">Running</span>`
  : s === 'off' ? `<span class="tag">Off</span>`
  : `<span class="tag">Unknown</span>`;

function irrigMotorCard(m) {
  const icon = m.source === 'niagara' ? 'i-switch'
    : m.source === 'livesky' ? 'i-water_heater' : 'i-default';
  return `<div class="area-card">
    <div class="area-top">
      <span class="area-icon"><svg viewBox="0 0 24 24" class="ico"><use href="#${icon}"/></svg></span>
    </div>
    <div>
      <div class="area-name">${escapeHtml(m.name || 'Motor')}</div>
      <div class="area-meta">
        <span class="area-count">${escapeHtml(m.source === 'niagara' ? 'Well controller'
          : m.source === 'livesky' ? 'River motor' : 'Motor')}</span>
        ${irrigStatusTag(m.status)}
      </div>
      ${m.detail ? `<div class="area-count">${escapeHtml(m.detail)}</div>` : ''}
    </div>
  </div>`;
}

const irrigRow = (icon, name, meta, right) =>
  `<div class="row"><span class="row-icon"><svg viewBox="0 0 24 24" class="ico ico-sm"><use href="#${icon}"/></svg></span>` +
  `<span class="row-main"><span class="row-name">${escapeHtml(name)}</span>` +
  `<span class="row-meta">${escapeHtml(meta)}</span></span>${right}</div>`;

function irrigationView() {
  const def = irrDefaultDates();
  if (!irrFrom) irrFrom = def.from;
  if (!irrTo) irrTo = def.to;

  const groups = [...new Set(IRR_TYPES.map((t) => t.group))];
  const options = groups.map((g) =>
    `<optgroup label="${escapeHtml(g)}">` + IRR_TYPES.filter((t) => t.group === g).map((t) =>
      `<option value="${t.type}"${irrType === t.type ? ' selected' : ''}>${escapeHtml(t.label)}</option>`
    ).join('') + `</optgroup>`).join('');
  const showRange = irrNeedsRange(irrType);
  const pending = irrWaiters.size;
  const builder = canControl
    ? `<div class="rep-builder">
        <label class="rep-field"><span>Report</span>
          <select id="irr-type" data-act="irr-type">${options}</select></label>
        <label class="rep-field"${showRange ? '' : ' hidden'}><span>From</span>
          <input id="irr-from" type="date" value="${escapeHtml(irrFrom)}" data-act="irr-from" max="${escapeHtml(def.to)}"></label>
        <label class="rep-field"${showRange ? '' : ' hidden'}><span>To</span>
          <input id="irr-to" type="date" value="${escapeHtml(irrTo)}" data-act="irr-to" max="${escapeHtml(def.to)}"></label>
        <button class="btn btn-primary" data-act="irr-gen"${pending ? ' disabled' : ''}>` +
          `${pending ? 'Working…' : 'Generate report'}</button>
      </div>
      ${pending ? `<p class="more-note">Pulling from the vendor — the result lands below, usually within a minute.</p>` : ''}`
    : `<p class="more-note">Report generation is limited to controllers — ` +
      `your account can view results below, but not run new pulls.</p>`;

  const reports = irrReports();
  const repsSec = sectionHead('i-menu', 'Reports') +
    (reports.length
      ? reports.slice().reverse().map(([k, r]) => irrReportCard(k, r)).join('')
      : emptyBlock('No reports yet',
          canControl ? 'Build one above — pick a report and press Generate.'
                     : 'No reports have been run yet.'));

  const n = irrig();
  const motors = [...(n.motors || []), ...(n.controllers || [])];
  const valves = n.valves || [];
  const dcon = n.dcon || {};
  const weather = n.weather || {};
  const lastNote = n.meta?.lastUpdated
    ? `<p class="more-note">Last results from ` +
      `${escapeHtml(n.meta.lastType || 'a report')} · ` +
      `${escapeHtml(new Date(n.meta.lastUpdated).toLocaleString())}.` +
      `${n.meta.lastError ? ` Last error: ${escapeHtml(n.meta.lastError)}.` : ''}</p>`
    : '';

  const running = motors.filter((m) => m.status === 'on').length;
  const valvesOpen = valves.filter((v) => v.status === 'on').length;
  const cacheSec = (motors.length || valves.length || dcon.device || weather.temp != null)
    ? sectionHead('i-water_heater', 'Last results') + lastNote +
      `<div class="stats">
        <div class="stat stat-on"><span class="stat-label">Motors running</span>
          <span class="stat-value">${running}</span>
          <span class="stat-note">of ${motors.length} last seen</span></div>
        <div class="stat"><span class="stat-label">Valves open</span>
          <span class="stat-value">${valvesOpen}</span>
          <span class="stat-note">of ${valves.length} last seen</span></div>
        <div class="stat"><span class="stat-label">Field temp</span>
          <span class="stat-value">${weather.temp != null ? `${Math.round(weather.temp)}°` : '—'}</span>
          <span class="stat-note">${escapeHtml(weather.desc || 'no weather pull yet')}</span></div>
      </div>` +
      (motors.length
        ? `<div class="grid">${motors.map(irrigMotorCard).join('')}</div>` : '') +
      (valves.length
        ? `<div class="list${valves.length > 8 ? ' cols' : ''}">` +
          valves.map((v) => irrigRow('i-valve', v.name || `Valve ${v.id || ''}`,
            [v.runtime, v.id].filter(Boolean).join(' · ') || 'valve',
            irrigStatusTag(v.status))).join('') + `</div>` : '')
    : '';

  return head('Irrigation', 'Build a vendor report — motors, valves, weather.') +
    sectionHead('n-irrigation', 'Generate report') + builder + repsSec + cacheSec +
    `<p class="more-note">Read-only pulls — this page cannot operate pumps or valves.</p>`;
}

/* ---- admin (add people, grant/revoke view + control) ---- */

/* Two ways for an ordinary account to end up in acl/viewers or
 * acl/controllers, and both start on this page:
 *   - Add a person: writes acl/invites/<email key>. Their next sign-in
 *     claims it automatically (see enter()) and deletes the invite.
 *   - Grant/Revoke on an existing row: writes acl/viewers|controllers
 *     directly, for someone who has already signed in at least once and so
 *     self-registered acl/directory/<uid> with their email.
 * Neither path touches the command line or the service account — that is
 * the point: tools/grant-access.js remains only for the one tier this page
 * cannot hand out (see below).
 *
 * RTDB rules cascade a read of the whole acl subtree to an admin
 * (root.child('acl/admins').child(auth.uid)), so state.acl arrives as one
 * snapshot: { admins, viewers, controllers, directory, invites }. Admin
 * itself is never grantable from here — that stays a command-line,
 * service-account action (tools/grant-access.js --admin), the same way
 * cover/lock stay out of device control: promoting an admin is a security
 * decision, not a click. */

function aclTierOf(uid) {
  const a = state.acl || {};
  if (a.admins?.[uid] === true) return 'admin';
  if (a.controllers?.[uid] === true) return 'control';
  if (a.viewers?.[uid] === true) return 'view';
  return 'none';
}

const aclTierTag = (t) =>
  t === 'admin' ? `<span class="tag tag-on">Admin</span>`
  : t === 'control' ? `<span class="tag tag-on">Controller</span>`
  : t === 'view' ? `<span class="tag">Viewer</span>`
  : `<span class="tag tag-bad">No access</span>`;

/* One write, one path — same shape of trust as sendCommand. Removing a tier
 * is always allowed by rules; granting view or control is validated
 * server-side too, this just avoids a round trip to find out. */
function aclSet(uid, tier) {
  if (!isAdmin || !uid || uid === currentUser?.uid) return;
  const db = firebase.database();
  const viewRef = db.ref(`acl/viewers/${uid}`);
  const ctlRef = db.ref(`acl/controllers/${uid}`);
  const fail = (err) => {
    toast('err', err?.code === 'PERMISSION_DENIED'
      ? 'The database refused that change.' : `Could not update: ${err?.message || err}`);
  };
  let action;
  if (tier === 'none') action = Promise.all([ctlRef.remove(), viewRef.remove()]);
  else if (tier === 'view') action = ctlRef.remove().then(() => viewRef.set(true));
  else action = viewRef.set(true).then(() => ctlRef.set(true));   // 'control'
  action.then(() => toast('ok', 'Access updated.')).catch(fail);
}

/* Pre-authorize someone who has never signed in: write acl/invites/<key>,
 * and their first Google sign-in claims it automatically (see enter()) —
 * the only two ways to become a viewer or controller are an admin doing
 * this, or claiming an invite an admin left. Neither needs a terminal. */
function sendInvite() {
  if (!isAdmin) return;
  const emailInput = el('admin-add-email');
  const email = (emailInput?.value || '').trim().toLowerCase();
  const tier = el('admin-add-tier')?.value === 'control' ? 'control' : 'view';
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    toast('err', 'Enter a valid email address.');
    return;
  }
  const key = emailToInviteKey(email);
  firebase.database().ref(`acl/invites/${key}`).set({
    tier, at: firebase.database.ServerValue.TIMESTAMP,
  }).then(() => {
    toast('ok', `${email} will get ${tier === 'control' ? 'view + control' : 'view'} ` +
      `access the moment they sign in.`);
    if (emailInput) emailInput.value = '';
  }).catch((err) => {
    toast('err', err.code === 'PERMISSION_DENIED'
      ? 'The database refused that invite.' : `Could not invite: ${err.message}`);
  });
}

function cancelInvite(key) {
  if (!isAdmin || !key) return;
  firebase.database().ref(`acl/invites/${key}`).remove()
    .then(() => toast('ok', 'Invite cancelled.'))
    .catch(() => toast('err', 'Could not cancel that invite.'));
}

function inviteRow(key, invite) {
  const email = inviteKeyToEmail(key);
  const tierLabel = invite?.tier === 'control' ? 'View + control' : 'View';
  return `<div class="row acl-row">
    <span class="row-icon"><svg viewBox="0 0 24 24" class="ico ico-sm"><use href="#i-person"/></svg></span>
    <span class="row-main">
      <span class="row-name">${escapeHtml(email)}</span>
      <span class="row-meta">Invited · ${escapeHtml(tierLabel)} · awaiting first sign-in</span>
    </span>
    <span class="tag">Pending</span>
    <div class="acl-actions">
      <button class="btn btn-ghost" data-act="acl-cancel-invite" data-key="${escapeHtml(key)}">Cancel invite</button>
    </div>
  </div>`;
}

function adminRow(uid, person) {
  const tier = aclTierOf(uid);
  const email = person?.email || '';
  const name = person?.name || '';
  const self = uid === currentUser?.uid;
  const btn = (act, label) =>
    `<button class="btn btn-ghost" data-act="${act}" data-uid="${escapeHtml(uid)}">${escapeHtml(label)}</button>`;
  const actions = self ? `<span class="more-note">This is you</span>` : [
    tier === 'none' ? btn('acl-view', 'Grant view') : '',
    tier === 'view' ? btn('acl-control', 'Grant control') : '',
    tier === 'control' ? btn('acl-view', 'Revoke control') : '',
    tier === 'admin' ? `<span class="more-note">Admin — change from the command line</span>` : '',
    tier === 'view' || tier === 'control' ? btn('acl-none', 'Revoke all') : '',
  ].filter(Boolean).join(' ');
  return `<div class="row acl-row" data-uid="${escapeHtml(uid)}">
    <span class="row-icon"><svg viewBox="0 0 24 24" class="ico ico-sm"><use href="#i-person"/></svg></span>
    <span class="row-main">
      <span class="row-name">${escapeHtml(name || email || '(no directory entry)')}</span>
      <span class="row-meta">${escapeHtml([email, name ? uid : ''].filter(Boolean).join(' · ') || uid)}</span>
    </span>
    ${aclTierTag(tier)}
    <div class="acl-actions">${actions}</div>
  </div>`;
}

function adminView() {
  const acl = state.acl || {};
  const directory = acl.directory || {};
  const invites = acl.invites || {};
  const knownEmails = new Set(Object.values(directory)
    .map((p) => (p?.email || '').toLowerCase()).filter(Boolean));

  const uids = new Set([
    ...Object.keys(acl.admins || {}),
    ...Object.keys(acl.viewers || {}),
    ...Object.keys(acl.controllers || {}),
    ...Object.keys(directory),
  ]);
  const rank = { admin: 0, control: 1, view: 2, none: 3 };
  const peopleRows = [...uids]
    .map((uid) => ({ uid, tier: aclTierOf(uid), person: directory[uid] }))
    .sort((a, b) => rank[a.tier] - rank[b.tier] ||
      (a.person?.email || a.uid).localeCompare(b.person?.email || b.uid, undefined, NATURAL));
  // Once claimed, enter() deletes the invite - this filter just covers the
  // gap between a claim landing and the invite delete confirming.
  const inviteRows = Object.entries(invites)
    .filter(([key]) => !knownEmails.has(inviteKeyToEmail(key).toLowerCase()))
    .sort((a, b) => a[0].localeCompare(b[0], undefined, NATURAL));

  const addForm = `<div class="rep-builder">
    <label class="rep-field"><span>Email</span>
      <input id="admin-add-email" type="email" placeholder="someone@example.com" autocomplete="off" spellcheck="false"></label>
    <label class="rep-field"><span>Access</span>
      <select id="admin-add-tier"><option value="view">View</option><option value="control">View + control</option></select></label>
    <button class="btn btn-primary" data-act="admin-invite">Add person</button>
  </div>
  <p class="more-note">They get that access automatically the moment they sign in with that Google account — no command line, no service account.</p>`;

  const rows = [
    ...inviteRows.map(([key, inv]) => inviteRow(key, inv)),
    ...peopleRows.map((r) => adminRow(r.uid, r.person)),
  ];
  const list = rows.length
    ? `<div class="list">${rows.join('')}</div>`
    : emptyBlock('No one yet', 'Add someone above — they do not need to have signed in first.');

  return head('Admin', 'Add people and grant or revoke dashboard access.') +
    sectionHead('n-admin', 'Add a person') + addForm +
    sectionHead('n-admin', 'People') + list +
    `<p class="more-note">Admin status is granted from the command line ` +
    `(<code>npm run grant -- someone@example.com --admin</code>), not from here — ` +
    `the one tier this page cannot hand out.</p>`;
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
      <span class="dev-icon"><svg viewBox="0 0 24 24" class="ico"><use href="#i-${iconFor(ent)}"/></svg></span>
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
    <span class="row-icon"><svg viewBox="0 0 24 24" class="ico ico-sm"><use href="#i-${iconFor(ent)}"/></svg></span>
    <span class="row-main">
      <span class="row-name" title="${escapeHtml(ent.name || ent.entity_id)}">${escapeHtml(ent.name || ent.entity_id)}</span>
      <span class="row-meta">${escapeHtml(withArea ? areaName(ent.area) : humanDomain(ent.domain))}${subtitle(ent)}</span>
    </span>
    <span class="dev-state ${stateClass(ent)}">${escapeHtml(formatState(ent))}</span>
  </div>`;
}

const emptyBlock = (title, body) => `<div class="empty">
  <span class="empty-mark"><svg viewBox="0 0 24 24" class="ico"><use href="#i-search"/></svg></span>
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

  // Report builder: keep selections in module vars so a live re-render
  // mid-form does not wipe them; only a type change re-renders (to show or
  // hide the date fields), date edits stay put until Generate is pressed.
  view.querySelectorAll('[data-act="irr-type"]').forEach((sel) => {
    sel.onchange = () => { irrType = sel.value; render(); };
  });
  view.querySelectorAll('[data-act="irr-from"]').forEach((input) => {
    input.onchange = () => { irrFrom = input.value; };
  });
  view.querySelectorAll('[data-act="irr-to"]').forEach((input) => {
    input.onchange = () => { irrTo = input.value; };
  });
  view.querySelectorAll('[data-act="irr-gen"]').forEach((btn) => {
    btn.onclick = () => { sendReportRequest(); };
  });

  view.querySelectorAll('[data-act="acl-view"]').forEach((btn) => {
    btn.onclick = () => aclSet(btn.dataset.uid, 'view');
  });
  view.querySelectorAll('[data-act="acl-control"]').forEach((btn) => {
    btn.onclick = () => aclSet(btn.dataset.uid, 'control');
  });
  view.querySelectorAll('[data-act="acl-none"]').forEach((btn) => {
    btn.onclick = () => aclSet(btn.dataset.uid, 'none');
  });
  view.querySelectorAll('[data-act="admin-invite"]').forEach((btn) => {
    btn.onclick = () => sendInvite();
  });
  view.querySelectorAll('[data-act="acl-cancel-invite"]').forEach((btn) => {
    btn.onclick = () => cancelInvite(btn.dataset.key);
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
  const mpill = el('m-bridge'), mtext = el('m-bridge-text');
  const hb = state.meta?.bridge;
  const set = (cls, msg) => {
    pill.className = 'pill pill-unknown ' + cls;
    mpill.className = 'pill pill-unknown only-narrow ' + cls;
    text.textContent = msg; mtext.textContent = msg;
  };

  if (!hb || !hb.lastSeen) { set('', 'no bridge data'); return; }
  if (hb.status === 'offline') { set('pill-offline', 'bridge offline'); return; }

  const ageSec = (Date.now() + clockSkewMs - hb.lastSeen) / 1000;
  if (ageSec > (hb.heartbeatSeconds || 30) * STALE_FACTOR) {
    set('pill-stale', `stale ${humanAge(ageSec)}`);
  } else {
    set('pill-online', 'live');
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
