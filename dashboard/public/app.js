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

let state = { meta: {}, areas: {}, devices: {}, entities: {}, irrigation: {}, irrigation_reports: {}, water: {}, acl: {} };
let canControl = false;
let isAdmin = false;
let aclRef = null;
let currentUser = null;
let search = '';
let domainFilter = null;
let statusFilter = 'all';   // all | active | offline
const openDevices = new Set();   // device ids expanded on All devices
const openDetails = new Map();   // <details> opened or closed by hand
/* Report cards open one at a time. The newest opens by default (so the one
 * you just generated is visible when it lands); a card you open or close
 * yourself stays that way across the once-a-second rebuilds. */
const reportOpen = new Map();    // report key -> true/false, only once toggled
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

/* Light is the default look; dark is its complement. With no stored choice
 * the page follows the OS, and keeps following it if the OS flips at dusk. */
const isDark = () => document.documentElement.matches('[data-theme=dark]') ||
  (!document.documentElement.hasAttribute('data-theme') &&
   window.matchMedia('(prefers-color-scheme: dark)').matches);
const applyTheme = (t) => {
  if (t) document.documentElement.setAttribute('data-theme', t);
  else document.documentElement.removeAttribute('data-theme');
  const dark = isDark();
  document.querySelector('meta[name=theme-color]')?.setAttribute('content', dark ? '#1c1c1e' : '#ffffff');
  const label = el('theme-menu-text');
  if (label) label.textContent = dark ? 'Switch to light theme' : 'Switch to dark theme';
};
applyTheme(localStorage.getItem('snof-theme'));
window.matchMedia('(prefers-color-scheme: dark)').addEventListener?.('change', () =>
  applyTheme(localStorage.getItem('snof-theme')));

const flipTheme = () => {
  const next = isDark() ? 'light' : 'dark';
  localStorage.setItem('snof-theme', next);
  applyTheme(next);
};
el('theme-btn').onclick = flipTheme;
el('theme-menu').onclick = flipTheme;

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
el('signout-menu').onclick = doSignOut;
el('signout-gate').onclick = doSignOut;

function detach() {
  refs.forEach(({ ref, ev, cb }) => ref.off(ev, cb));
  refs = [];
  if (statusTimer) { clearInterval(statusTimer); statusTimer = null; }
  syncWaterPolling(false);
}

function leave() {
  detach();
  irrWaiters.forEach(({ ref, cb, timer }) => { clearTimeout(timer); ref.off('value', cb); });
  irrWaiters.clear();
  state = { meta: {}, areas: {}, devices: {}, entities: {}, irrigation: {}, water: {}, acl: {} };
  lsStep = 'idle'; lsMobile = ''; lsCode = ''; lsError = ''; lsInfo = '';
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
  // "Sibhi Govindasamy" -> "Sibhi G.": the bar has room for a name, not a
  // full one; the menu shows it whole.
  const parts = name.trim().split(/\s+/);
  el('acct-name').textContent = parts.length > 1 ? `${parts[0]} ${parts[parts.length - 1][0]}.` : name;
  el('acct-full').textContent = name;
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
  watch('devices', 'devices');
  watch('mobitech_status', 'mobitechStatus');
  watch('entities', 'entities');
  // The irrigation cache is whatever the last report left behind; the
  // reports list is the last 20 results, newest last from RTDB.
  watch('irrigation', 'irrigation');
  watch('water', 'water');
  watch('irrigation_lock', 'irrigationLock');
  {
    const resRef = db.ref(`farms/${FARM}/irrigation_command_results`).limitToLast(10);
    const resCb = resRef.on('value', (snap) => { settleIrrigation(snap.val() || {}); render(); }, () => {});
    refs.push({ ref: resRef, ev: 'value', cb: resCb });
  }
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

/* Only entities in a real room exist here. The bridge already refuses to
 * publish anything without an area; this is the second net, so a stale node
 * left over from an older bridge, or one whose room was just deleted, never
 * surfaces as an "Unassigned" pile or becomes pressable. */
function flatEntities() {
  const out = [];
  const areas = state.areas || {};
  for (const [domain, objs] of Object.entries(state.entities || {})) {
    for (const [objectId, node] of Object.entries(objs || {})) {
      if (node && typeof node === 'object' && node.area && node.area !== 'unassigned' && areas[node.area]) {
        out.push({ ...node, domain, objectId, key: `${domain}.${objectId}` });
      }
    }
  }
  return out;
}

const areaName = (id) => state.areas?.[id]?.name || id;

/* The farm thinks in devices — "the printer is off" — while Home Assistant
 * reports entities, dozens per device. Group back into devices for anything
 * that counts. An entity without a device id (an older bridge) stands alone. */
function byDevice(ents) {
  const map = new Map();
  for (const e of ents) {
    const id = e.device || e.key;
    if (!map.has(id)) map.set(id, { id, name: state.devices?.[e.device]?.name || e.name || e.key, area: e.area, ents: [] });
    map.get(id).ents.push(e);
  }
  return [...map.values()];
}
/** A device is offline when nothing on it is reporting, and active when
 *  anything on it is on, open or running. */
const deviceOffline = (d) => d.ents.every(isBad);
const deviceActive = (d) => d.ents.some(isOn);
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
  return [...map.entries()].sort((a, b) => areaName(a[0]).localeCompare(areaName(b[0]), undefined, NATURAL));
}

const byName = (a, b) => (a.name || a.key).localeCompare(b.name || b.key, undefined, NATURAL);

/* ================= commands ================= */

/* One write, one path, one shape. RTDB rules reject anything else, and the
 * bridge additionally refuses domains outside its own allow-list — so a bug
 * here cannot become a bug at the relay. */
function sendCommand(ent, service, data = {}) {
  if (!canControl) { toast('err', 'Your account can view, but not control.'); return; }
  const gate = bridgeGate('control');
  if (!gate.ok) { clearPending(ent.key); toast('err', gate.why); render(); return; }
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
  const gate = bridgeGate('control');
  // Checked before the optimistic flip, not after: a control that snaps back
  // 12 seconds later reads as a broken farm, not a switched-off feature.
  if (!gate.ok) { toast('err', gate.why); return; }
  const want = !isOn(ent);
  markPending(ent.key, want ? 'on' : 'off');
  render();
  sendCommand(ent, want ? 'turn_on' : 'turn_off');
}

function onLevel(ent, pct) {
  const gate = bridgeGate('control');
  if (!gate.ok) { toast('err', gate.why); render(); return; }
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
window.addEventListener('hashchange', () => { render(); el('view').focus(); window.scrollTo(0, 0); closeMenu(); });

/* ================= chrome ================= */

el('search').oninput = (e) => { search = e.target.value.trim().toLowerCase(); render(); };

const closeMenu = () => {
  el('acct-menu').hidden = true;
  el('acct-btn').setAttribute('aria-expanded', 'false');
};

el('acct-btn').onclick = (e) => {
  e.stopPropagation();
  const open = el('acct-menu').hidden;
  el('acct-menu').hidden = !open;
  el('acct-btn').setAttribute('aria-expanded', String(open));
};
el('acct-menu').onclick = (e) => e.stopPropagation();
document.addEventListener('click', () => { if (!el('acct-menu').hidden) closeMenu(); });
document.addEventListener('keydown', (e) => { if (e.key === 'Escape') closeMenu(); });

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
  el('brand-sub').textContent =
    farmName.replace(/^Sibhi\s*/i, '').replace(/\s*and Farms$/i, '') || 'Live farm state';
  // The search bar lives outside #view and shows only where it filters.
  document.body.dataset.route = r.name;

  const areas = groupByArea(all);
  document.querySelectorAll('.nav-admin').forEach((n) => { n.hidden = !isAdmin; });
  document.querySelectorAll('[data-nav]').forEach((n) =>
    n.classList.toggle('on', n.dataset.nav === (['area', 'devices'].includes(r.name) ? 'areas' : r.name === 'sys' ? 'overview' : r.name)));

  reconcilePending(all);
  syncWaterPolling(r.name === 'water' || r.name === 'overview');
  if (r.name === 'overview' || r.name === 'irrigation') autoRefreshIrrigation();

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
    else if (r.name === 'water') view.innerHTML = waterView();
    else if (r.name === 'sys') view.innerHTML = systemView(all, r.arg);
    else if (r.name === 'admin') view.innerHTML = isAdmin ? adminView()
      : head('Admin', '', '') +
        emptyBlock('Admins only', 'Your account does not have admin access.');
    else view.innerHTML = overviewView(all);
    wire(all);
    restoreFocus(token);
  }
  // After the view: the overview's own bridge pill is inside it.
  renderBridgeStatus();


  flashChanged(all);
}

/* ---- views ---- */

/* Every page opens the same way: an uppercase eyebrow that says where you
 * are, a large title, one line of context, and anything page-level on the
 * right. */
const head = (title, sub, right = '', eyebrow = '') =>
  `<div class="page-head"><div class="page-head-text">` +
  (eyebrow ? (eyebrow.startsWith('<') ? eyebrow : `<p class="eyebrow">${escapeHtml(eyebrow)}</p>`) : '') +
  `<h1 class="page-title">${escapeHtml(title)}</h1>` +
  (sub ? `<p class="page-sub">${escapeHtml(sub)}</p>` : '') +
  `</div><div class="spacer"></div>${right}</div>`;

const arrow = (name = 'i-arrow', cls = '') =>
  `<svg viewBox="0 0 24 24" class="ico${cls ? ' ' + cls : ''}" aria-hidden="true"><use href="#${name}"/></svg>`;

const panelHead = (title, link = null, n = null) =>
  `<div class="panel-head"><h2 class="panel-title">${escapeHtml(title)}` +
  (n != null ? `<span class="n">${n}</span>` : '') + `</h2>` +
  (link ? `<a class="panel-link" href="${link[0]}"${link[2] ? ` ${link[2]}` : ''}>${escapeHtml(link[1])}${arrow()}</a>` : '') +
  `</div>`;

const sectionHead = (_symbol, title, link = null) =>
  `<div class="section-head"><span class="section-title">${escapeHtml(title)}</span><span class="section-rule"></span>` +
  (link ? `<a class="panel-link" href="${link[0]}">See all${arrow()}</a>` : '') + `</div>`;

/** 6 -> "06". Two-digit counts read as a dashboard, and line up. */
const pad2 = (n) => (n >= 0 && n < 10 ? `0${n}` : String(n));
const WORDS = ['no', 'one', 'two', 'three', 'four', 'five', 'six', 'seven', 'eight', 'nine', 'ten', 'eleven', 'twelve'];
const inWords = (n) => (n <= 12 ? WORDS[n] : String(n));
const cap = (t) => t.charAt(0).toUpperCase() + t.slice(1);
const plural = (n, one, many) => (n === 1 ? one : many);
/** ["Cold Store", "East Orchard", "Barn"] -> "Cold Store, East Orchard and Barn". */
function listWords(items, max = 2) {
  if (items.length <= max) return items.length > 1 ? `${items.slice(0, -1).join(', ')} and ${items.at(-1)}` : (items[0] || '');
  const rest = items.length - max;
  return `${items.slice(0, max).join(', ')} and ${rest} ${plural(rest, 'other', 'others')}`;
}
const todayLine = () => new Date().toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })
  .replace(/^(\w+),?\s/, '$1 · ');

function skeletonView() {
  return head('Home', '', '') +
    `<div class="sk-grid">${'<div class="sk-card"></div>'.repeat(6)}</div>`;
}

/** Rooms with anything not reporting, worst first. */
function troubledAreas(devices) {
  const tally = new Map();
  for (const d of devices) if (deviceOffline(d)) tally.set(d.area, (tally.get(d.area) || 0) + 1);
  return [...tally.entries()].sort((a, b) => b[1] - a[1] ||
    areaName(a[0]).localeCompare(areaName(b[0]), undefined, NATURAL)).map(([id]) => id);
}

/** Which devices are down, and where — a to-do list, not an entity count. */
function attentionCard(devices) {
  const troubled = devices.filter((d) => d.ents.some(isBad));
  const dead = troubled.filter(deviceOffline);
  if (!dead.length) {
    const partly = troubled.length;
    return `<section class="panel att is-clear" aria-label="Attention">
      <div class="att-top"><span class="att-n">00</span><div>
        <p class="att-title">Every device is reporting</p>
        <p class="att-sub"><span>${partly ? `${inWords(partly)} ${plural(partly, 'is', 'are')} partly reporting` : 'Nothing needs a look right now.'}</span></p>
      </div></div></section>`;
  }
  const rooms = troubledAreas(devices).map(areaName);
  const rows = troubled.map((d) => ({ ...d, bad: d.ents.filter(isBad).length }))
    .sort((a, b) => (deviceOffline(b) - deviceOffline(a)) || (b.bad - a.bad) ||
                    a.name.localeCompare(b.name, undefined, NATURAL));
  // Past a handful, a list of identical "Offline" rows says less than where
  // they are: one row per room, worst first, with how much of it is down.
  const byRoom = dead.length > 4;
  const shown = byRoom ? [] : rows.slice(0, 3);
  const roomRows = byRoom ? troubledAreas(devices).slice(0, 3).map((id) => {
    const inRoom = devices.filter((d) => d.area === id);
    const down = inRoom.filter(deviceOffline).length;
    return `
      <a class="att-row" href="#/area/${encodeURIComponent(id)}">
        <span class="att-main"><span class="att-name">${escapeHtml(areaName(id))}</span>
          <span class="att-bar" aria-hidden="true"><span style="width:${(down / inRoom.length * 100).toFixed(1)}%"></span></span></span>
        <span class="att-count">${down}<span class="att-of"> of ${inRoom.length} offline</span></span>
      </a>`;
  }).join('') : '';
  return `<section class="panel att" aria-label="Attention">
    <div class="att-top"><span class="att-n">${pad2(dead.length)}</span><div>
      <p class="att-title">${plural(dead.length, 'Device needs', 'Devices need')} attention</p>
      <a class="att-sub" href="#/devices" data-act="filter" data-status="offline">
        <span>${escapeHtml(byRoom ? `Across ${rooms.length} ${plural(rooms.length, 'room', 'rooms')}`
          : rooms.slice(0, 2).join(' · ') + (rooms.length > 2 ? ` · +${rooms.length - 2}` : ''))}</span>${arrow()}</a>
    </div></div>
    <div class="att-list">` + roomRows + shown.map((d) => `
      <a class="att-row" href="#/area/${encodeURIComponent(d.area)}">
        <span class="att-main"><span class="att-name">${escapeHtml(d.name)}</span>
          <span class="att-meta">${escapeHtml(areaName(d.area))}</span></span>
        <span class="tag ${deviceOffline(d) ? 'tag-bad' : 'tag-warn'}">${deviceOffline(d) ? 'Offline' : `${d.bad} of ${d.ents.length} down`}</span>
      </a>`).join('') + `</div>` +
    (byRoom
      ? `<a class="att-more" href="#/devices" data-act="filter" data-status="offline">` +
        `<span>See all ${rows.length} not reporting</span>${arrow()}</a>`
      : rows.length > shown.length
      ? `<a class="att-more" href="#/devices" data-act="filter" data-status="offline">` +
        `<span>${rows.length - shown.length} more not reporting</span>${arrow()}</a>` : '') +
    `</section>`;
}

function quickControls(all) {
  // An unavailable device in a *control* panel is a dead switch. They belong in
  // the attention list, never here.
  const operable = all.filter((e) => CONTROLLABLE.has(e.domain) && !isBad(e)).sort(byName);
  const quick = operable.filter(isOn).concat(operable.filter((e) => !isOn(e))).slice(0, 5);
  const controllableTotal = all.filter((e) => CONTROLLABLE.has(e.domain)).length;
  const more = operable.length - quick.length;
  const body = quick.length
    ? `<div class="dev-list">${quick.map((e) => deviceCard(e, 'quick')).join('')}</div>` +
      (more > 0 ? `<a class="qc-more" href="#/devices" data-act="filter" data-status="active">` +
        `<span>${more} more operable ${plural(more, 'device', 'devices')}</span>${arrow()}</a>` : '')
    : emptyBlock('Nothing to operate right now',
        controllableTotal
          ? `All ${controllableTotal} switches, lights and fans are currently unavailable.`
          : 'No switches, lights or fans are in a room yet.');
  return `<section class="panel qc" aria-label="Quick controls">` +
    panelHead(canControl ? 'Quick controls' : 'Controllable devices', ['#/devices', 'All devices']) +
    controlNote() + body + `</section>`;
}

/* Home: what needs a look, one line per system, and the switches. Every
 * number here is a link to the page that has the rest (owner, 2026-09-25:
 * "basic and simple to navigate"). */
function solarGlance(all) {
  const sensors = all.filter((e) => e.domain === 'sensor');
  const unit = (e) => e.attrs?.unit_of_measurement;
  const first = (test) => { const hits = sensors.filter((e) => test(String(e.name || '').toLowerCase(), e)); return hits.find((e) => !isBad(e)) || hits[0]; };
  const now = first((n, e) => (e.attrs?.device_class === 'power' || ['W', 'kW'].includes(unit(e))) && (n.endsWith('pv power') || n.endsWith('solar power')));
  const today = first((n, e) => n.includes('today') && (n.includes('pv') || n.includes('solar')) && (e.attrs?.device_class === 'energy' || unit(e) === 'kWh'));
  if (!now && !today) return null;
  const val = (e) => (e && !isBad(e) ? `${e.state} ${unit(e) || ''}`.trim() : null);
  return { area: (now || today).area, now: val(now), today: val(today) };
}

/* ---- Home, drawn (owner, 2026-09-25: "so dull … I need more visuals") ----
 * Every picture is real data: the water chain as pipes that flow while their
 * motor runs, a ring for the irrigation run, solar, a donut of what is
 * reporting, and the switches as tiles. Colour still only means something:
 * brand green is on / flowing, brick is offline. */

const motorArt = (m) => artImg(m && m.running ? 'motor-on' : 'motor-off', 'flow-art');
const motorWord = (m) => (!m ? 'No reading' : m.running === true ? 'Running' : m.running === false ? 'Off' : 'Unknown');

function flowHero() {
  const w = state.water || {};
  const motors = Object.values(w.motors || {});
  const supply = motors.find((m) => m.role === 'main-farm');
  const drip = motors.find((m) => m.role === 'drip');
  const s = irrNowState();
  const node = (cls, art, title, sub, on) =>
    `<div class="flow-node ${cls}${on ? ' is-on' : ''}"><span class="flow-disc">${art}</span>` +
    `<span class="flow-title">${escapeHtml(title)}</span><span class="flow-sub">${escapeHtml(sub)}</span></div>`;
  const pipe = (on, label) => `<div class="flow-pipe${on ? ' is-on' : ''}" aria-hidden="true">` +
    `<span class="pipe-line"></span>` +
    (label ? `<em>${escapeHtml(label)}</em>` : '') + `</div>`;
  const drips = drip ? `<a class="flow-branch${drip.running ? ' is-on' : ''}" href="#/water">${artImg(drip.running ? 'motor-on' : 'motor-off', 'flow-mini')}` +
    `<span>${escapeHtml(drip.name)} · ${escapeHtml(motorWord(drip))}${drip.program ? ` · ${escapeHtml(drip.program)} zone ${drip.zone ?? ''}` : ''}</span></a>` : '';
  const hasWater = w.river || motors.length;
  return `<section class="panel flow" aria-label="Water from the river to the main farm">
    <div class="flow-head"><h2 class="panel-title">Water</h2>
      ${w.pulledAt ? `<span class="card-age">${escapeHtml(agoText(w.pulledAt))}</span>` : ''}
      <a class="panel-link" href="#/water">Details${arrow()}</a></div>
    <div class="flow-row">
      ${node('', motorArt(w.river), 'River', hasWater ? motorWord(w.river) : 'No reading', w.river?.running)}
      ${pipe(w.river?.running, '')}
      ${node('', motorArt(supply), 'Other farm', supply ? `7.5 HP ${motorWord(supply).toLowerCase()}` : 'No reading', supply?.running)}
      ${pipe(supply?.running, '')}
      ${node('farm', artImg('kulam', 'flow-art'), 'Main farm', s.running ? 'Watering' : 'Not watering', s.running)}
    </div>
    ${drips}
  </section>`;
}

/* A ring: how far through the current run, or how much of the last one was
 * delivered. Stopped early reads amber, never green. */
function ring(frac, tone, label, sub) {
  const r = 42, c = 2 * Math.PI * r, f = Math.max(0, Math.min(1, frac || 0));
  return `<div class="ring ${tone}" role="img" aria-label="${escapeHtml(label)} ${escapeHtml(sub)}">
    <svg viewBox="0 0 100 100"><circle class="ring-track" cx="50" cy="50" r="${r}"/>
      <circle class="ring-fill" cx="50" cy="50" r="${r}" stroke-dasharray="${(c * f).toFixed(1)} ${c.toFixed(1)}"/></svg>
    <span class="ring-mid"><strong>${escapeHtml(label)}</strong><small>${escapeHtml(sub)}</small></span></div>`;
}

/** When the controller was last asked, as "5 min ago" (Refresh pulls it). */
const irrChecked = () => { const c = irrig(); const t = c.program?.at || c.meta?.lastUpdated; return t ? agoText(t) : ''; };

function irrigationCard() {
  const c = irrig(), p = c.program, s = irrNowState();
  const empty = !p && !(c.timerLog || []).length;
  let frac = 0, tone = '', label = '—', sub = 'no data';
  let valves = '';
  if (s.running && p) {
    const left = p.remainingMin, planned = p.plannedMin;
    frac = planned ? 1 - Math.max(0, left || 0) / planned : 0.5;
    tone = 'is-on'; label = left != null ? fmtMin(Math.max(0, left)) : 'On'; sub = 'left';
    valves = p.valves || '';
  } else {
    const last = irrRuns()[0];
    if (last) {
      frac = last.planned ? (last.delivered ?? (last.finished ? last.planned : 0)) / last.planned : 1;
      tone = last.finished ? 'is-done' : 'is-warn';
      label = runAmount(last).split(' of ')[0] || '—'; sub = last.finished ? 'last run' : 'stopped early';
      valves = last.valves;
    }
  }
  const pics = String(valves).split(/,\s*/).filter(Boolean).slice(0, 5)
    .map((v) => { const a = valveArt(v, 'irrigation'); return a ? artImg(a, 'crop') : ''; }).join('');
  return `<a class="panel vcard" href="#/irrigation" aria-label="Irrigation">
    <span class="vcard-label">Irrigation${irrChecked() ? ` <em class="card-age">${escapeHtml(irrChecked())}</em>` : ''}</span>
    ${empty ? `<p class="vcard-empty">No data yet</p>` : `<div class="vcard-body">${ring(frac, tone, label, sub)}
      <div class="vcard-text"><strong>${escapeHtml(s.running ? s.title : s.title.replace(/^Last: /, ''))}</strong>
        <span>${escapeHtml(s.running ? 'Watering now' : farmWhen(irrRuns()[0]?.start || '') || 'Not watering')}</span>
        <span class="crops">${pics}</span></div></div>`}
  </a>`;
}

/** One operable thing as a tile; the whole tile is the button. */
function tileFor(e) {
  const want = pending.get(e.key)?.want;
  const on = want ? want === 'on' : isOn(e);
  const can = canControl && bridgeGate('control').ok;
  const full = e.name || e.entity_id;
  const dev = state.devices?.[e.device]?.name || '';
  const trimmed = dev && full.startsWith(`${dev} `) ? full.slice(dev.length + 1) : full;
  const name = trimmed || full;
  return `<button class="tile${on ? ' is-on' : ''}${want ? ' busy' : ''}" data-key="${escapeHtml(e.key)}" data-act="toggle"` +
    ` role="switch" aria-checked="${on}" aria-label="${escapeHtml(full)}"${can ? '' : ' disabled'}>` +
    `<span class="tile-ico"><svg viewBox="0 0 24 24" class="ico"><use href="#i-${iconFor(e)}"/></svg></span>` +
    `<span class="tile-name">${escapeHtml(name)}</span>` +
    `<span class="tile-meta">${escapeHtml(areaName(e.area))} · ${on ? 'On' : 'Off'}</span></button>`;
}

/* The switches as tiles, on first: the ones you would reach for. */
function switchTiles(all) {
  // Only the lights & switches system: an inverter's export-limit switch or
  // an AC's sleep mode is a setting, not something to reach for on Home.
  const sys = farmSystems(all).switches;
  const operable = (sys ? sys.ents : []).filter((e) => CONTROLLABLE.has(e.domain) && !isBad(e)).sort(byName);
  const shown = operable.filter(isOn).concat(operable.filter((e) => !isOn(e))).slice(0, 8);
  if (!shown.length) return '';
  const more = operable.length - shown.length;
  return `<section class="tiles-sec" aria-label="Switches">
    <div class="panel-head bare"><h2 class="panel-title">Switches</h2>
      <a class="panel-link" href="#/sys/switches">${more > 0 ? `All ${operable.length}` : 'All'}${arrow()}</a></div>
    ${controlNote()}<div class="tiles">${shown.map(tileFor).join('')}</div></section>`;
}

/* ---- the farm, by system ----
 * Devices sorted into what they are, from their own entities rather than
 * names typed by hand: an inverter reports PV power, a camera is a camera,
 * an AC is a climate entity. Mirrors Systems.swift in SNOFCore; keep the
 * rules in step. Each system knows whether being offline is a problem (a
 * camera, the inverter, a switch module) or only means it is switched off at
 * the wall (an AC, a TV, the 3D printer), so appliances at rest never read
 * as faults. (Owner, 2026-09-25: most "offline" devices were ACs, TVs and a
 * printer that were simply off.) */
const SYSTEMS = {
  security: { title: 'Security', icon: 'i-shield', offline: 'bad' },
  solar: { title: 'Solar', icon: 'i-sun', offline: 'warn' },
  switches: { title: 'Lights & switches', icon: 'i-light', offline: 'warn' },
  climate: { title: 'Climate', icon: 'i-climate', offline: 'none' },
  media: { title: 'TVs', icon: 'i-media_player', offline: 'none' },
  printer: { title: '3D printer', icon: 'i-printer', offline: 'none' },
  other: { title: 'Other', icon: 'i-default', offline: 'none' },
};
const SYSTEM_ORDER = ['security', 'solar', 'switches', 'climate', 'media', 'printer', 'other'];
const lname = (e) => String(e.name || '').toLowerCase();
const numOf = (e) => { const n = parseFloat(e?.state); return e && !isBad(e) && Number.isFinite(n) ? n : null; };
const unitOf = (e) => e?.attrs?.unit_of_measurement || '';
const fmtPower = (w) => (w >= 1000 ? `${(w / 1000).toFixed(2)} kW` : `${Math.round(w)} W`);

function systemOfDevice(g) {
  const ents = g.ents;
  const has = (dom) => ents.some((e) => e.domain === dom);
  if (ents.some((e) => e.domain === 'sensor' && /(pv power|solar power|pv generation)/.test(lname(e)))) return 'solar';
  if (has('alarm_control_panel') || has('camera') && !ents.some((e) => /print/.test(lname(e)))) return 'security';
  if (ents.some((e) => /\bprint (error|progress|status)|current stage/.test(lname(e)))) return 'printer';
  if (has('climate')) return 'climate';
  if (has('media_player')) return 'media';
  if (ents.some((e) => CONTROLLABLE.has(e.domain))) return 'switches';
  return 'other';
}

/** { id -> { id, title, icon, offline, devices, ents } } for systems that have devices. */
function farmSystems(all) {
  const groups = byDevice(all);
  const out = {};
  const put = (id, g) => {
    if (!out[id]) out[id] = { id, ...SYSTEMS[id], devices: [], ents: [] };
    out[id].devices.push(g); out[id].ents.push(...g.ents);
  };
  const printers = [];
  const rest = [];
  for (const g of groups) {
    const id = systemOfDevice(g);
    if (id === 'printer') { printers.push(g.name); put(id, g); } else rest.push([id, g]);
  }
  // A printer's add-ons (its AMS, the external spool) are named after it.
  for (const [id, g] of rest) put(printers.some((p) => g.name.startsWith(`${p}_`)) ? 'printer' : id, g);
  return out;
}

/** deviceId -> system id, so any page can tell a fault from an appliance at rest. */
function deviceSystems(all) {
  const out = new Map();
  for (const sys of Object.values(farmSystems(all))) for (const d of sys.devices) out.set(d.id, sys.id);
  return out;
}
/** Offline devices split into faults and appliances switched off. */
function offlineSplit(devices, index) {
  const down = devices.filter(deviceOffline);
  const fault = down.filter((d) => (SYSTEMS[index.get(d.id)] || SYSTEMS.other).offline !== 'none');
  return { fault: fault.length, off: down.length - fault.length };
}

/** One status line per system: { state: on|rest|off|offline|bad, line, sub }. */
function systemSummary(sys) {
  const ents = sys.ents;
  const find = (test) => ents.find((e) => test(lname(e), e) && !isBad(e)) || ents.find((e) => test(lname(e), e));
  const offlineDevices = sys.devices.filter(deviceOffline);
  const allOffline = offlineDevices.length === sys.devices.length;
  switch (sys.id) {
    case 'solar': {
      const pv = find((n, e) => e.domain === 'sensor' && (n.endsWith('pv power') || n.endsWith('solar power')));
      const today = find((n, e) => e.domain === 'sensor' && n.includes('today') && (n.includes('pv') || n.includes('solar')));
      const mode = find((n) => n.endsWith('work mode'));
      let w = numOf(pv);
      if (w != null && unitOf(pv).toLowerCase() === 'kw') w *= 1000;
      const kwh = numOf(today);
      if (allOffline || w == null) return { state: 'offline', line: 'Inverter offline', sub: '', watts: null, kwh };
      if (w > 0) return { state: 'on', line: fmtPower(w), sub: kwh != null ? `${kwh} kWh today` : 'generating', watts: w, kwh };
      const resting = /wait|standby|sleep/i.test(mode?.state || '');
      return { state: 'rest', line: resting ? 'Resting' : '0 W', sub: kwh ? `${kwh} kWh today` : (resting ? 'No sun right now' : ''), watts: 0, kwh };
    }
    case 'security': {
      const panels = ents.filter((e) => e.domain === 'alarm_control_panel' && !isBad(e));
      const cams = ents.filter((e) => e.domain === 'camera');
      const camsOn = cams.filter((e) => !isBad(e)).length;
      const active = ents.filter((e) => e.domain === 'binary_sensor' && isOn(e) && /(person|motion|pet) detected/.test(lname(e)));
      const p = panels.find((e) => e.state === 'triggered') || panels.find((e) => /^armed/.test(e.state)) || panels[0];
      const armed = !p ? '' : p.state === 'triggered' ? 'Alarm triggered'
        : p.state === 'disarmed' ? 'Disarmed' : /^armed_/.test(p.state) ? `Armed · ${cap(p.state.replace('armed_', '').replace('_', ' '))}` : cap(p.state);
      const camLine = cams.length ? `${camsOn} of ${cams.length} cameras online` : '';
      return { state: p?.state === 'triggered' ? 'bad' : active.length ? 'on' : camsOn < cams.length ? 'warn' : 'rest',
               line: armed || camLine || 'No alarm', sub: active.length ? `${active.length} detecting now` : (armed ? camLine : ''),
               armed: !!p && /^armed/.test(p.state), camsOn, cams: cams.length, active };
    }
    case 'switches': {
      const ops = ents.filter((e) => CONTROLLABLE.has(e.domain));
      const live = ops.filter((e) => !isBad(e));
      const on = live.filter(isOn).length;
      return { state: on ? 'on' : live.length ? 'rest' : 'offline',
               line: !live.length ? 'Offline' : on ? `${on} on` : 'All off',
               sub: `${live.length} of ${ops.length} reachable`, on, total: ops.length };
    }
    case 'climate': case 'media': {
      const main = ents.filter((e) => e.domain === (sys.id === 'climate' ? 'climate' : 'media_player'));
      const on = main.filter((e) => !isBad(e) && !['off', 'standby', 'idle'].includes(e.state));
      // A set-top box is not a TV: count screens as devices.
      const noun = sys.id === 'climate' ? ['AC', 'ACs'] : ['device', 'devices'];
      return { state: on.length ? 'on' : 'off', line: on.length ? `${on.length} on` : 'All off',
               sub: `${main.length} ${plural(main.length, noun[0], noun[1])}` };
    }
    case 'printer': {
      const prog = find((n, e) => n.includes('progress') && unitOf(e) === '%');
      const stage = find((n) => /current stage|print status/.test(n));
      const pct = numOf(prog);
      if (allOffline) return { state: 'off', line: 'Off', sub: 'Switched off' };
      if (pct != null && pct > 0 && pct < 100) return { state: 'on', line: `Printing ${Math.round(pct)}%`, sub: stage && !isBad(stage) ? cap(String(stage.state).replace(/_/g, ' ')) : '' };
      return { state: 'rest', line: stage && !isBad(stage) ? cap(String(stage.state).replace(/_/g, ' ')) : 'Idle', sub: '' };
    }
    default: {
      const on = sys.devices.filter(deviceActive).length;
      return { state: on ? 'on' : 'rest', line: on ? `${on} active` : 'Quiet', sub: `${sys.devices.length} ${plural(sys.devices.length, 'device', 'devices')}` };
    }
  }
}

/* ---- needs a look ----
 * Everything across every system that deserves a look, worst first, each
 * with where to go about it. Appliances switched off never appear here. */
function attentionItems(all, systems) {
  const items = [];
  const add = (level, text, sub, href) => items.push({ level, text, sub, href });
  const b = bridgeStatus();
  if (b.cls === 'pill-offline' || b.cls === 'pill-stale') {
    add('bad', 'Farm box offline', `Switches and controller reads are paused${b.ageSec ? ` · quiet for ${humanAge(b.ageSec)}` : ''}`, '#/');
  }
  // Irrigation.
  const c = irrig(), p = c.program;
  if (p && p.running) for (const f of p.faults || []) add('bad', `Valve ${f}`, 'during the running program', '#/irrigation');
  const sup = irrSupply();
  if (sup && sup.v.length && !sup.live) add('warn', 'No power at the pump', sup.at ? `as of ${sup.at}` : '', '#/irrigation');
  else if (sup && sup.missing) add('bad', 'A power phase is missing', `${sup.live} of 3 phases live${sup.at ? ` · ${sup.at}` : ''}`, '#/irrigation');
  const since = serverNow() - 864e5;
  // Programs with no valves assigned end at 0m by design; they are not faults.
  const stopped = irrRuns().filter((r) => !r.finished && r.planned != null && r.valves && (farmMs(r.start) ?? 0) >= since);
  if (stopped.length) add('warn', `${stopped.length} ${plural(stopped.length, 'run', 'runs')} stopped early`, stopped.slice(0, 2).map((r) => `${r.name} ${runAmount(r)}`).join(' · '), '#/irrigation');
  const repErr = c.meta?.lastError;
  if (repErr) add('warn', 'Could not reach the controller', repErr.replace(/^DCON [a-z_]+: /, '').slice(0, 80), '#/irrigation');
  if (isAdmin && mobitechState().kind !== 'ok') add('warn', 'Mobitech sign-in needed', 'valve control is off until an admin signs in', '#/irrigation');
  // Water chain.
  const w = state.water || {};
  for (const m of [w.river, ...Object.values(w.motors || {})].filter(Boolean)) {
    if ((m.trips || []).length) add('bad', `${m.name} tripped`, m.trips.join(', '), '#/water');
    if (m.skippedZone != null) add('warn', `${m.name}: zone ${m.skippedZone} skipped`, 'no valve feedback', '#/water');
  }
  const ws = state.meta?.water || {};
  if (ws.enabled === true) {
    if (isAdmin && liveskyState().kind !== 'ok') add('warn', 'Livesky sign-in needed', 'the river motor is not being read', '#/water');
    else if (ws.livesky?.ok === false && ws.livesky?.error) add('warn', 'River motor not read', ws.livesky.error, '#/water');
    if (ws.niagara?.ok === false && ws.niagara?.error) add('warn', 'Other farm not read', ws.niagara.error, '#/water');
    if (w.pulledAt && serverNow() - w.pulledAt > 30 * 60000) add('warn', 'Water readings are old', `last read ${agoText(w.pulledAt)}`, '#/water');
  }
  // Home Assistant systems that should never be offline.
  for (const id of ['security', 'solar', 'switches']) {
    const sys = systems[id];
    if (!sys) continue;
    if (id === 'security') {
      const s = systemSummary(sys);
      if (s.state === 'bad') add('bad', 'Alarm triggered', '', `#/sys/security`);
      const camsDown = sys.ents.filter((e) => e.domain === 'camera' && isBad(e));
      if (camsDown.length) add('warn', `${camsDown.length === 1 ? camsDown[0].name.replace(/ camera$/i, '') + ' camera' : `${camsDown.length} cameras`} offline`,
        camsDown.length > 1 ? camsDown.map((e) => e.name).join(', ') : areaName(camsDown[0].area), '#/sys/security');
      continue;
    }
    if (id === 'solar') {
      const h = new Date(serverNow() + 330 * 60000).getUTCHours();
      if (h >= 7 && h < 18 && systemSummary(sys).state === 'offline') add('warn', 'Solar inverter offline', 'during daylight', '#/sys/solar');
      continue;
    }
    const down = sys.devices.filter(deviceOffline);
    if (down.length) add('warn', `${down.length === 1 ? down[0].name : `${down.length} switch modules`} offline`,
      down.length === 1 ? areaName(down[0].area) : down.map((d) => d.name).join(', '), '#/sys/switches');
  }
  return items.sort((a, b) => (a.level === b.level ? 0 : a.level === 'bad' ? -1 : 1));
}

function attentionPanel(items) {
  if (!items.length) {
    return `<section class="panel attn is-clear" aria-label="Needs a look"><span class="attn-ok">${arrow('i-check')}</span>` +
      `<span><strong>All clear</strong><span>Nothing on the farm needs a look.</span></span></section>`;
  }
  const bad = items.filter((i) => i.level === 'bad').length;
  const shown = items.slice(0, 5);
  return `<section class="panel attn${bad ? ' is-bad' : ''}" aria-label="Needs a look">
    <div class="attn-head"><span class="attn-n">${items.length}</span><h2 class="panel-title">${plural(items.length, 'Thing needs', 'Things need')} a look</h2></div>
    ${shown.map((i) => `<a class="attn-row ${i.level}" href="${i.href}"><span class="attn-dot"></span>` +
      `<span class="attn-main"><strong>${escapeHtml(i.text)}</strong>${i.sub ? `<span>${escapeHtml(i.sub)}</span>` : ''}</span>${arrow('i-chevron', 'attn-chev')}</a>`).join('')}
    ${items.length > shown.length ? `<p class="attn-more">${items.length - shown.length} more</p>` : ''}
  </section>`;
}

function securityCard(systems) {
  const sys = systems.security;
  if (!sys) return '';
  const s = systemSummary(sys);
  const tone = s.state === 'bad' ? 'is-bad' : s.armed ? 'is-on' : '';
  return `<a class="panel vcard sec ${tone}" href="#/sys/security" aria-label="Security">
    <span class="vcard-label">Security</span>
    <div class="vcard-body"><span class="shield" aria-hidden="true"><svg viewBox="0 0 24 24" class="ico"><use href="#i-shield"/></svg></span>
      <div class="vcard-text"><strong>${escapeHtml(s.line)}</strong>
        <span>${escapeHtml(s.sub || (s.cams ? `${s.camsOn} of ${s.cams} cameras online` : ''))}</span>
        ${s.cams ? `<span class="cam-dots" aria-hidden="true">${sys.ents.filter((e) => e.domain === 'camera').map((e) => `<i class="${isBad(e) ? 'off' : 'on'}"></i>`).join('')}</span>` : ''}</div></div>
  </a>`;
}

function solarCard(systems) {
  const sys = systems.solar;
  if (!sys) return '';
  const s = systemSummary(sys);
  const [v, u] = s.watts > 0 ? fmtPower(s.watts).split(' ') : [s.line, ''];
  return `<a class="panel vcard solar is-${s.state}" href="#/sys/solar" aria-label="Solar">
    <span class="vcard-label">Solar</span>
    <div class="vcard-body"><span class="sun" aria-hidden="true"><svg viewBox="0 0 48 48"><circle cx="24" cy="24" r="9"/>
      ${[0, 45, 90, 135, 180, 225, 270, 315].map((d) => `<line x1="24" y1="5" x2="24" y2="10" transform="rotate(${d} 24 24)"/>`).join('')}</svg></span>
      <div class="vcard-text"><strong class="${s.watts > 0 ? 'big' : ''}">${escapeHtml(v)}${u ? `<small>${escapeHtml(u)}</small>` : ''}</strong>
        <span>${escapeHtml(s.watts > 0 ? `now · ${s.sub}` : s.sub || '')}</span></div></div>
  </a>`;
}

/* The rest of the farm, one tile each: what it is, and one word on how it is. */
function systemsGrid(systems) {
  // Switches have their own tiles (and an "All" link) right above.
  const ids = ['climate', 'media', 'printer', 'other'].filter((id) => systems[id]);
  if (!ids.length) return '';
  return `<section class="sys-sec" aria-label="Farm systems">
    <div class="panel-head bare"><h2 class="panel-title">Around the farm</h2></div>
    <div class="sys-grid">${ids.map((id) => {
      const sys = systems[id], s = systemSummary(sys);
      return `<a class="sys-tile is-${s.state}" href="#/sys/${id}"><span class="sys-ico"><svg viewBox="0 0 24 24" class="ico"><use href="#${sys.icon}"/></svg></span>` +
        `<span class="sys-name">${escapeHtml(sys.title)}</span><span class="sys-line">${escapeHtml(s.line)}</span>` +
        (s.sub ? `<span class="sys-sub">${escapeHtml(s.sub)}</span>` : '') + `</a>`;
    }).join('')}</div></section>`;
}

function overviewView(all) {
  const systems = farmSystems(all);
  const busy = irrRefreshing.size > 0;
  const refresh = `<button class="btn btn-ghost btn-sm" data-act="home-refresh"${busy ? ' disabled' : ''}>${busy ? 'Checking…' : 'Refresh'}</button>`;
  return head('Home', '', refresh) + attentionPanel(attentionItems(all, systems)) + flowHero() +
    `<div class="vcards">${irrigationCard()}${solarCard(systems)}${securityCard(systems)}</div>` +
    switchTiles(all) + systemsGrid(systems);
}

/* ---- one system, in full ---- */
function systemView(all, id) {
  const systems = farmSystems(all);
  const sys = systems[id];
  const back = `<a class="back" href="#/">${arrow('i-back')}Home</a>`;
  if (!sys) return head('Not found', '', '', back) + emptyBlock('Nothing here', 'This part of the farm has no devices right now.');
  const s = systemSummary(sys);
  const devices = sys.devices.slice().sort((a, b) => (deviceOffline(a) - deviceOffline(b)) || a.name.localeCompare(b.name, undefined, NATURAL));
  let top = '';
  if (id === 'solar') {
    const f = (test) => sys.ents.find((e) => test(lname(e)) && !isBad(e));
    const facts = [
      ['Now', s.watts != null ? fmtPower(s.watts) : '—'],
      ['Today', s.kwh != null ? `${s.kwh} kWh` : '—'],
      ['Lifetime', (() => { const t = numOf(f((n) => n.includes('total pv generation'))); return t != null ? `${Math.round(t).toLocaleString('en-IN')} kWh` : '—'; })()],
      ['Mode', f((n) => n.endsWith('work mode'))?.state || '—'],
      ['Inverter', (() => { const t = numOf(f((n) => n.endsWith('inverter temperature'))); return t != null ? `${t} °C` : '—'; })()],
      ['Grid', (() => { const v = numOf(f((n) => n.includes('on-grid l1 voltage'))); return v != null ? `${Math.round(v)} V` : '—'; })()],
      ['Export limit', (() => { const sw = f((n) => n.includes('export limit switch')); const pct = numOf(f((n) => n.endsWith('grid export limit')));
        return sw ? `${sw.state === 'on' ? 'On' : 'Off'}${pct != null ? ` · ${pct}%` : ''}` : '—'; })()],
    ];
    top = `<section class="panel sys-hero solar is-${s.state}"><span class="sun" aria-hidden="true"><svg viewBox="0 0 48 48"><circle cx="24" cy="24" r="9"/>` +
      [0, 45, 90, 135, 180, 225, 270, 315].map((d) => `<line x1="24" y1="5" x2="24" y2="10" transform="rotate(${d} 24 24)"/>`).join('') + `</svg></span>` +
      `<div class="mb-facts">${facts.map(([k, v]) => `<div><span>${k}</span><strong>${escapeHtml(v)}</strong></div>`).join('')}</div></section>`;
  } else if (id === 'security') {
    const cams = sys.ents.filter((e) => e.domain === 'camera');
    top = `<section class="panel sys-hero sec ${s.state === 'bad' ? 'is-bad' : s.armed ? 'is-on' : ''}"><span class="shield" aria-hidden="true"><svg viewBox="0 0 24 24" class="ico"><use href="#i-shield"/></svg></span>
      <div><h2 class="sys-hero-title">${escapeHtml(s.line)}</h2><p class="sys-hero-sub">${escapeHtml(`${s.camsOn} of ${s.cams} cameras online`)}${s.active.length ? ` · ${s.active.length} detecting now` : ''}</p></div></section>` +
      `<section class="panel"><div class="list">${cams.map((e) => {
        const dev = sys.devices.find((d) => d.ents.includes(e));
        const now = (dev?.ents || []).filter((x) => x.domain === 'binary_sensor' && isOn(x) && /(person|motion|pet|sound) detected/.test(lname(x)))
          .map((x) => lname(x).match(/(person|motion|pet|sound) detected/)[1]);
        return `<div class="row ${isBad(e) ? 'is-bad' : ''}"><span class="row-icon"><svg viewBox="0 0 24 24" class="ico ico-sm"><use href="#i-camera"/></svg></span>
          <span class="row-main"><span class="row-name">${escapeHtml(dev?.name || e.name)}</span><span class="row-meta">${escapeHtml(areaName(e.area))}</span></span>
          ${isBad(e) ? `<span class="tag tag-bad">Offline</span>` : now.length ? `<span class="tag tag-on">${escapeHtml(cap(now.join(', ')))} now</span>` : `<span class="tag">Watching</span>`}</div>`;
      }).join('')}</div></section>`;
  } else {
    top = `<section class="panel sys-hero is-${s.state}"><span class="sys-ico big"><svg viewBox="0 0 24 24" class="ico"><use href="#${sys.icon}"/></svg></span>
      <div><h2 class="sys-hero-title">${escapeHtml(s.line)}</h2>${s.sub ? `<p class="sys-hero-sub">${escapeHtml(s.sub)}</p>` : ''}</div></section>`;
  }
  // Operable things as tiles; everything else as the device's readings,
  // offline devices last and folded, since there is nothing to do with them.
  const ops = sys.ents.filter((e) => CONTROLLABLE.has(e.domain) && !isBad(e));
  // Settings stay settings: the inverter's and the ACs' switches are shown as
  // readings, never offered as tiles.
  const tiles = ops.length && ['switches', 'other'].includes(id)
    ? `<section class="tiles-sec"><div class="panel-head bare"><h2 class="panel-title">Switches</h2></div>${controlNote()}<div class="tiles">${ops.filter(isOn).sort(byName).concat(ops.filter((e) => !isOn(e)).sort(byName)).map(tileFor).join('')}</div></section>` : '';
  const live = devices.filter((d) => !deviceOffline(d));
  const off = devices.filter(deviceOffline);
  const devList = ['security', 'solar', 'switches'].includes(id) ? '' : live.map((d) => `<section class="panel area-sec">` + panelHead(d.name, null) +
      `<div class="list">${d.ents.filter((e) => !isBad(e) && !CONTROLLABLE.has(e.domain) && !['select', 'number', 'time', 'button', 'image'].includes(e.domain)).sort(byName).slice(0, 12).map((e) => row(e)).join('') || `<p class="more-note">${escapeHtml(areaName(d.area))}</p>`}</div></section>`).join('');
  const offNote = off.length && id !== 'security' ? `<p class="more-note">${escapeHtml(SYSTEMS[id].offline === 'none' ? 'Switched off' : 'Offline')}: ${escapeHtml(off.map((d) => d.name).join(', '))}</p>` : '';
  return head(sys.title, '', '', back) + top + tiles + devList + offNote;
}

/* Rooms and All devices are one destination with a switch: a room is
 * where a device lives, and the list is the same devices without the rooms. */
const roomsSwitch = (on) => `<div class="seg seg-nav" role="navigation" aria-label="Rooms or devices">` +
  `<a href="#/areas" aria-current="${on === 'areas' ? 'page' : 'false'}">Rooms</a>` +
  `<a href="#/devices" aria-current="${on === 'devices' ? 'page' : 'false'}">All devices</a></div>`;

function areasView(all) {
  const areas = groupByArea(all.filter(matches));
  const index = deviceSystems(all);
  return head('Rooms', '', '') + roomsSwitch('areas') +
    (areas.length ? `<div class="grid">${areas.map(([id, list]) => areaCard(id, list, index)).join('')}</div>` : noMatch());
}

/* A room: how many devices, and what is wrong. An AC or TV that is off at
 * the wall is "off", not an alarm; red is kept for real faults. */
function areaCard(id, list, index = new Map()) {
  const devices = byDevice(list);
  const { fault, off } = offlineSplit(devices, index);
  return `<a class="area-card" href="#/area/${encodeURIComponent(id)}">
    <div class="area-top"><span class="area-name">${escapeHtml(areaName(id))}</span>${arrow('i-chevron', 'area-arrow')}</div>
    <span class="area-count">${devices.length} ${plural(devices.length, 'device', 'devices')}` +
      `${fault ? ` · <span class="bad">${fault} offline</span>` : ''}${off ? ` · ${off} off` : ''}</span>
  </a>`;
}

function areaView(all, id) {
  const inArea = all.filter((e) => e.area === id);
  const list = inArea.filter(matches);
  const back = `<a class="back" href="#/areas">${arrow('i-back')}Rooms</a>`;
  // Not a room (an old #/area/unassigned bookmark, or a deleted area): say
  // nothing about what might have been there.
  if (!state.areas?.[id]) {
    return head('Area not found', '', '', back) +
      emptyBlock('No such area', 'It may have been removed or renamed in Home Assistant.');
  }
  if (!list.length) {
    // An area that is empty and an area whose contents the search hid are
    // different problems, and only one of them is the user's to fix.
    return inArea.length
      ? head(areaName(id), 'Nothing here matches that search.', '', back) + noMatch()
      : head(areaName(id), 'No devices here yet.', '', back) +
        emptyBlock('This area is empty', 'Nothing in Home Assistant is assigned to this area yet.');
  }
  const devices = byDevice(inArea);
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
  const split = offlineSplit(devices, deviceSystems(all));
  const sub = `${devices.length} ${plural(devices.length, 'device', 'devices')}` +
    (split.fault ? ` · ${split.fault} offline` : '') + (split.off ? ` · ${split.off} off` : '');

  return head(areaName(id), sub, '', back) +
    (canControl && !bridgeGate('control').ok ? controlNote() : '') +
    order.map((d) => {
      const items = byDomain.get(d).sort(byName);
      const title = cap(humanDomain(d));
      return `<section class="panel area-sec">` + panelHead(title, null, items.length) + (CONTROLLABLE.has(d)
        ? `<div class="dev-list${items.length > 8 ? ' cols' : ''}">${items.map((e) => deviceCard(e, 'area')).join('')}</div>`
        : `<div class="list${items.length > 8 ? ' cols' : ''}">${items.map((e) => row(e)).join('')}</div>`) +
        `</section>`;
    }).join('');
}

/* All devices is a list of devices, not of the hundreds of readings they
 * publish: a printer is one line with a status, and opens to show its 67
 * readings. Filters and search still work on readings; a device appears when
 * any of its readings match, and opens itself when a filter is doing the
 * choosing, so what matched is visible without a click. */
function devicesView(all) {
  const byStatus = (e) => statusFilter === 'all' ? true
    : statusFilter === 'active' ? !isBad(e) : isBad(e);
  const scoped = all.filter(byStatus);
  const list = scoped.filter((e) => matches(e) && (!domainFilter || e.domain === domainFilter)).sort(byName);
  const groups = byDevice(list).sort((a, b) => a.name.localeCompare(b.name, undefined, NATURAL));

  const counts = { all: byDevice(all).length, active: byDevice(all.filter((e) => !isBad(e))).length,
                   offline: byDevice(all.filter(isBad)).length };
  const seg = `<div class="seg" role="group" aria-label="Filter by status">` +
    [['all', 'All'], ['offline', 'Not reporting']].map(([k, label]) =>
      `<button data-act="status" data-status="${k}" aria-pressed="${statusFilter === k}">` +
      `${label}<span class="n">${counts[k]}</span></button>`).join('') + `</div>`;


  const filtering = !!(search || domainFilter || statusFilter === 'offline');
  const full = new Map(byDevice(all).map((d) => [d.id, d]));
  const body = groups.map((g) => {
    // No device id (an older bridge, or the synthetic fixture): a plain row.
    if (g.id === g.ents[0].key && !g.ents[0].device) return `<div class="list dgroup-solo">${row(g.ents[0], true)}</div>`;
    const whole = full.get(g.id) || g;
    const down = whole.ents.filter(isBad).length;
    const open = filtering || openDevices.has(g.id);
    const status = down === 0 ? `<span class="tag tag-on">All reporting</span>`
      : down === whole.ents.length ? `<span class="tag tag-bad">Offline</span>`
      : `<span class="tag tag-warn">${down} of ${whole.ents.length} down</span>`;
    return `<section class="dgroup${open ? ' open' : ''}">
      <button class="dgroup-head" data-act="dev-open" data-dev="${escapeHtml(g.id)}" aria-expanded="${open}">
        <span class="dgroup-main"><span class="dgroup-name">${escapeHtml(g.name)}</span>
          <span class="dgroup-meta">${escapeHtml(areaName(g.area))}</span></span>
        ${status}${arrow('i-chevron', 'dgroup-chev')}
      </button>
      ${open ? `<div class="dgroup-body">${g.ents.map((e) => row(e)).join('')}</div>` : ''}
    </section>`;
  }).join('');

  return head('Rooms', '', '') + roomsSwitch('devices') +
    `<div class="toolbar-row">${seg}</div>` +
    (groups.length ? `<div class="dgroups">${body}</div>` : noMatch());
}

/* ---- irrigation (vendor motor/valve mirror, read-only) ---- */

/* ---- irrigation reports (Mobitech DCON controller, on demand) ---- */

/* Nothing on this page is polled. Each report below answers a user pressing
 * Generate: the dashboard appends a request to
 * /farms/<farm>/irrigation_requests, a Cloud Function
 * (dashboard/functions) makes the one to three controller calls with
 * credentials held in Secret Manager, and writes the finished report to
 * /farms/<farm>/irrigation_reports. The NUC is not involved: reports work
 * while the bridge is offline. This page renders requests
 * and results and nothing else: it never sees a vendor credential and
 * cannot operate a pump. Valve/pump control is deliberately not built —
 * that is a security decision of the same order as cover/lock, not a config
 * tweak, and would arrive through the /commands queue, never as a direct
 * vendor call from a browser tab. */
const IRR_TYPES = [
  // Every report reads the same Mobitech DCON controller. The combined ones
  // answer a question that spans two of its endpoints — did the line hold
  // while the valves were open, did the motor stop mid-timer — which reading
  // two separate cards left you to work out by eye.
  { type: 'live_readings', label: 'Power and pressure now', needs: 'live', group: 'Combined' },
  { type: 'session_log', label: 'Irrigation session log', needs: 'range', group: 'Combined' },
  { type: 'performance', label: 'Valve runtime against pressure', needs: 'range', group: 'Combined' },
  { type: 'controller', label: 'Controller dashboard', needs: 'live', group: 'Single endpoint' },
  { type: 'electricity', label: 'Electricity snapshot', needs: 'live', group: 'Single endpoint' },
  { type: 'pressure', label: 'Pressure snapshot', needs: 'live', group: 'Single endpoint' },
  { type: 'valves', label: 'Valve runtime', needs: 'range', group: 'Single endpoint' },
  { type: 'timer_log', label: 'Timer log', needs: 'range', group: 'Single endpoint' },
  { type: 'motor_log', label: 'Motor log', needs: 'range', group: 'Single endpoint' },
  { type: 'pressure_range', label: 'Pressure range', needs: 'range', group: 'Single endpoint' },
  { type: 'pressure_hour', label: 'Pressure, last hour', needs: 'live', group: 'Single endpoint' },
  { type: 'power_range', label: 'Power over time', needs: 'range', group: 'Single endpoint' },
];
const IRR_TIMEOUT_MS = 60000;
// Builder selections survive re-renders (a sensor update mid-form must not
// wipe the dates), and one waiter per outstanding request resolves it.
let irrType = 'live_readings', irrFrom = '', irrTo = '';
const irrWaiters = new Map();   // reqKey -> { ref, cb, timer }

const irrig = () => state.irrigation || {};
const irrReports = () => Object.entries(state.irrigation_reports || {})
  .filter(([, r]) => r && typeof r === 'object')
  .sort((a, b) => (a[1].at || 0) - (b[1].at || 0));
/** The newest report of each kind and range, newest last: every Refresh
 *  writes three reports, and eighty identical cards buried the one asked for
 *  (found on the real farm, 2026-09-25). */
function latestReports() {
  const seen = new Map();
  for (const [k, r] of irrReports()) {
    const p = r.params || {};
    seen.set(`${r.type}|${p.from || ''}|${p.to || ''}`, [k, r]);
  }
  return [...seen.values()].sort((a, b) => (a[1].at || 0) - (b[1].at || 0)).slice(-12);
}

const irrNeedsRange = (t) => (IRR_TYPES.find((x) => x.type === t) || {}).needs === 'range';

function irrDefaultDates() {
  const today = new Date(), past = new Date(Date.now() - 2 * 864e5);
  const iso = (d) => d.toISOString().slice(0, 10);
  return { from: iso(past), to: iso(today) };
}

/* Will anything on the NUC act on this?
 *
 * Device control is gated on the bridge and published on every heartbeat as
 * meta/bridge.control (allow_control). The page used to ignore it, so a switched-off capability looked exactly like a
 * broken one: a light toggle flipped, wrote a command nothing was watching,
 * then snapped back 12 seconds later saying the farm had not responded. Three
 * turn_on commands for switch.car_shed_light_1 were found sitting unexecuted
 * in production on 2026-09-23.
 *
 * A bridge too old to publish a field leaves it undefined, which is not the
 * same as off; only an explicit false blocks. */
function bridgeGate(feature) {
  const hb = state.meta && state.meta.bridge;
  if (!hb || !hb.lastSeen) {
    return { ok: false, why: 'The bridge has not reported in yet, so nothing would act on that.' };
  }
  const ageSec = (Date.now() + clockSkewMs - hb.lastSeen) / 1000;
  if (hb.status === 'offline' || ageSec > (hb.heartbeatSeconds || 30) * STALE_FACTOR) {
    return { ok: false, why: 'The bridge is not reporting in, so nothing would act on that.' };
  }
  if (feature === 'control' && hb.control === false) {
    return { ok: false, why: 'Device control is switched off on the bridge. Turn on allow_control in the add-on options to operate anything from here.' };
  }
  return { ok: true, why: '' };
}

/* Reports do not go through the NUC (see above), so the bridge's heartbeat
 * says nothing about them. The only gate is the kill switch the function
 * itself reads, meta/reports.enabled, which only the service account can
 * set. Undefined is open, same as bridgeGate. */
function reportsGate() {
  if (state.meta?.reports?.enabled === false) {
    return { ok: false, why: 'Irrigation reports are switched off for now.' };
  }
  return { ok: true, why: '' };
}

function sendReportRequest() {
  if (!canControl) { toast('err', 'Your account can view, but not run reports.'); return; }
  const reachable = reportsGate();
  if (!reachable.ok) { toast('err', reachable.why); render(); return; }
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
      reportOpen.set(key, true);
      done(true);
      toast(rep.status === 'ok' ? 'ok' : 'err',
        rep.status === 'ok' ? 'Report ready.' : `Report failed: ${rep.error || 'vendor error'}`);
    }
  };
  const timer = setTimeout(() => done(false, 'No answer yet — it will appear below when the vendor responds.'), IRR_TIMEOUT_MS);
  irrWaiters.set(key, { ref: child, cb, timer });
  child.on('value', cb);
  ref.set(payload, (err) => {
    if (err) {
      done(false, err.code === 'PERMISSION_DENIED'
        ? 'The database refused that request.'
        : `Could not send: ${err.message}`);
    } else {
      toast('ok', 'Report requested — the farm controller is pulling it from the vendor now.');
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
    ${r.art ? artImg(r.art, 'bar-art') : '<span class="bar-art"></span>'}
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
    art: valveArt(r.name, r.type, r.status),
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
    r.name || 'Motor', r.meta || '', irrigStatusTag(r.status),
    valveArt(r.name, r.type || r.meta, r.status))).join('');
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
    art: valveArt(r.name, r.type, r.status),
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
    const art = timelineArt(r.source);
    const source = (art ? artImg(art, 'tl-art') : '') + (r.source
      ? `<span class="tl-chip">${escapeHtml(r.source)}</span>` : '');
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

/* ---- multi-value kinds: lines, stack, grid, matrix ----
 * Rows stay flat {key: value}; the section's `legend` says which keys to
 * draw and what to call them. A key missing from a row is a gap — a supply
 * cut, a pump that was off — and the line breaks there instead of joining
 * across it. Series are told apart by weight and dash, not by a rainbow:
 * the first is the accent, the others are the page's own greys. */

const irrLegend = (sec) => (Array.isArray(sec.legend) ? sec.legend : [])
  .filter((l) => l && l.key);
const num = (v) => (typeof v === 'number' ? v : parseReading(v));
const fmtNum = (v) => (Math.abs(v) >= 100 ? Math.round(v) : Math.round(v * 10) / 10);
const legendChips = (legend, cls) => `<div class="chart-legend">` + legend.map((l, i) =>
  `<span class="lg"><i class="${cls}-${i}"></i>${escapeHtml(l.label || l.key)}</span>`).join('') + `</div>`;

function irrLines(rows, sec) {
  const legend = irrLegend(sec).slice(0, 4);
  const unit = sec.unit || '';
  const vals = rows.flatMap((r) => legend.map((l) => num(r[l.key]))).filter((v) => v != null);
  if (rows.length < 2 || !vals.length) return '';
  const W = 600, H = 150, L = 34, R = 6, T = 6, B = 20;
  let lo = Math.min(...vals), hi = Math.max(...vals);
  const pad = (hi - lo) * 0.08 || 1;
  lo = Math.max(0, lo - pad); hi += pad;
  const x = (i) => L + (i / (rows.length - 1)) * (W - L - R);
  const y = (v) => T + (1 - (v - lo) / (hi - lo)) * (H - T - B);
  const step = (W - L - R) / (rows.length - 1);
  const shade = rows.map((r, i) => (r.on == 1 || r.on === true)
    ? `<rect x="${(x(i) - step / 2).toFixed(1)}" y="${T}" width="${step.toFixed(1)}" height="${H - T - B}" class="ln-on"/>` : '').join('');
  const paths = legend.map((l, k) => {
    let d = '', open = false;
    rows.forEach((r, i) => {
      const v = num(r[l.key]);
      if (v == null) { open = false; return; }
      d += `${open ? 'L' : 'M'}${x(i).toFixed(1)},${y(v).toFixed(1)}`;
      open = true;
    });
    return `<path d="${d}" class="ln ln-${k}"/>`;
  }).join('');
  // Labels are HTML placed by percentage, not SVG text: the SVG stretches to
  // the card, and text inside it would shrink to nothing on a phone.
  const pct = (v, of) => (v / of * 100).toFixed(2);
  const ticks = [lo, (lo + hi) / 2, hi].map((v) =>
    `<line x1="${L}" x2="${W - R}" y1="${y(v).toFixed(1)}" y2="${y(v).toFixed(1)}" class="ln-grid"/>`).join('');
  const yLabels = [lo, (lo + hi) / 2, hi].map((v) =>
    `<span class="ln-ax ln-ay" style="top:${(y(v) / H * 150).toFixed(1)}px">${fmtNum(v)}</span>`).join('');
  const when = (r) => String(r.at || '').slice(rows[0].at?.slice(0, 10) === rows[rows.length - 1].at?.slice(0, 10) ? 11 : 5, 16);
  const xs = [0, Math.floor((rows.length - 1) / 2), rows.length - 1].map((i, j) =>
    `<span class="ln-ax ln-ax-${['s', 'm', 'e'][j]}" style="left:${pct(x(i), W)}%">${escapeHtml(when(rows[i]))}</span>`).join('');
  // One invisible column per point carries the hover: every series at that time.
  const hover = rows.map((r, i) => `<rect x="${(x(i) - step / 2).toFixed(1)}" y="${T}" width="${step.toFixed(1)}" height="${H - T - B}" class="ln-hit">` +
    `<title>${escapeHtml([r.at, ...legend.map((l) => num(r[l.key]) == null ? `${l.label}: —` : `${l.label}: ${fmtNum(num(r[l.key]))}${unit ? ' ' + unit : ''}`)].join('\n'))}</title></rect>`).join('');
  return `<div class="chart">
    <div class="chart-plot">
      <svg viewBox="0 0 ${W} ${H}" preserveAspectRatio="none" class="chart-svg" role="img" aria-label="${escapeHtml(sec.title || 'chart')}">
        ${shade}${ticks}${paths}${hover}
      </svg>${yLabels}<div class="ln-xs">${xs}</div>
    </div>
    ${legendChips(legend, 'ln').replace('</div>', unit ? `<span class="lg lg-note">in ${escapeHtml(unit)}</span></div>` : '</div>')}
  </div>`;
}

function irrStack(rows, sec) {
  const [whole, part] = irrLegend(sec);
  if (!whole || !part || !rows.length) return '';
  const unit = sec.unit || '';
  const max = Math.max(...rows.map((r) => num(r[whole.key]) || 0), 1);
  const cols = rows.map((r) => {
    const t = num(r[whole.key]) || 0, p = Math.min(num(r[part.key]) || 0, t || Infinity);
    const tip = `${r.at}: ${part.label} ${fmtNum(p)} ${unit} of ${fmtNum(t)} ${unit} ${whole.label.toLowerCase()}`;
    return `<div class="stk-col" title="${escapeHtml(tip)}">
      <span class="stk-whole" style="height:${(t / max * 100).toFixed(1)}%">
        <span class="stk-part" style="height:${t ? (p / t * 100).toFixed(1) : 0}%"></span></span>
      <span class="stk-at">${escapeHtml(String(r.at || '').slice(8, 10))}</span>
    </div>`;
  }).join('');
  return `<div class="chart"><div class="stk" role="img" aria-label="${escapeHtml(sec.title || '')}">${cols}</div>` +
    `<div class="chart-legend"><span class="lg"><i class="stk-k-whole"></i>${escapeHtml(whole.label)}</span>` +
    `<span class="lg"><i class="stk-k-part"></i>${escapeHtml(part.label)}</span>` +
    `<span class="lg lg-note">max ${fmtNum(max)} ${escapeHtml(unit)}</span></div></div>`;
}

function irrGrid(rows) {
  const cells = rows.map((r) => {
    const m = Number(r.value) || 0, art = valveArt(r.name, r.type, m ? 'on' : 'off');
    return `<div class="vg${m ? '' : ' vg-idle'}">
      ${art ? artImg(art, 'vg-art') : '<span class="vg-art"></span>'}
      <span class="vg-name">${escapeHtml(r.name || 'Valve')}</span>
      <span class="vg-val">${m ? escapeHtml(fmtMinutes(m)) : 'none'}</span>
    </div>`;
  }).join('');
  return cells ? `<div class="vgrid">${cells}</div>` : '';
}

function irrMatrix(rows, sec) {
  const cols = irrLegend(sec);
  if (!cols.length || !rows.length) return '';
  const max = Math.max(1, ...rows.flatMap((r) => cols.map((c) => Number(r[c.key]) || 0)));
  const head = `<tr><th class="mx-name">Valve</th>` +
    cols.map((c) => `<th>${escapeHtml(c.label)}</th>`).join('') + `<th class="mx-total">Total</th></tr>`;
  const body = rows.map((r) => `<tr><th class="mx-name">${escapeHtml(r.name || '')}</th>` +
    cols.map((c) => {
      const m = Number(r[c.key]) || 0;
      return m ? `<td style="--heat:${(0.10 + 0.55 * m / max).toFixed(2)}" title="${escapeHtml(`${r.name} · ${c.label}: ${fmtMinutes(m)}`)}">${escapeHtml(fmtMinutes(m))}</td>`
        : `<td class="mx-zero">–</td>`;
    }).join('') + `<td class="mx-total">${escapeHtml(fmtMinutes(Number(r.total) || 0))}</td></tr>`).join('');
  return `<div class="mx-wrap"><table class="mx">${head}${body}</table></div>`;
}

const IRR_SECTION_DRAW = {
  metrics: irrMetrics, status: irrStatusRows, series: irrSeries,
  bars: irrBars, timeline: irrTimeline, facts: irrFacts,
  lines: irrLines, stack: irrStack, grid: irrGrid, matrix: irrMatrix,
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

function irrReportCard(key, rep, open = true) {
  const label = rep.label || rep.type || 'Report';
  const when = rep.at ? new Date(rep.at).toLocaleString('en-GB',
    { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '';
  const from = rep.params && rep.params.from, to = rep.params && rep.params.to;
  const params = from && to && from === to ? from : [from, to].filter(Boolean).join(' → ');
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
  // The function appends the date range to the summary; the header already
  // shows it, so it is not said twice. Mirrors ReportListRow on iOS.
  let summary = rep.summary || '';
  if (params) for (const r of [params, from && to ? `${from} → ${to}` : null].filter(Boolean)) {
    if (summary.endsWith(' · ' + r)) summary = summary.slice(0, -(r.length + 3));
    else if (summary === r) summary = '';
  }
  // The header is the toggle; closed, a card is one line plus its summary.
  // The body stays in the page, hidden, so nothing re-lays-out on open.
  return `<section class="rep-card${open ? ' open' : ''}" data-rep="${escapeHtml(key)}">
    <button class="rep-head" data-act="rep-open" data-rep="${escapeHtml(key)}" aria-expanded="${open}">
      <span class="rep-title">${escapeHtml(label)}</span>${statusTag}
      <span class="rep-when">${escapeHtml([params, when].filter(Boolean).join(' · '))}</span>
      <svg viewBox="0 0 24 24" class="ico rep-chev" aria-hidden="true"><use href="#i-chevron"/></svg>
    </button>
    ${summary ? `<p class="rep-summary">${escapeHtml(summary)}</p>` : ''}
    ${rep.status === 'error' && rep.error ? `<p class="rep-summary rep-err">${escapeHtml(rep.error)}</p>` : ''}
    <div class="rep-body"${open ? '' : ' hidden'}>${body}</div>
  </section>`;
}

/* The sidebar badge. It counted running motors until the Livesky and Niagara
 * feeds were removed; open valves is the equivalent "something is on right
 * now" number from the one controller that is left. */
function irrigRunning() {
  return (irrig().valves || []).filter((v) => v && v.status === 'on').length;
}

const irrigStatusTag = (s) =>
  s === 'on' ? `<span class="tag tag-on">Running</span>`
  : s === 'off' ? `<span class="tag">Off</span>`
  : `<span class="tag">Unknown</span>`;

/* Which farm illustration (the DCON design assets, /art/<key>.png) goes with
 * a valve. The controller names valves "<number> <word>" — "4 Veg",
 * "6 Kulam", "13 Gova 1" — and the word is what the valve waters. Anything
 * unrecognised gets null and keeps the plain icon: a wrong crop on a valve is
 * worse than none. Mirrors ValveArt.swift in ios/SNOFCore; keep the tables in
 * step. */
const VALVE_ART_WORDS = {
  veg: 'veg', vegetable: 'veg', vegetables: 'veg', onion: 'onion', kulam: 'kulam',
  grass: 'grass', house: 'house', mulberry: 'mulberry', coco: 'coconut', coconut: 'coconut',
  gova: 'guava', guava: 'guava', mango: 'mango', amla: 'amla', jamun: 'jamun',
  pomegranate: 'pomegranate', pomegra: 'pomegranate', backwash: 'backwash',
};
function valveArt(name, type, status) {
  const t = String(type || '').toLowerCase();
  const tokens = String(name || '').toLowerCase().split(/[^a-z]+/).filter(Boolean);
  // A pump is a motor whatever it is called; its picture shows on/off.
  if (t.includes('pump') || tokens.some((w) => w === 'bpump' || w === 'pump' || w === 'motor')) {
    return status === 'on' ? 'motor-on' : 'motor-off';
  }
  if (t.includes('backwash')) return 'backwash';
  for (const w of tokens) if (VALVE_ART_WORDS[w]) return VALVE_ART_WORDS[w];
  return null;
}
const timelineArt = (source) => ({ motor: 'motor-on', timer: 'timer' })[String(source || '').toLowerCase()] || null;
const artImg = (key, cls = 'row-art') => `<img class="${cls}" src="/art/${key}.png" alt="" width="28" height="28" loading="lazy">`;

const irrigRow = (icon, name, meta, right, art = null) =>
  `<div class="row">${art ? `<span class="row-icon row-icon-art">${artImg(art)}</span>`
    : `<span class="row-icon"><svg viewBox="0 0 24 24" class="ico ico-sm"><use href="#${icon}"/></svg></span>`}` +
  `<span class="row-main"><span class="row-name">${escapeHtml(name)}</span>` +
  `<span class="row-meta">${escapeHtml(meta)}</span></span>${right}</div>`;

/* ---- irrigation: the whole Mobitech DCON side, as modules ----
 *
 * One page for everything irrigation (owner, 2026-09-25: "the irrigation
 * tab should have everything, not just the reports"): what the controller is
 * doing now with Run / Stop, the valves, the last day's figures, the supply,
 * and the reports. The helpers are ports of SNOFCore's Irrigation (Overview.
 * swift) so web and iOS read the same cache the same way. Farm time is the
 * controller's offset (+05:30), never the browser's zone. */

const fmtMin = (m) => (m >= 60 ? (m % 60 ? `${Math.floor(m / 60)}h ${m % 60}m` : `${m / 60}h`) : `${m}m`);
function tzOffsetMin(tz) {
  const m = /^([+-])(\d{2}):?(\d{2})$/.exec(tz || '');
  return m ? (m[1] === '-' ? -1 : 1) * (Number(m[2]) * 60 + Number(m[3])) : 330;
}
const farmTz = () => tzOffsetMin(irrig().dcon?.timeZone);
/** "2026-09-23 20:32[:00]" in farm time -> epoch ms. */
function farmMs(s) {
  const m = /^(\d{4})-(\d{2})-(\d{2})[ T](\d{2}):(\d{2})/.exec(s || '');
  return m ? Date.UTC(+m[1], m[2] - 1, +m[3], +m[4], +m[5]) - farmTz() * 60000 : null;
}
const farmDay = (ms) => new Date(ms + farmTz() * 60000).toISOString().slice(0, 10);
function farmDayLabel(day) {
  const now = serverNow();
  if (day === farmDay(now)) return 'Today';
  if (day === farmDay(now - 864e5)) return 'Yesterday';
  const d = new Date(`${day}T00:00:00Z`);
  return Number.isNaN(d.getTime()) ? day : d.toLocaleDateString('en-GB', { day: 'numeric', month: 'short', timeZone: 'UTC' });
}
/** "20:32", "20:32 yesterday", "21 Sep 20:32". */
function farmWhen(s) {
  if (!s || s.length < 16) return '';
  const day = s.slice(0, 10), time = s.slice(11, 16), label = farmDayLabel(day);
  return label === 'Today' ? time : label === 'Yesterday' ? `${time} yesterday` : `${label} ${time}`;
}

/** One timerLog row -> a program run (reports.py run_row). */
function parseRun(r) {
  if (!r || (r.source && r.source !== 'timer') || !r.event || !r.at || r.at.length < 10) return null;
  const headParts = String(r.event).split(' · ');
  const kind = headParts.length > 1 ? headParts[0] : 'Program';
  const name = headParts.length > 1 ? headParts.slice(1).join(' · ') : r.event;
  const pieces = String(r.detail || '').split(' · ');
  let delivered = null, planned = null, finished = false;
  const first = pieces[0] || '';
  if (/, (finished|stopped)$/.test(first)) {
    finished = first.endsWith(', finished');
    const amount = first.split(',')[0];
    const parts = amount.split(' of ');
    if (parts.length === 2) { delivered = parseRuntimeMinutes(parts[0]); planned = parseRuntimeMinutes(parts[1]); }
    else { planned = parseRuntimeMinutes(amount); delivered = finished ? planned : null; }
    pieces.shift();
  }
  let valves = pieces[0] || '';
  const l = valves.toLowerCase();
  if (l.includes('backwash') || l.startsWith('started by') || l.startsWith('ended by') || valves === 'no valves') valves = '';
  return { kind, name, start: r.at, day: r.at.slice(0, 10), delivered, planned, finished, valves };
}
const runAmount = (x) => (x.planned == null ? (x.delivered != null ? fmtMin(x.delivered) : '')
  : x.finished ? fmtMin(x.planned) : `${fmtMin(x.delivered || 0)} of ${fmtMin(x.planned)}`);
const irrRuns = () => (irrig().timerLog || []).map(parseRun).filter(Boolean)
  .sort((a, b) => (a.start < b.start ? 1 : a.start > b.start ? -1 : 0));

/** "pump 16h 21m of 19h 42m with power · 77.89 kWh". */
function parsePumpDay(r) {
  if (!r || (r.source && r.source !== 'motor') || !r.at || !r.detail) return null;
  const m = /^pump (.+?) of (.+?) with power/.exec(r.detail);
  if (!m) return null;
  const kwh = String(r.detail).split(' · ').find((p) => p.endsWith(' kWh'));
  return { day: r.at.slice(0, 10), pumpMin: parseRuntimeMinutes(m[1]), supplyMin: parseRuntimeMinutes(m[2]),
           kwh: kwh ? parseFloat(kwh) : null };
}

/** The newest day the logs cover. */
function irrLatestDay() {
  const runs = irrRuns();
  const pumps = (irrig().motorLog || []).map(parsePumpDay).filter(Boolean).sort((a, b) => (a.day < b.day ? 1 : -1));
  const day = [runs[0]?.day, pumps[0]?.day].filter(Boolean).sort().at(-1);
  if (!day) return null;
  const dayRuns = runs.filter((r) => r.day === day);
  return { day, runs: dayRuns, pump: pumps.find((p) => p.day === day) || null,
           waterMin: dayRuns.reduce((s, r) => s + (r.delivered || 0), 0),
           stopped: dayRuns.filter((r) => !r.finished).length };
}

const triple = (s) => String(s || '').split('/').map((x) => parseFloat(x)).filter(Number.isFinite);
function irrSupply() {
  const rows = irrig().electricity || [];
  const volts = rows.find((r) => String(r.label || '').toLowerCase().includes('phase voltage'));
  const amps = rows.find((r) => String(r.label || '').toLowerCase().includes('current'));
  const v = triple(volts?.value), a = triple(amps?.value);
  if (!v.length && !a.length) return null;
  const note = [volts?.note, amps?.note].filter(Boolean).join(' ');
  const live = v.filter((x) => x >= 120).length;
  const imb = parseFloat((/([\d.]+)% imbalance/.exec(volts?.note || '') || [])[1]);
  return { v, a, at: (/\d{2}:\d{2}/.exec(note) || [''])[0], live, imbalance: Number.isFinite(imb) ? imb : null,
           missing: v.length === 3 && live > 0 && live < 3, drawing: a.length ? a.some((x) => x > 0.5) : null };
}
function irrPressure() {
  const last = (irrig().pressure || []).at(-1);
  return last && last.value ? { value: [last.value, last.unit].filter(Boolean).join(' '), at: last.at || '' } : null;
}

/** Valves a manual run may open: Irrigation ones only (the consumer checks
 *  again against the controller's own registry). */
function valveRows() {
  const c = irrig();
  return (c.valveNames && c.valveNames.length ? c.valveNames : c.valves || [])
    .filter((r) => r && r.id != null)
    .sort((a, b) => Number(a.id) - Number(b.id));
}
const isIrrigationValve = (r) => String(r.type || '').toLowerCase() === 'irrigation' && /^\d{1,2}$/.test(String(r.id));
const isManualProgram = (p) => !!p && (p.kind === 'Manual' || p.name === 'Manual Mode');

/** Watering now, or what ran last. Mirrors WaterNow on iOS. */
function irrNowState() {
  const c = irrig(), p = c.program;
  if (p && p.running && p.name) {
    const asOf = farmMs(p.lastSeen) ?? p.at ?? null;
    const elapsed = asOf ? Math.max(0, (serverNow() - asOf) / 60000) : 0;
    const left = p.remainingMin != null ? p.remainingMin - Math.round(elapsed) : null;
    if (left != null ? left > 0 : elapsed < 60) {
      const bits = [p.valves].filter(Boolean);
      if (left != null && p.plannedMin != null) bits.push(`${fmtMin(left)} left of ${fmtMin(p.plannedMin)}`);
      const since = farmWhen(p.start);
      if (since) bits.push(`since ${since}`);
      return { running: true, manual: isManualProgram(p), title: p.name, detail: bits.join(' · '),
               checked: p.at ? agoText(p.at) : '', valves: p.valves || '' };
    }
  }
  const last = irrRuns()[0];
  if (last) {
    const bits = [];
    const a = runAmount(last);
    if (a) bits.push(last.finished ? a : `${a}, stopped early`);
    if (last.valves) bits.push(last.valves);
    const w = farmWhen(last.start);
    if (w) bits.push(w);
    return { running: false, title: `Last: ${last.name}`, detail: bits.join(' · '), checked: p?.at ? agoText(p.at) : '' };
  }
  if (p && p.name) return { running: false, title: `Last: ${p.name}`, detail: p.valves || '', checked: p.at ? agoText(p.at) : '' };
  return { running: false, title: 'No runs logged yet', detail: '', checked: '' };
}

/* ---- valve control (admins) ----
 * The same path as the iOS app: append to irrigation_commands; the consumer
 * validates, takes irrigation_lock, sends, and re-reads the controller until
 * it shows the change. No second change until the first is confirmed
 * (owner, 2026-09-24): the rules refuse while the lock is live, and so does
 * this page. */
const IRR_MAX_VALVES = 5;
let irrPending = null, irrConfirming = false, irrPendingTimer = null;
let runOpen = false, runPick = [], runMinutes = 15;

function irrControlGate() {
  if (state.meta?.irrigationControl?.enabled === true) return { ok: true, why: '' };
  const hb = state.meta?.bridge;
  if (!hb || !hb.lastSeen) return { ok: false, why: 'Valve control has not checked in yet.' };
  const ageSec = (serverNow() - hb.lastSeen) / 1000;
  if (hb.status === 'offline' || ageSec > (hb.heartbeatSeconds || 30) * STALE_FACTOR) {
    return { ok: false, why: 'Valve control is not answering right now.' };
  }
  if (hb.irrigationControl !== true) return { ok: false, why: 'Valve control is switched off.' };
  return { ok: true, why: '' };
}
const irrLocked = () => (state.irrigationLock?.until || 0) > serverNow();
function irrRefusal() {
  if (!isAdmin) return 'Only farm admins can open or close valves.';
  const g = irrControlGate();
  if (!g.ok) return g.why;
  if (irrPending) return irrConfirming ? 'Confirming with the controller…' : 'Waiting for the farm…';
  if (irrLocked()) return 'The last change is still being confirmed.';
  return null;
}
function irrMaxMinutes() {
  const m = state.meta || {};
  const cap = m.irrigationControl?.enabled === true ? m.irrigationControl.maxMinutes
    : m.bridge?.irrigationControlStatus?.maxMinutes;
  return Math.min(60, Number(cap) || 60);
}

function sendIrrigation(cmd) {
  const why = irrRefusal();
  if (why) { toast('err', why); render(); return; }
  const ref = firebase.database().ref(`farms/${FARM}/irrigation_commands`).push();
  irrPending = ref.key; irrConfirming = false;
  clearTimeout(irrPendingTimer);
  // Sending plus the farm's 2-minute confirmation; the lock expires at 3.
  irrPendingTimer = setTimeout(() => {
    if (irrPending !== ref.key) return;
    irrPending = null; irrConfirming = false;
    toast('err', 'No answer from the farm. Check the controller before trying again.');
    render();
  }, 200000);
  ref.set({ ...cmd, uid: currentUser.uid, at: firebase.database.ServerValue.TIMESTAMP }, (err) => {
    if (!err) return;
    irrPending = null; clearTimeout(irrPendingTimer);
    toast('err', err.code === 'PERMISSION_DENIED' ? 'The database refused that.' : `Could not send: ${err.message}`);
    render();
  });
  render();
}

function settleIrrigation(results) {
  const node = irrPending && results ? results[irrPending] : null;
  if (!node) return;
  if (node.ok && node.confirming === true) { irrConfirming = true; return; }
  irrPending = null; irrConfirming = false; clearTimeout(irrPendingTimer);
  if (node.ok) {
    const what = node.action === 'stop' ? 'Stopped' : `Valves ${node.valves || ''} for ${node.minutes || '?'} min`;
    if (node.verified === false) toast('err', 'Sent, but not confirmed after 2 minutes. Check the controller.');
    else toast('ok', node.verified === true ? `Confirmed: ${what}.` : `Sent: ${what}.`);
    setTimeout(() => refreshIrrigation(true), 20000);
  } else {
    toast('err', node.message ? `Not sent: ${node.message}` : 'The farm refused that.');
  }
}

function runValves() {
  const ids = runPick.slice(0, IRR_MAX_VALVES);
  const mins = Math.min(irrMaxMinutes(), Math.max(1, runMinutes));
  if (!ids.length) { toast('err', 'Pick at least one valve.'); return; }
  const names = ids.map((id) => valveRows().find((r) => Number(r.id) === id)?.name || `Valve ${id}`);
  if (!window.confirm(`Water ${names.join(', ')} for ${fmtMin(mins)}?`)) return;
  runOpen = false; runPick = [];
  sendIrrigation({ action: 'run', valves: ids.join(','), minutes: mins });
}
function stopIrrigation() {
  if (!window.confirm('Stop the manual run? The controller closes the valves.')) return;
  sendIrrigation({ action: 'stop' });
}

/* ---- Refresh: three ordinary report requests ----
 * What the controller is doing now, power and pressure now, and yesterday-
 * and-today's runs. Each is a press, never a poll, so the rules, the kill
 * switch and the function's own checks apply unchanged. */
const irrRefreshing = new Set();
function refreshIrrigation(quiet = false) {
  if (!canControl) { if (!quiet) toast('err', 'Your account can view, but not refresh.'); return; }
  const g = reportsGate();
  if (!g.ok) { if (!quiet) toast('err', g.why); return; }
  if (irrRefreshing.size) return;
  // Three reads through the farm box per press: a second press within 45 s
  // of the last read adds load and nothing new (2026-09-24: 27 presses).
  const last = irrig().program?.at || irrig().meta?.lastUpdated || 0;
  if (serverNow() - last < 45000) { if (!quiet) toast('ok', `Just checked, ${agoText(last)}.`); return; }
  const now = serverNow(), today = farmDay(now), yesterday = farmDay(now - 864e5);
  const db = firebase.database();
  for (const [type, from, to] of [['controller'], ['live_readings'], ['session_log', yesterday, today]]) {
    const ref = db.ref(`farms/${FARM}/irrigation_requests`).push();
    const key = ref.key;
    irrRefreshing.add(key);
    const child = db.ref(`farms/${FARM}/irrigation_reports/${key}`);
    const finish = (err) => {
      if (!irrRefreshing.delete(key)) return;
      child.off('value', cb); clearTimeout(timer);
      if (err && !quiet) toast('err', err);
      if (!irrRefreshing.size && !quiet && !err) toast('ok', 'Irrigation updated.');
      render();
    };
    const cb = (snap) => { const rep = snap.val(); if (rep) finish(rep.status === 'error' ? `${rep.label || type} failed: ${rep.error || 'controller error'}` : null); };
    const timer = setTimeout(() => finish(null), IRR_TIMEOUT_MS);
    child.on('value', cb);
    const payload = { type, uid: currentUser.uid, at: firebase.database.ServerValue.TIMESTAMP };
    if (from) { payload.from = from; payload.to = to; }
    ref.set(payload, (err) => { if (err) finish(err.code === 'PERMISSION_DENIED' ? 'The database refused that.' : err.message); });
  }
  render();
}

/* Opening Home or Irrigation with controller data older than 15 minutes
 * fetches it again, at most once every 10 minutes per device, so nobody has
 * to press Refresh to trust what they see. Controllers only (viewers cannot
 * ask for reads); quiet unless it fails. */
let irrAutoAt = 0;
function autoRefreshIrrigation() {
  if (!canControl || !currentUser || document.hidden || irrRefreshing.size || !reportsGate().ok) return;
  const last = irrig().program?.at || irrig().meta?.lastUpdated || 0;
  const now = Date.now();
  if (serverNow() - last < 15 * 60000 || now - irrAutoAt < 10 * 60000) return;
  irrAutoAt = now;
  setTimeout(() => refreshIrrigation(true), 0);
}

/* ---- the modules ---- */

function irrNowModule() {
  const c = irrig();
  const s = irrNowState();
  const refusal = irrRefusal();
  const busy = irrRefreshing.size > 0;
  const refresh = canControl
    ? `<button class="btn btn-ghost btn-sm" data-act="irr-refresh"${busy || !reportsGate().ok ? ' disabled' : ''}>${busy ? 'Checking…' : 'Refresh'}</button>` : '';
  const empty = !c.program && !(c.timerLog || []).length;
  const faults = s.running ? (c.program?.faults || []) : [];
  const next = c.program?.next;
  const controls = isAdmin ? `<div class="now-actions">
      <button class="btn btn-primary" data-act="run-open"${refusal || runOpen || (s.running && s.manual) ? ' disabled' : ''}>Run valves</button>
      ${s.running && s.manual ? `<button class="btn btn-danger" data-act="irr-stop"${refusal ? ' disabled' : ''}>Stop</button>` : ''}
    </div>
    ${irrPending ? `<p class="more-note">${irrConfirming ? 'Confirming with the controller…' : 'Sent. Waiting for the farm…'}</p>`
      : refusal && refusal !== 'Only farm admins can open or close valves.' ? `<p class="more-note note-off">${escapeHtml(refusal)}</p>`
      : mobitechState().kind !== 'ok' ? `<p class="more-note note-off">${escapeHtml(mobitechState().text)}</p>` : ''}` : '';
  return `<section class="panel now${s.running ? ' is-on' : ''}" aria-label="Now">
    <div class="now-top">
      <p class="now-label"><span class="dot"></span>${s.running ? 'Watering now' : 'Not watering'}</p>
      ${s.checked ? `<span class="now-checked">checked ${escapeHtml(s.checked)}</span>` : ''}${refresh}
    </div>
    ${empty ? `<h2 class="now-title">No data yet</h2><p class="now-detail">${canControl ? 'Press Refresh to ask the controller.' : 'Nothing has been pulled yet.'}</p>`
      : `<h2 class="now-title">${escapeHtml(s.title)}</h2>${s.detail ? `<p class="now-detail">${escapeHtml(s.detail)}</p>` : ''}`}
    ${faults.map((f) => `<span class="tag tag-bad">${escapeHtml(f)}</span>`).join('')}
    ${next && next.name ? `<p class="now-next"><span>Next</span>${escapeHtml([next.name, next.plannedMin != null ? fmtMin(next.plannedMin) : ''].filter(Boolean).join(' · '))}</p>` : ''}
    ${controls}
  </section>`;
}

function irrValvesModule() {
  // Only while picking valves for a run: a standing list of valve names told
  // the owner nothing (2026-09-25). What each crop got is irrCropsModule.
  if (!(isAdmin && runOpen)) return '';
  const rows = valveRows();
  if (!rows.length) return '';
  const now = irrNowState();
  const openNames = new Set(now.running ? String(now.valves).split(/,\s*/).map((v) => v.trim().toLowerCase()) : []);
  const picking = isAdmin && runOpen;
  const cells = rows.map((r) => {
    const name = r.name || `Valve ${r.id}`;
    const art = valveArt(name, r.type, openNames.has(name.toLowerCase()) ? 'on' : 'off');
    const on = openNames.has(name.toLowerCase());
    const can = picking && isIrrigationValve(r);
    const picked = runPick.includes(Number(r.id));
    const inner = `${art ? artImg(art, 'vchip-art') : `<span class="vchip-art vchip-ico">${arrow('i-valve')}</span>`}` +
      `<span class="vchip-name">${escapeHtml(name)}</span>${on ? '<span class="vchip-dot" title="Open"></span>' : ''}`;
    return can
      ? `<button class="vchip is-pick${picked ? ' picked' : ''}" data-act="run-pick" data-valve="${escapeHtml(String(r.id))}" aria-pressed="${picked}"` +
        `${!picked && runPick.length >= IRR_MAX_VALVES ? ' disabled' : ''}>${inner}</button>`
      : `<span class="vchip${picking ? ' is-off' : ''}${on ? ' is-on' : ''}">${inner}</span>`;
  }).join('');
  const cap = irrMaxMinutes();
  const bar = picking ? `<div class="run-bar">
      <label class="rep-field"><span>For</span><select data-act="run-min">${[5, 10, 15, 20, 30, 45, 60].filter((m) => m <= cap)
        .map((m) => `<option value="${m}"${m === runMinutes ? ' selected' : ''}>${fmtMin(m)}</option>`).join('')}</select></label>
      <button class="btn btn-primary" data-act="run-go"${runPick.length ? '' : ' disabled'}>${runPick.length ? `Water ${runPick.length} ${plural(runPick.length, 'valve', 'valves')}` : 'Pick valves'}</button>
      <button class="btn btn-ghost" data-act="run-cancel">Cancel</button>
    </div>` : '';
  return `<section class="panel irr-mod" aria-label="Valves">` +
    panelHead(picking ? `Pick up to ${IRR_MAX_VALVES} valves` : 'Valves', null, rows.length) +
    `<div class="valve-grid">${cells}</div>${bar}</section>`;
}

/* ---- watered, by crop ----
 * What each crop got on one farm day, from the controller's own run log:
 * the useful form of "the valves" (owner, 2026-09-25: a plain valve list
 * "makes no use and sense"). Valves in one program run together, so a crop
 * got as long as its longest-watered valve. Display only. */
const CROP_LABELS = {
  veg: 'Vegetables', onion: 'Onion', kulam: 'Kulam', grass: 'Grass', house: 'House', mulberry: 'Mulberry',
  coconut: 'Coconut', guava: 'Guava', mango: 'Mango', amla: 'Amla', jamun: 'Jamun', pomegranate: 'Pomegranate',
};
let cropDayPick = null;   // 'today' | 'yesterday', once chosen by hand
const valveNo = (name) => { const m = /^(\d{1,2})\b/.exec(String(name || '').trim()); return m ? Number(m[1]) : null; };

function cropBreakdown(day) {
  const runs = irrRuns().filter((r) => r.day === day && r.valves);
  const valves = new Map();
  for (const r of runs) {
    for (const n of r.valves.split(/,\s*/).filter(Boolean)) {
      const v = valves.get(n) || { name: n, min: 0, cut: 0, runs: 0 };
      v.min += r.delivered || 0; v.runs += 1; if (!r.finished) v.cut += 1;
      valves.set(n, v);
    }
  }
  const crops = new Map();
  for (const v of valves.values()) {
    const art = valveArt(v.name, 'irrigation');
    const key = art && art !== 'backwash' ? art : `v:${v.name}`;
    const c = crops.get(key) || { key, art: art && art !== 'backwash' ? art : null,
      label: CROP_LABELS[art] || String(v.name).replace(/^\d+\s*/, '') || v.name, min: 0, cut: 0, valves: [] };
    // Valves of one crop share their runs: count runs, not valve-runs.
    c.min = Math.max(c.min, v.min); c.cut = Math.max(c.cut, v.cut); c.valves.push(v.name);
    crops.set(key, c);
  }
  const watered = new Set([...valves.keys()].map(valveNo).filter((n) => n != null));
  const dry = valveRows().filter((r) => isIrrigationValve(r) && !watered.has(Number(r.id))).map((r) => r.name);
  return { crops: [...crops.values()].sort((a, b) => b.min - a.min || a.label.localeCompare(b.label)), dry, runs };
}

function irrCropsModule() {
  const now = serverNow(), today = farmDay(now), yesterday = farmDay(now - 864e5);
  const hasToday = irrRuns().some((r) => r.day === today);
  const pick = cropDayPick || (hasToday ? 'today' : 'yesterday');
  const day = pick === 'today' ? today : yesterday;
  const { crops, dry, runs } = cropBreakdown(day);
  const pumps = (irrig().motorLog || []).map(parsePumpDay).filter(Boolean);
  const pump = pumps.find((p) => p.day === day);
  if (!irrRuns().length && !pumps.length) return '';
  const seg = `<div class="seg seg-sm" role="group" aria-label="Which day">` +
    [['today', 'Today'], ['yesterday', 'Yesterday']].map(([k, l]) =>
      `<button data-act="crop-day" data-day="${k}" aria-pressed="${pick === k}">${l}</button>`).join('') + `</div>`;
  const water = runs.reduce((s, r) => s + (r.delivered || 0), 0);
  const fig = (v, label) => `<div class="fig"><span class="fig-v">${v}</span><span class="fig-l">${label}</span></div>`;
  const max = Math.max(1, ...crops.map((c) => c.min));
  const rows = crops.map((c) => `<div class="crop-row${c.cut ? ' is-cut' : ''}">
      ${c.art ? artImg(c.art, 'crop-art') : `<span class="crop-art crop-ico">${arrow('i-valve')}</span>`}
      <span class="crop-main"><span class="crop-name">${escapeHtml(c.label)}</span>
        <span class="crop-valves">${escapeHtml(c.valves.join(', '))}${c.cut ? ` · ${c.cut} cut short` : ''}</span>
        <span class="crop-bar"><i style="width:${(c.min / max * 100).toFixed(1)}%"></i></span></span>
      <span class="crop-min">${escapeHtml(fmtMin(c.min))}</span></div>`).join('');
  return `<section class="panel irr-mod watered" aria-label="Watered">
    <div class="panel-head"><h2 class="panel-title">Watered</h2>${seg}</div>
    <div class="figs">${fig(runs.length, plural(runs.length, 'Run', 'Runs'))}${fig(fmtMin(water), 'Water')}` +
    (pump ? fig(fmtMin(pump.pumpMin), 'Pump') : '') + (pump?.kwh != null ? fig(`${Math.round(pump.kwh)}<small>kWh</small>`, 'Energy') : '') + `</div>` +
    (crops.length ? `<div class="crop-list">${rows}</div>` : `<p class="more-note crop-empty">Nothing watered ${pick === 'today' ? 'yet today' : 'yesterday'}.</p>`) +
    (dry.length && crops.length ? `<p class="more-note crop-dry">Not watered: ${escapeHtml(dry.join(', '))}</p>` : '') +
    `</section>`;
}

function irrDayModule() {
  const d = irrLatestDay();
  if (!d) return '';
  const fig = (v, label) => `<div class="fig"><span class="fig-v">${v}</span><span class="fig-l">${label}</span></div>`;
  const runs = irrRuns().slice(0, 4);
  return `<section class="panel irr-mod" aria-label="${escapeHtml(farmDayLabel(d.day))}">` +
    panelHead(farmDayLabel(d.day)) +
    `<div class="figs">${fig(d.runs.length, 'Runs')}${fig(fmtMin(d.waterMin), 'Water')}` +
    (d.pump ? fig(fmtMin(d.pump.pumpMin), 'Pump') : '') +
    (d.pump?.kwh != null ? fig(`${Math.round(d.pump.kwh)}<small>kWh</small>`, 'Energy') : '') + `</div>` +
    (runs.length ? `<div class="list">${runs.map((r) => `<div class="row run-row">
        <span class="run-time">${escapeHtml(r.start.slice(11, 16))}</span>
        <span class="row-main"><span class="row-name">${escapeHtml(r.name)}</span>
          ${r.valves ? `<span class="row-meta">${escapeHtml(r.valves)}</span>` : ''}</span>
        <span class="run-amt${r.finished ? '' : ' warn'}">${escapeHtml(runAmount(r))}</span></div>`).join('')}</div>` : '') +
    `</section>`;
}

function irrSupplyModule() {
  const s = irrSupply(), p = irrPressure();
  if (!s && !p) return '';
  // Three phases as three bars against a 0–300 V scale; a phase that is out
  // of the 200–260 V band, or missing, reads in warning colours.
  const bars = s && s.v.length ? `<div class="phases" role="img" aria-label="Phase voltages ${s.v.map(Math.round).join(', ')} volts">` +
    s.v.map((x, i) => `<div class="phase${x < 120 ? ' dead' : x < 200 || x > 260 ? ' warn' : ''}"><span class="phase-bar"><i style="height:${Math.min(100, x / 300 * 100).toFixed(1)}%"></i></span>` +
      `<strong>${Math.round(x)}</strong><small>L${i + 1}</small></div>`).join('') + `</div>` : '';
  const tags = [];
  if (s && s.v.length) {
    if (!s.live) tags.push(`<span class="tag tag-bad">No power</span>`);
    else if (s.missing) tags.push(`<span class="tag tag-bad">Phase missing · ${s.live} of 3 live</span>`);
    else if (s.imbalance != null && s.imbalance >= 5) tags.push(`<span class="tag tag-warn">${s.imbalance}% phase imbalance</span>`);
    else tags.push(`<span class="tag tag-on">All three phases</span>`);
  }
  if (s && s.drawing != null) tags.push(`<span class="tag${s.drawing ? ' tag-on' : ''}">${s.drawing ? `Pump running · ${s.a.map((x) => x.toFixed(1)).join(' / ')} A` : 'Pump off'}</span>`);
  const last = (irrig().pressure || []).at(-1);
  const outlet = last && /outlet ([\d.]+ ?bar)/.exec(last.detail || '');
  return `<section class="panel irr-mod" aria-label="Pump and power">` +
    `<div class="panel-head"><h2 class="panel-title">Pump &amp; power</h2>${s && s.at ? `<span class="card-age">at ${escapeHtml(s.at)}</span>` : ''}</div>` +
    `<div class="supply">${bars}${p ? `<div class="pressure"><span class="fig-v">${escapeHtml(p.value)}</span><span class="fig-l">Inlet pressure</span>` +
      (outlet ? `<span class="pressure-out">outlet ${escapeHtml(outlet[1])}</span>` : '') + `</div>` : ''}</div>` +
    (tags.length ? `<div class="tags">${tags.join('')}</div>` : '') + `</section>`;
}

function irrReportsModule() {
  const reports = latestReports();
  const reachable = reportsGate();
  const pending = irrWaiters.size;
  const groups = [...new Set(IRR_TYPES.map((t) => t.group))];
  const options = groups.map((g) => `<optgroup label="${escapeHtml(g)}">` + IRR_TYPES.filter((t) => t.group === g)
    .map((t) => `<option value="${t.type}"${irrType === t.type ? ' selected' : ''}>${escapeHtml(t.label)}</option>`).join('') + `</optgroup>`).join('');
  const def = irrDefaultDates();
  if (!irrFrom) irrFrom = def.from;
  if (!irrTo) irrTo = def.to;
  const range = irrNeedsRange(irrType);
  const builder = canControl && irrBuilderOpen ? `<div class="rep-builder">
      <label class="rep-field"><span>Report</span><select id="irr-type" data-act="irr-type">${options}</select></label>
      <label class="rep-field"${range ? '' : ' hidden'}><span>From</span><input id="irr-from" type="date" value="${escapeHtml(irrFrom)}" data-act="irr-from" max="${escapeHtml(def.to)}"></label>
      <label class="rep-field"${range ? '' : ' hidden'}><span>To</span><input id="irr-to" type="date" value="${escapeHtml(irrTo)}" data-act="irr-to" max="${escapeHtml(def.to)}"></label>
      <button class="btn btn-primary" data-act="irr-gen"${pending || !reachable.ok ? ' disabled' : ''}>${pending ? 'Working…' : 'Generate'}</button>
    </div>${reachable.ok ? '' : `<p class="more-note note-off">${escapeHtml(reachable.why)}</p>`}` : '';
  const toggle = canControl ? ['#', irrBuilderOpen ? 'Close' : 'New report', 'data-act="irr-builder"'] : null;
  return `<section class="irr-reports" aria-label="Reports">` +
    `<div class="panel-head bare"><h2 class="panel-title">Reports<span class="n">${reports.length || ''}</span></h2>` +
    (toggle ? `<a class="panel-link" href="#" ${toggle[2]}>${escapeHtml(toggle[1])}</a>` : '') + `</div>` +
    builder +
    (reports.length
      ? reports.slice().reverse().map(([k, r]) => irrReportCard(k, r, reportOpen.get(k) === true)).join('')
      : `<p class="more-note">No reports yet.</p>`) +
    `</section>`;
}
let irrBuilderOpen = false;

function irrigationView() {
  // Admins find the Mobitech account where it matters: folded away unless
  // it needs them, or they are part-way through signing in.
  const mb = isAdmin ? mobitechState() : { kind: 'ok' };
  const account = isAdmin
    ? `<details class="acct-sec"${mb.kind !== 'ok' || mbStep !== 'idle' ? ' open' : ''}><summary>Mobitech account</summary>${mobitechPanel()}</details>` : '';
  return head('Irrigation', '', '') +
    `<div class="irr-grid"><div class="irr-col">${irrNowModule()}${irrValvesModule()}${irrSupplyModule()}</div>` +
    `<div class="irr-col">${irrCropsModule()}</div></div>` +
    irrReportsModule() + account;
}

/* ---- water: river -> other farm -> main farm ----
 *
 * One chain, three vendors (docs/water.md). The river motor (Livesky) pumps
 * to the other farm, where two Niagara controllers run a 7.5 HP motor that
 * sends water on to the main farm and a zoned motor for that farm's own
 * drip lines; the main farm's valves are Mobitech DCON (the Irrigation page).
 * Read-only. The water functions read both vendors into farms/<farm>/water
 * every 10 minutes, and at most every 15 s while this page is open: it asks
 * by appending to water_requests (the function deletes each one). Nothing
 * here can switch a motor. */
const WATER_ASK_MS = 30000;
let waterTimer = null;
let waterAsked = 0;

/* Off unless the service account has set meta/water.enabled: a new
 * capability starts switched off, unlike reports (undefined = open). */
function waterGate() {
  if (state.meta?.water?.enabled !== true) {
    return { ok: false, why: 'Water readings are switched off for now.' };
  }
  return { ok: true, why: '' };
}

function requestWater(force = false) {
  if (!currentUser || document.hidden || !waterGate().ok) return;
  const now = Date.now();
  if (!force && now - waterAsked < WATER_ASK_MS - 2000) return;
  if (force && now - waterAsked < 5000) return;
  waterAsked = now;
  // A background refresh must never take the view down with it: this runs
  // inside render(), so anything it throws would stop the page updating.
  try {
    Promise.resolve(firebase.database().ref(`farms/${FARM}/water_requests`).push({
      uid: currentUser.uid, at: firebase.database.ServerValue.TIMESTAMP,
    })).catch(() => {});
  } catch (err) { console.warn('water refresh not sent', err); }
}

/* Poll only while the Water page is on screen and the tab is visible. */
function syncWaterPolling(active) {
  if (active && !waterTimer) {
    requestWater();
    waterTimer = setInterval(() => requestWater(), WATER_ASK_MS);
  } else if (!active && waterTimer) {
    clearInterval(waterTimer);
    waterTimer = null;
  }
}
document.addEventListener('visibilitychange', () => { if (waterTimer && !document.hidden) requestWater(); });

const serverNow = () => Date.now() + clockSkewMs;
/** "3 min ago" from an ISO stamp or epoch ms; '' when unknown. */
function agoText(when) {
  const t = typeof when === 'number' ? when : Date.parse(when || '');
  if (!Number.isFinite(t)) return '';
  const sec = Math.max(0, (serverNow() - t) / 1000);
  return sec < 45 ? 'just now' : `${humanAge(sec)} ago`;
}
const hm = (min) => (min == null ? '' : min < 60 ? `${min} min` : `${Math.floor(min / 60)} h ${pad2(min % 60)} min`);
const hms = (v) => String(v || '').replace(/^00:/, '').replace(/^0(\d:)/, '$1');
const joinNums = (list, unit) => (Array.isArray(list) && list.length ? `${list.join(' · ')} ${unit}` : '');

const WATER_ROLE = {
  'main-farm': 'Sends water to the main farm',
  drip: "Runs this farm's own drip zones",
};

function motorStateTag(m) {
  if (m.running === true) return `<span class="tag tag-on">Running</span>`;
  if (m.running === false) return `<span class="tag">Off</span>`;
  return `<span class="tag">Unknown</span>`;
}

/* What is on its way: Livesky marks an unacknowledged change "-inprogress";
 * Niagara's `requested` is what its app last asked for, which differs from
 * the controller's own report until the motor follows (20-40 s). */
function motorPending(m) {
  if (m.vendor === 'livesky') return m.pending ? 'A change is on its way to the starter.' : '';
  if (m.requested == null || m.running == null || m.requested === m.running) return '';
  return m.requested ? 'Asked to start; the controller has not reported it running yet.'
    : 'Asked to stop; the controller has not reported it off yet.';
}

function waterMotorCard(m, vendorErr) {
  if (!m) return '';
  const facts = [];
  if (m.vendor === 'livesky') {
    if (m.running === true && m.runMinutes != null) facts.push(['Running for', hm(m.runMinutes)]);
    if (m.running === false && m.stopMinutes != null) facts.push(['Off for', hm(m.stopMinutes)]);
  }
  if (m.program) {
    facts.push(['Program', `${m.program}${m.zone != null ? ` · zone ${m.zone}` : ''}`]);
    if (m.zoneLeft) facts.push(['Zone time left', hms(m.zoneLeft)]);
  }
  const volts = joinNums(m.volts, 'V');
  if (volts) facts.push(['Voltage', volts]);
  const amps = joinNums(m.amps, 'A');
  if (amps && (m.running || (m.amps || []).some((a) => a > 0))) facts.push(['Current', amps]);
  if (m.pressureOut != null && m.running) facts.push(['Outlet pressure', String(m.pressureOut)]);
  facts.push(['Power', m.power ? (m.supply ? m.supply.toLowerCase().replace('phase', 'phase present') : 'present') : 'none reported']);
  if (m.autoStart != null) facts.push(['Auto-start on power return', m.autoStart ? 'on' : 'off']);
  if (m.vendor === 'livesky' && m.connected === false) facts.push(['Starter link', 'not connected']);
  // The headline is state and how long; the electrics fold away.
  const mainKeys = new Set(['Running for', 'Off for', 'Program', 'Zone time left']);
  const headline = facts.filter(([k]) => mainKeys.has(k));
  const details = facts.filter(([k]) => !mainKeys.has(k));

  const when = m.liveAt || m.reportedAt;
  const notes = [];
  const pend = motorPending(m);
  if (pend) notes.push(`<p class="more-note note-off">${escapeHtml(pend)}</p>`);
  if ((m.trips || []).length) notes.push(`<p class="more-note note-bad">Tripped: ${escapeHtml(m.trips.join(', '))}.</p>`);
  if (m.skippedZone != null) notes.push(`<p class="more-note note-bad">Zone ${m.skippedZone} was skipped: no valve feedback.</p>`);
  if (vendorErr) notes.push(`<p class="more-note note-off">${escapeHtml(vendorErr)}</p>`);
  const sub = [m.vendor === 'livesky' ? 'Livesky' : 'Niagara', WATER_ROLE[m.role] || m.group].filter(Boolean).join(' · ');
  return `<article class="panel wmotor${m.running ? ' is-on' : ''}">
    <div class="wmotor-head">
      <img class="wmotor-art" src="/art/${m.running ? 'motor-on' : 'motor-off'}.png" alt="" width="44" height="44">
      <div class="wmotor-title"><h3>${escapeHtml(m.name || 'Motor')}</h3><p>${escapeHtml(sub)}</p></div>
      ${motorStateTag(m)}
    </div>
    ${headline.length ? `<div class="mb-facts">${headline.map(([k, v]) => `<div><span>${escapeHtml(k)}</span><strong>${escapeHtml(v)}</strong></div>`).join('')}</div>` : ''}
    ${notes.join('')}
    <details class="wdetails"><summary>${when ? `Reported ${escapeHtml(agoText(when))}` : 'Details'}</summary>
      <div class="mb-facts">${details.map(([k, v]) => `<div><span>${escapeHtml(k)}</span><strong>${escapeHtml(v)}</strong></div>`).join('')}</div></details>
  </article>`;
}

const waterStage = (n, title, _lead, body) =>
  `<section class="wstage"><div class="wstage-head"><span class="wstage-n">${n}</span>` +
  `<div><h2 class="wstage-title">${escapeHtml(title)}</h2></div></div>` +
  `<div class="wstage-body">${body}</div></section>`;
const waterFlow = (text) => `<div class="wflow" aria-hidden="true"><span></span><em>${escapeHtml(text)}</em></div>`;

function waterView() {
  const gate = waterGate();
  const w = state.water || {};
  const st = state.meta?.water || {};
  const motors = Object.values(w.motors || {});
  const supply = motors.filter((m) => m.role === 'main-farm');
  const others = motors.filter((m) => m.role !== 'main-farm');
  const liveskyErr = st.livesky && st.livesky.ok === false ? st.livesky.error : '';
  const niagaraErr = st.niagara && st.niagara.ok === false ? st.niagara.error : '';
  const refresh = `<button class="btn btn-ghost btn-sm" data-act="water-refresh"${gate.ok ? '' : ' disabled'}>Refresh</button>`;

  const riverBody = w.river
    ? waterMotorCard(w.river, liveskyErr ? `${liveskyErr} Showing the last reading.` : '')
    : emptyBlock('No reading from the river motor', liveskyErr || 'It appears after the first pull.');
  const livesky = isAdmin ? liveskyState() : { kind: 'ok' };
  const riverNote = livesky.kind === 'ok' ? ''
    : `<p class="more-note note-off">${escapeHtml(livesky.text)}</p>`;

  const otherBody = motors.length
    ? `<div class="wmotors">${[...supply, ...others].map((m) => waterMotorCard(m)).join('')}</div>` +
      (niagaraErr ? `<p class="more-note note-off">${escapeHtml(niagaraErr)} Showing the last readings.</p>` : '')
    : emptyBlock('No reading from the other farm', niagaraErr || 'It appears after the first pull.');

  const dcon = (state.irrigation || {}).dcon || {};
  const mainBody = `<a class="panel wmain" href="#/irrigation">
      <img class="wmotor-art" src="/art/kulam.png" alt="" width="44" height="44">
      <div class="wmotor-title"><h3>${escapeHtml(dcon.device || 'Mobitech DCON')}</h3>
        <p>Mobitech DCON · valves and reports</p></div>${arrow()}</a>`;

  const account = isAdmin
    ? `<details class="acct-sec"${livesky.kind !== 'ok' || lsStep !== 'idle' ? ' open' : ''}><summary>Livesky account</summary>${liveskyPanel()}</details>` : '';
  return head('Water', '', refresh) +
    (gate.ok ? '' : `<p class="more-note note-off">${escapeHtml(gate.why)}</p>`) +
    `<div class="wchain">` +
    waterStage('1', 'River', 'The river motor pumps to the other farm.', riverNote + riverBody) +
    waterFlow('to the other farm') +
    waterStage('2', 'Other farm', 'Two motors on Niagara controllers.', otherBody) +
    waterFlow('7.5 HP motor to the main farm') +
    waterStage('3', 'Main farm', '', mainBody) +
    `</div>` + account;
}

/* ---- Livesky sign-in (admins) ----
 * The river motor's API takes a 24-hour token from an SMS code
 * (docs/livesky-app.md) and no refresh call was seen, so an admin signs in
 * again when it runs out. The water_session function makes the calls and
 * keeps the token in /private/livesky; this page only sends the number, the
 * code and the caller's Firebase ID token, and never sees the Livesky token. */
let lsStep = 'idle';     // idle | mobile | code
let lsMobile = '', lsCode = '', lsBusy = false, lsError = '', lsInfo = '';

async function waterSession(body) {
  const projectId = firebase.app().options.projectId;
  const idToken = await currentUser.getIdToken();
  const r = await fetch(`https://asia-southeast1-${projectId}.cloudfunctions.net/water_session`, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${idToken}` },
    body: JSON.stringify(body),
  });
  const j = await r.json().catch(() => null);
  if (!r.ok || !j || !j.ok) throw new Error((j && j.error) || `the function answered ${r.status}`);
  return j;
}

async function liveskySendCode() {
  const mobile = mobitechDigits(lsMobile);
  if (!/^\d{10}$/.test(mobile)) { lsError = 'Enter the 10-digit mobile number on the Livesky account.'; render(); return; }
  lsBusy = true; lsError = ''; lsInfo = ''; render();
  try {
    await waterSession({ action: 'send_code', mobile });
    lsStep = 'code'; lsCode = '';
    lsInfo = `Livesky sent a code to the number ending ${mobile.slice(-4)}.`;
  } catch (err) {
    lsError = `No code sent: ${err.message}`;
  }
  lsBusy = false; render();
}

async function liveskySignIn() {
  const code = String(lsCode || '').replace(/\D/g, '');
  if (!/^\d{4,8}$/.test(code)) { lsError = 'Enter the code from the SMS.'; render(); return; }
  lsBusy = true; lsError = ''; render();
  try {
    const j = await waterSession({ action: 'verify', mobile: mobitechDigits(lsMobile), code });
    lsStep = 'idle'; lsMobile = ''; lsCode = ''; lsInfo = '';
    toast('ok', `Signed in to Livesky${j.device ? ` (${j.device})` : ''} until ${mbWhen(j.expires)}.`);
  } catch (err) {
    lsError = `Not signed in: ${err.message}`;
  }
  lsBusy = false; render();
}

async function liveskySignOut() {
  lsBusy = true; render();
  try {
    await waterSession({ action: 'sign_out' });
    toast('ok', 'Signed SNOF out of Livesky. The river motor will not be read until someone signs in again.');
  } catch (err) {
    toast('err', `Could not sign out: ${err.message}`);
  }
  lsBusy = false; render();
}

/** SNOF's Livesky session in one line, for any page. */
function liveskyState() {
  const st = state.meta?.water?.livesky || {};
  if (!st.signedInAt && !st.expires) return { kind: 'none', text: 'SNOF is not signed in to Livesky, so the river motor cannot be read.' };
  if (st.expires && st.expires <= serverNow()) {
    return { kind: 'expired', text: `The Livesky session ended ${mbWhen(st.expires)}. Sign in again to read the river motor.` };
  }
  if (st.ok === false && st.error) return { kind: 'error', text: st.error };
  return { kind: 'ok', text: '' };
}

function liveskyPanel() {
  const st = state.meta?.water?.livesky || {};
  const s = liveskyState();
  const facts = st.signedInAt || st.expires ? `<div class="mb-facts">
      ${st.mobileLast4 ? `<div><span>Number</span><strong>ending ${escapeHtml(st.mobileLast4)}</strong></div>` : ''}
      ${st.signedInAt ? `<div><span>Since</span><strong>${escapeHtml(mbWhen(st.signedInAt))}</strong></div>` : ''}
      ${st.expires ? `<div><span>Session ends</span><strong>${escapeHtml(mbWhen(st.expires))}</strong></div>` : ''}
      <div><span>Last reading</span><strong>${st.at ? escapeHtml(mbWhen(st.at)) : 'none yet'}</strong></div>
    </div>` : '';
  const status = s.kind === 'ok' ? '' : `<p class="more-note note-off">${escapeHtml(s.text)}</p>`;
  let form;
  if (lsStep === 'mobile') {
    form = `<div class="rep-builder" data-key="livesky">
        <label class="rep-field"><span>Livesky mobile number</span>
          <input id="ls-mobile" type="tel" inputmode="numeric" autocomplete="tel-national" placeholder="10 digits"
                 value="${escapeHtml(lsMobile)}" data-act="ls-mobile"></label>
        <button class="btn btn-primary" data-act="ls-send"${lsBusy ? ' disabled' : ''}>${lsBusy ? 'Sending…' : 'Send code'}</button>
        <button class="btn btn-ghost" data-act="ls-cancel"${lsBusy ? ' disabled' : ''}>Cancel</button>
      </div>`;
  } else if (lsStep === 'code') {
    form = `<div class="rep-builder" data-key="livesky">
        <label class="rep-field"><span>Code from the SMS</span>
          <input id="ls-code" type="text" inputmode="numeric" autocomplete="one-time-code" placeholder="6 digits"
                 value="${escapeHtml(lsCode)}" data-act="ls-code"></label>
        <button class="btn btn-primary" data-act="ls-signin"${lsBusy ? ' disabled' : ''}>${lsBusy ? 'Signing in…' : 'Sign in'}</button>
        <button class="btn btn-ghost" data-act="ls-back"${lsBusy ? ' disabled' : ''}>Use another number</button>
      </div>`;
  } else {
    const signedIn = st.signedInAt || st.expires;
    form = `<div class="mb-actions">
        <button class="btn btn-primary" data-act="ls-start">${signedIn ? 'Sign in again' : 'Sign in to Livesky'}</button>
        ${signedIn ? `<button class="btn btn-ghost" data-act="ls-signout"${lsBusy ? ' disabled' : ''}>Sign SNOF out</button>` : ''}
      </div>`;
  }
  return `<section class="panel mb-panel">
      ${facts}${status}${form}
      ${lsInfo ? `<p class="more-note">${escapeHtml(lsInfo)}</p>` : ''}
      ${lsError ? `<p class="more-note note-off">${escapeHtml(lsError)}</p>` : ''}
    </section>`;
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

/* ---- Mobitech sign-in (admins) ----
 * Ground truth: docs/mobitech-app.md (the Mobitech iOS app, captured with
 * mitmproxy on 2026-09-24). Mobitech does not issue a credential. The app
 * *registers* a device token (its FCM push token + "@ios") against the user:
 *
 *   POST /v1/otp/     {"mobile":"91<10>"} as the whole form body -> {"message":"Success",…}
 *   POST /v1/http/    action=login&type=otp&otp&mobile&token=<t>@ios&product=DCON
 *                     &app_id=com.mobitech.drip -> {"state":"ok","id":"<t>@ios",…}
 *
 * Only two calls check that token: action=dashboard (form token_id) and
 * POST /v1/command/ (header authorization). So SNOF registers a token of its
 * own — a session of its own that the phone's sign-outs cannot end — and
 * proves it with a dashboard read (read-only) before storing it.
 *
 * The browser talks to Mobitech directly (it allows any origin; it refuses
 * Google Cloud). The token goes where no client can read it
 * (/private/mobitech); a non-secret line goes to farms/<farm>/mobitech_status,
 * where whatever sends the commands also records lastOk / lastRejected.
 * The number and the code are never stored. Unproven until first used:
 * whether Mobitech accepts a token that is not a real FCM token, and
 * whether it lets one user keep two sessions (the phone may be signed out). */
const MOBITECH = 'https://dcon.mobitechwireless.com';
let mbStep = 'idle';     // idle | mobile | code
let mbMobile = '', mbCode = '', mbBusy = false, mbError = '', mbInfo = '';
let mbToken = '';

/** A device token shaped like the Mobitech app's (an FCM registration token
 *  with "@ios"): 22 url-safe characters, ":APA91b", 134 more. */
function mobitechDeviceToken() {
  const abc = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
  const pick = (n) => Array.from(crypto.getRandomValues(new Uint8Array(n)), (b) => abc[b % 64]).join('');
  return `${pick(22)}:APA91b${pick(134)}@ios`;
}

const mobitechDigits = (v) => String(v || '').replace(/\D/g, '').replace(/^91(?=\d{10}$)/, '');
const mbForm = (fields) => ({ method: 'POST', headers: { 'content-type': 'application/x-www-form-urlencoded' },
  body: typeof fields === 'string' ? fields : new URLSearchParams(fields) });
async function mbJson(r) { const t = await r.text(); try { return JSON.parse(t); } catch { return null; } }

async function mobitechSendCode() {
  const mobile = mobitechDigits(mbMobile);
  if (!/^\d{10}$/.test(mobile)) { mbError = 'Enter the 10-digit mobile number on the Mobitech account.'; render(); return; }
  mbBusy = true; mbError = ''; mbInfo = ''; render();
  try {
    // Byte for byte what the app sends: a JSON object as the whole form body.
    const r = await fetch(`${MOBITECH}/v1/otp/`, mbForm(JSON.stringify({ mobile: `91${mobile}` })));
    const j = await mbJson(r);
    if (!r.ok || (j && j.message && j.message !== 'Success')) {
      throw new Error((j && j.message) || `Mobitech answered ${r.status}`);
    }
    mbStep = 'code'; mbCode = ''; mbToken = mobitechDeviceToken();
    mbInfo = `Mobitech sent a code to the number ending ${mobile.slice(-4)}.`;
  } catch (err) {
    mbError = `No code sent: ${err.message}`;
  }
  mbBusy = false; render();
}

async function mobitechSignIn() {
  const mobile = mobitechDigits(mbMobile);
  const otp = String(mbCode || '').replace(/\D/g, '');
  if (!/^\d{4,8}$/.test(otp)) { mbError = 'Enter the code from the SMS.'; render(); return; }
  mbBusy = true; mbError = ''; render();
  try {
    const sent = mbToken || mobitechDeviceToken();
    const r = await fetch(`${MOBITECH}/v1/http/?`, mbForm({ action: 'login', type: 'otp', otp, mobile,
      token: sent, product: 'DCON', app_id: 'com.mobitech.drip' }));
    const who = await mbJson(r);
    if (!r.ok || !who || who.state !== 'ok') {
      throw new Error((who && (who.msg || who.message || who.reason)) || 'the code was not accepted');
    }
    const token = String(who.id || sent);
    if (!token.endsWith('@ios')) throw new Error('Mobitech did not register a session');
    // Prove it: the dashboard is one of the two calls that check the token,
    // and a read changes nothing. A rejected token gets no controller back.
    const d = await mbJson(await fetch(`${MOBITECH}/v1/http/`,
      mbForm({ action: 'dashboard', p: 'app', token_id: token, product: 'DCON' })));
    const ok = d && typeof d === 'object' && Object.values(d).some((v) => v && typeof v === 'object' && !Array.isArray(v));
    if (!ok) throw new Error('Mobitech took the code but will not serve the controller to this session');
    const db = firebase.database();
    const at = firebase.database.ServerValue.TIMESTAMP;
    await db.ref('private/mobitech').set({ token, at, uid: currentUser.uid });
    await db.ref(`farms/${FARM}/mobitech_status`).set({ at, uid: currentUser.uid,
      name: String(who.name || '').slice(0, 64), user: String(who.uname || '').slice(0, 64),
      mobileLast4: mobile.slice(-4) });
    mbStep = 'idle'; mbMobile = ''; mbCode = ''; mbToken = ''; mbInfo = '';
    toast('ok', `Signed in to Mobitech as ${who.name || who.uname || 'the farm account'}. Valve commands use this session.`);
  } catch (err) {
    mbError = `Not signed in: ${err.message}`;
  }
  mbBusy = false; render();
}

/** Stop SNOF using its session. The Mobitech logout call needs the token,
 *  which no client can read, so the session stays registered at Mobitech
 *  but unused; signing in again replaces it. */
async function mobitechSignOut() {
  mbBusy = true; render();
  try {
    await firebase.database().ref('private/mobitech').remove();
    await firebase.database().ref(`farms/${FARM}/mobitech_status`).remove();
    toast('ok', 'Signed SNOF out of Mobitech. Valve commands are off until someone signs in again.');
  } catch (err) {
    toast('err', `Could not sign out: ${err.message}`);
  }
  mbBusy = false; render();
}

const mbWhen = (ms) => new Date(ms).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' });

/** What SNOF's Mobitech session is doing, in one line, for any page. */
function mobitechState() {
  const st = state.mobitechStatus || {};
  if (!st.at) return { kind: 'none', text: 'SNOF is not signed in to Mobitech, so valve commands cannot be sent.' };
  if (st.lastRejected && st.lastRejected > Math.max(st.at, st.lastOk || 0)) {
    return { kind: 'rejected', text: `Mobitech rejected SNOF's session at ${mbWhen(st.lastRejected)}. Sign in again to send valve commands.` };
  }
  return { kind: 'ok', text: '' };
}

function mobitechPanel() {
  const st = state.mobitechStatus || {};
  const m = mobitechState();
  const who = st.at ? `${escapeHtml(st.name || st.user || 'the farm account')}${st.user && st.name ? ` (${escapeHtml(st.user)})` : ''}` : '';
  const facts = st.at ? `<div class="mb-facts">
      <div><span>Signed in as</span><strong>${who}</strong></div>
      <div><span>Number</span><strong>ending ${escapeHtml(st.mobileLast4 || '····')}</strong></div>
      <div><span>Since</span><strong>${escapeHtml(mbWhen(st.at))}</strong></div>
      <div><span>Last command</span><strong>${st.lastOk ? `accepted ${escapeHtml(mbWhen(st.lastOk))}` : 'none yet'}</strong></div>
    </div>` : '';
  const status = m.kind === 'ok' ? '' : `<p class="more-note note-off">${escapeHtml(m.text)}</p>`;
  let form = '';
  if (mbStep === 'mobile') {
    form = `<div class="rep-builder" data-key="mobitech">
        <label class="rep-field"><span>Mobitech mobile number</span>
          <input id="mb-mobile" type="tel" inputmode="numeric" autocomplete="tel-national" placeholder="10 digits"
                 value="${escapeHtml(mbMobile)}" data-act="mb-mobile"></label>
        <button class="btn btn-primary" data-act="mb-send"${mbBusy ? ' disabled' : ''}>${mbBusy ? 'Sending…' : 'Send code'}</button>
        <button class="btn btn-ghost" data-act="mb-cancel"${mbBusy ? ' disabled' : ''}>Cancel</button>
      </div>
`;
  } else if (mbStep === 'code') {
    form = `<div class="rep-builder" data-key="mobitech">
        <label class="rep-field"><span>Code from the SMS</span>
          <input id="mb-code" type="text" inputmode="numeric" autocomplete="one-time-code" placeholder="6 digits"
                 value="${escapeHtml(mbCode)}" data-act="mb-code"></label>
        <button class="btn btn-primary" data-act="mb-signin"${mbBusy ? ' disabled' : ''}>${mbBusy ? 'Signing in…' : 'Sign in'}</button>
        <button class="btn btn-ghost" data-act="mb-back"${mbBusy ? ' disabled' : ''}>Use another number</button>
      </div>`;
  } else {
    form = `<div class="mb-actions">
        <button class="btn btn-primary" data-act="mb-start">${st.at ? 'Sign in again' : 'Sign in to Mobitech'}</button>
        ${st.at ? `<button class="btn btn-ghost" data-act="mb-signout"${mbBusy ? ' disabled' : ''}>Sign SNOF out</button>` : ''}
      </div>`;
  }
  return `<section class="panel mb-panel">
      ${facts}${status}${form}
      ${mbInfo ? `<p class="more-note">${escapeHtml(mbInfo)}</p>` : ''}
      ${mbError ? `<p class="more-note note-off">${escapeHtml(mbError)}</p>` : ''}
    </section>`;
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
  <p class="more-note">Access starts when they sign in with that Google account.</p>`;

  const rows = [
    ...inviteRows.map(([key, inv]) => inviteRow(key, inv)),
    ...peopleRows.map((r) => adminRow(r.uid, r.person)),
  ];
  const list = rows.length
    ? `<div class="list">${rows.join('')}</div>`
    : emptyBlock('No one yet', 'Add someone above — they do not need to have signed in first.');

  return head('Admin', '', '') +
    sectionHead('n-admin', 'Add a person') + addForm +
    sectionHead('n-admin', 'People') + list +
    `<p class="more-note">Admins are added from the command line: <code>npm run grant -- email --admin</code>.</p>`;
}

/* ---- pieces ---- */

/* One line, next to the controls it explains. Without it the toggles are just
 * greyed out with no reason given anywhere on the page. */
function controlNote() {
  if (!canControl) return '';
  const gate = bridgeGate('control');
  return gate.ok ? '' : `<p class="more-note note-off">${escapeHtml(gate.why)}</p>`;
}

/* One operable device as a row. `quick` (Overview) says where it is; `area`
 * (inside a room) already knows where, so it says what state it is in. */
function deviceCard(ent, mode = 'area') {
  const want = pending.get(ent.key)?.want;
  const on = want ? want === 'on' : isOn(ent);
  const bad = isBad(ent);
  const level = levelOf(ent);
  const cls = bad ? 'is-bad' : on ? 'is-on' : '';
  const canOperate = canControl && !bad && bridgeGate('control').ok;
  const name = ent.name || ent.entity_id;
  const lvl = level !== null && !bad && on ? ` · ${level}%` : '';
  // Inside a room the toggle already shows on or off; the words add what the
  // toggle cannot: for how long.
  const since = sinceText(ent);
  const meta = mode === 'quick'
    ? `${areaName(ent.area)}${lvl}`
    : bad ? `Not reporting${since ? ` for ${since}` : ''}`
      : `${on ? 'On' : 'Off'}${since ? ` for ${since}` : ''}${lvl}`;

  return `<div class="dev-card ${cls}" data-key="${escapeHtml(ent.key)}">
    <div class="dev-top">
      <span class="dev-text">
        <span class="dev-name" title="${escapeHtml(name)}">${escapeHtml(name)}</span>
        <span class="dev-meta">${escapeHtml(meta)}</span>
      </span>
      ${canControl
        ? `<button class="toggle${want ? ' busy' : ''}" role="switch" aria-checked="${on}" ` +
          `aria-label="${escapeHtml(name)}" data-act="toggle"${canOperate ? '' : ' disabled'}></button>`
        : `<span class="dev-state ${stateClass(ent)}">${escapeHtml(formatState(ent))}</span>`}
    </div>
    ${level !== null && canControl && mode === 'area' ? `<div class="ctl-row">
      <span class="ctl-label">${ent.domain === 'fan' ? 'Speed' : 'Bright'}</span>
      <input type="range" min="0" max="100" step="1" value="${level}" style="--fill:${level}%"
             aria-label="${escapeHtml(name)} level" data-act="level"${canOperate ? '' : ' disabled'}>
      <span class="ctl-val">${level}%</span>
    </div>` : ''}
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

  view.querySelectorAll('[data-act="rep-open"]').forEach((btn) => {
    btn.onclick = () => {
      reportOpen.set(btn.dataset.rep, btn.getAttribute('aria-expanded') !== 'true');
      render();
    };
  });

  view.querySelectorAll('[data-act="dev-open"]').forEach((btn) => {
    btn.onclick = () => {
      const id = btn.dataset.dev;
      if (openDevices.has(id)) openDevices.delete(id); else openDevices.add(id);
      render();
    };
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
  // Mobitech sign-in. Typing holds live rebuilds (as a slider drag does), so
  // a half-typed number or code is never wiped by a sensor update.
  view.querySelectorAll('[data-act="mb-mobile"],[data-act="mb-code"]').forEach((input) => {
    input.onfocus = beginInteract;
    // Released a beat later: a click on "Send code" blurs the field first,
    // and an immediate rebuild would swap the button out from under it.
    input.onblur = () => setTimeout(endInteract, 300);
    input.oninput = () => { if (input.dataset.act === 'mb-mobile') mbMobile = input.value; else mbCode = input.value; };
    input.onkeydown = (e) => { if (e.key === 'Enter') { input.blur(); (input.dataset.act === 'mb-mobile' ? mobitechSendCode : mobitechSignIn)(); } };
  });
  view.querySelectorAll('[data-act="mb-send"]').forEach((btn) => { btn.onclick = () => mobitechSendCode(); });
  view.querySelectorAll('[data-act="mb-signin"]').forEach((btn) => { btn.onclick = () => mobitechSignIn(); });
  view.querySelectorAll('[data-act="mb-back"]').forEach((btn) => {
    btn.onclick = () => { mbStep = 'mobile'; mbCode = ''; mbToken = ''; mbInfo = ''; mbError = ''; render(); };
  });
  view.querySelectorAll('[data-act="mb-start"]').forEach((btn) => {
    btn.onclick = () => { mbStep = 'mobile'; mbError = ''; mbInfo = ''; render(); };
  });
  view.querySelectorAll('[data-act="mb-cancel"]').forEach((btn) => {
    btn.onclick = () => { mbStep = 'idle'; mbMobile = ''; mbError = ''; render(); };
  });
  view.querySelectorAll('[data-act="mb-signout"]').forEach((btn) => { btn.onclick = () => mobitechSignOut(); });

  view.querySelectorAll('[data-act="irr-refresh"]').forEach((btn) => { btn.onclick = () => refreshIrrigation(); });
  view.querySelectorAll('[data-act="crop-day"]').forEach((btn) => { btn.onclick = () => { cropDayPick = btn.dataset.day; render(); }; });
  view.querySelectorAll('[data-act="home-refresh"]').forEach((btn) => {
    btn.onclick = () => { requestWater(true); if (canControl) refreshIrrigation(); else toast('ok', 'Asked for fresh water readings.'); };
  });
  view.querySelectorAll('[data-act="irr-builder"]').forEach((a) => {
    a.onclick = (e) => { e.preventDefault(); irrBuilderOpen = !irrBuilderOpen; render(); };
  });
  view.querySelectorAll('[data-act="run-open"]').forEach((btn) => {
    btn.onclick = () => { runOpen = true; runPick = []; render(); };
  });
  view.querySelectorAll('[data-act="run-cancel"]').forEach((btn) => {
    btn.onclick = () => { runOpen = false; runPick = []; render(); };
  });
  view.querySelectorAll('[data-act="run-pick"]').forEach((btn) => {
    btn.onclick = () => {
      const id = Number(btn.dataset.valve);
      runPick = runPick.includes(id) ? runPick.filter((x) => x !== id) : runPick.concat(id).slice(0, IRR_MAX_VALVES);
      render();
    };
  });
  view.querySelectorAll('[data-act="run-min"]').forEach((sel) => { sel.onchange = () => { runMinutes = Number(sel.value); }; });
  view.querySelectorAll('[data-act="run-go"]').forEach((btn) => { btn.onclick = () => runValves(); });
  view.querySelectorAll('[data-act="irr-stop"]').forEach((btn) => { btn.onclick = () => stopIrrigation(); });
  // A <details> is opened by hand; keep it open across the live rebuilds.
  view.querySelectorAll('details.acct-sec, details.wdetails').forEach((d, i) => {
    const key = `${d.className}:${i}`;
    if (openDetails.has(key)) d.open = openDetails.get(key);
    d.ontoggle = () => openDetails.set(key, d.open);
  });
  view.querySelectorAll('[data-act="water-refresh"]').forEach((btn) => {
    btn.onclick = () => { requestWater(true); toast('ok', 'Asked the controllers for fresh readings.'); };
  });
  // Livesky sign-in: the same held-rebuild handling as Mobitech's.
  view.querySelectorAll('[data-act="ls-mobile"],[data-act="ls-code"]').forEach((input) => {
    input.onfocus = beginInteract;
    input.onblur = () => setTimeout(endInteract, 300);
    input.oninput = () => { if (input.dataset.act === 'ls-mobile') lsMobile = input.value; else lsCode = input.value; };
    input.onkeydown = (e) => { if (e.key === 'Enter') { input.blur(); (input.dataset.act === 'ls-mobile' ? liveskySendCode : liveskySignIn)(); } };
  });
  view.querySelectorAll('[data-act="ls-send"]').forEach((btn) => { btn.onclick = () => liveskySendCode(); });
  view.querySelectorAll('[data-act="ls-signin"]').forEach((btn) => { btn.onclick = () => liveskySignIn(); });
  view.querySelectorAll('[data-act="ls-back"]').forEach((btn) => {
    btn.onclick = () => { lsStep = 'mobile'; lsCode = ''; lsInfo = ''; lsError = ''; render(); };
  });
  view.querySelectorAll('[data-act="ls-start"]').forEach((btn) => {
    btn.onclick = () => { lsStep = 'mobile'; lsError = ''; lsInfo = ''; render(); };
  });
  view.querySelectorAll('[data-act="ls-cancel"]').forEach((btn) => {
    btn.onclick = () => { lsStep = 'idle'; lsMobile = ''; lsError = ''; render(); };
  });
  view.querySelectorAll('[data-act="ls-signout"]').forEach((btn) => { btn.onclick = () => liveskySignOut(); });

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

/** "3h" since the entity last changed state, or '' if unknown. */
function sinceText(ent) {
  const t = Date.parse(ent.lastChanged || '');
  if (!Number.isFinite(t)) return '';
  const sec = (Date.now() + clockSkewMs - t) / 1000;
  if (sec < 0) return '';
  if (sec >= 172800) return `${Math.round(sec / 86400)} days`;
  return humanAge(sec);
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

/* One bridge state, drawn in two places: the header pill on phones and the
 * overview's page-head pill on wide screens. Words first, colour second. */
function bridgeStatus() {
  const hb = state.meta?.bridge;
  if (!hb || !hb.lastSeen) return { cls: '', short: 'Connecting', long: 'No bridge data yet' };
  if (hb.status === 'offline') return { cls: 'pill-offline', short: 'Offline', long: 'Bridge offline' };
  const ageSec = Math.max(0, (Date.now() + clockSkewMs - hb.lastSeen) / 1000);
  const ago = `${humanAge(ageSec)} ago`;
  if (ageSec > (hb.heartbeatSeconds || 30) * STALE_FACTOR) {
    return { cls: 'pill-stale', short: `Stale · ${ago}`, long: `Bridge stale · ${ago}`, ageSec };
  }
  return { cls: 'pill-online', short: `Live · ${ago}`, long: `Bridge live · ${ago}`, ageSec };
}

function renderBridgeStatus() {
  const b = bridgeStatus();
  el('m-bridge').className = `pill pill-unknown only-narrow ${b.cls}`;
  el('m-bridge-text').textContent = b.short;
  const head = el('head-bridge');
  if (head) {
    head.className = `pill pill-head ${b.cls}`;
    el('head-bridge-text').textContent = b.long;
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
