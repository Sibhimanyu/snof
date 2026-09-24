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

let state = { meta: {}, areas: {}, devices: {}, entities: {}, irrigation: {}, irrigation_reports: {}, acl: {} };
let canControl = false;
let isAdmin = false;
let aclRef = null;
let currentUser = null;
let search = '';
let domainFilter = null;
let statusFilter = 'all';   // all | active | offline
const openDevices = new Set();   // device ids expanded on All devices
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
}

function leave() {
  detach();
  irrWaiters.forEach(({ ref, cb, timer }) => { clearTimeout(timer); ref.off('value', cb); });
  irrWaiters.clear();
  state = { meta: {}, areas: {}, devices: {}, entities: {}, irrigation: {}, acl: {} };
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
    n.classList.toggle('on', n.dataset.nav === (r.name === 'area' ? 'areas' : r.name)));

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
      : head('Admin', 'Grant or revoke dashboard access.', '', 'Access') +
        emptyBlock('Admins only', 'Your account does not have admin access.');
    else view.innerHTML = overviewView(all, areas);
    wire(all);
    restoreFocus(token);
  }
  // After the view: the overview's own bridge pill is inside it.
  renderBridgeStatus();

  el('stats').textContent = all.length
    ? `${byDevice(all).length} devices · ${areas.length} areas · ${all.length} readings · updated ${new Date().toLocaleTimeString()}`
    : 'Waiting for the bridge to publish its first snapshot…';

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
  return head('Your farm, right now.', 'Connecting to the farm…', '', todayLine()) +
    `<div class="sk-grid">${'<div class="sk-card"></div>'.repeat(6)}</div>`;
}

/** Rooms with anything not reporting, worst first. */
function troubledAreas(devices) {
  const tally = new Map();
  for (const d of devices) if (deviceOffline(d)) tally.set(d.area, (tally.get(d.area) || 0) + 1);
  return [...tally.entries()].sort((a, b) => b[1] - a[1] ||
    areaName(a[0]).localeCompare(areaName(b[0]), undefined, NATURAL)).map(([id]) => id);
}

/* The farm pulse: one sentence a person would say, then the numbers behind
 * it — a single meter and three figures, each a link into All devices. Honest
 * before reassuring: a bridge gone quiet outranks everything, and "most areas
 * are running normally" is only said when it is true. The sentence names
 * *where*; the figures under it carry the counts, so neither repeats the other. */
function pulsePanel(devices, areaCount) {
  // Counted in devices, not entities: one switched-off printer is one thing to
  // look at, not 67. A device with some entities still answering is reporting.
  const n = devices.length;
  const bad = devices.filter(deviceOffline).length;
  const on = devices.filter(deviceActive).length;
  const where = listWords(troubledAreas(devices).map(areaName));
  const b = bridgeStatus();
  let title, body, quiet = false;
  if (b.cls === 'pill-stale' || b.cls === 'pill-offline') {
    quiet = true;
    title = 'The bridge has gone quiet.';
    body = b.cls === 'pill-offline'
      ? 'The farm bridge reported itself offline. What you see is the last state it sent.'
      : `Nothing has arrived from the farm for ${humanAge(b.ageSec)}. What you see may be out of date.`;
  } else if (!n) {
    title = 'Waiting for the first devices.';
    body = 'Assign devices to rooms in Home Assistant and they will appear here.';
  } else if (!bad) {
    title = 'Everything is reporting.';
    body = `Every device across ${areaCount} ${plural(areaCount, 'area', 'areas')} is answering.`;
  } else if (bad / n <= 0.25) {
    title = 'Most areas are running normally.';
    body = `The few that are not reporting are in ${where}.`;
  } else if (bad / n <= 0.5) {
    title = 'A few devices need a look.';
    body = `The ones not reporting are in ${where}.`;
  } else {
    title = 'Much of the farm is quiet.';
    body = `Most of what is offline is in ${where}.`;
  }
  const pct = (k) => (n ? (k / n) * 100 : 0).toFixed(1);
  const fig = (value, label, status, cls = '', of = '') =>
    `<a class="pstat ${cls}" href="#/devices" data-act="filter" data-status="${status}">` +
    `<span class="pstat-value">${value}${of}</span><span class="pstat-label">${label}</span></a>`;
  const figures = n ? `
    <div class="pulse-meter" role="img" aria-label="${n - bad} of ${n} devices reporting">
      <span class="pm-ok" style="width:${pct(n - bad)}%"></span><span class="pm-bad" style="width:${pct(bad)}%"></span></div>
    <div class="pulse-stats">` +
      fig(n - bad, 'Reporting', 'active', '', `<span class="pstat-of">/${n}</span>`) +
      fig(on, 'Active now', 'active') +
      fig(bad, 'Offline', 'offline', bad ? 'pstat-bad' : '') +
    `</div>` : '';
  return `<section class="pulse${quiet ? ' is-quiet' : ''}" aria-label="Farm pulse">
    <p class="eyebrow">Farm pulse</p><h2 class="pulse-title">${escapeHtml(title)}</h2>
    <p class="pulse-body">${escapeHtml(body)}</p>${figures}
  </section>`;
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
  const shown = byRoom ? [] : rows.slice(0, 4);
  const roomRows = byRoom ? troubledAreas(devices).slice(0, 4).map((id) => {
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

function overviewView(all, areas) {
  const devices = byDevice(all);
  const b = bridgeStatus();
  const pill = `<span id="head-bridge" class="pill pill-head ${b.cls}" role="status">` +
    `<span class="dot"></span><span id="head-bridge-text">${escapeHtml(b.long)}</span></span>`;
  const cards = areas.slice(0, 6).map(([id, list]) => areaCard(id, list)).join('');
  const areasPanel = `<section class="panel ov-areas" aria-label="Areas at a glance">` +
    panelHead('Areas at a glance', ['#/areas', areas.length > 6 ? `View all ${areas.length} areas` : 'View all areas']) +
    (cards ? `<div class="panel-body"><div class="grid">${cards}</div></div>`
           : emptyBlock('No areas yet', 'Assign devices to an area in Home Assistant and they will group themselves here.')) +
    `</section>`;

  return head('Your farm, right now.', '', pill, todayLine()) +
    `<div class="ov">
      <div class="ov-main">${pulsePanel(devices, areas.length)}${areasPanel}</div>
      <div class="ov-side">${attentionCard(devices)}${quickControls(all)}</div>
    </div>`;
}

function areasView(all) {
  const areas = groupByArea(all.filter(matches));
  if (!areas.length) return head('Areas', 'Nothing matches that search.', '', 'Rooms and zones') + noMatch();
  const devices = byDevice(all);
  const bad = devices.filter(deviceOffline).length;
  return head('Areas', `${areas.length} ${plural(areas.length, 'area', 'areas')} · ${devices.length} devices` +
      (bad ? ` · ${bad} offline` : ''), '', 'Rooms and zones') +
    `<div class="grid">${areas.map(([id, list]) => areaCard(id, list)).join('')}</div>`;
}

function areaCard(id, list) {
  // Devices, like the Overview tiles: a room with one switched-off printer has
  // one thing offline, not 56.
  const devices = byDevice(list);
  const on = devices.filter(deviceActive).length;
  const bad = devices.filter(deviceOffline).length;
  return `<a class="area-card" href="#/area/${encodeURIComponent(id)}">
    <div class="area-top"><span class="area-name">${escapeHtml(areaName(id))}</span>${arrow('i-arrow-ne', 'area-arrow')}</div>
    <span class="area-count">${devices.length} ${plural(devices.length, 'device', 'devices')}</span>
    <div class="area-meta">
      ${on ? `<span class="on">${on} active</span>` : `<span class="quiet">Nothing on</span>`}
      ${bad ? `<span class="bad">${bad} unavailable</span>` : `<span class="on">All reporting</span>`}
    </div>
  </a>`;
}

function areaView(all, id) {
  const inArea = all.filter((e) => e.area === id);
  const list = inArea.filter(matches);
  const back = `<a class="back" href="#/areas">${arrow('i-back')}All areas</a>`;
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
  const on = devices.filter(deviceActive).length;
  const bad = devices.filter(deviceOffline).length;
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
  const sub = `${devices.length} ${plural(devices.length, 'device', 'devices')} · ${on} active` + (bad ? ` · ${bad} unavailable` : '');

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
  const domains = [...new Set(scoped.map((e) => e.domain))].sort();
  const list = scoped.filter((e) => matches(e) && (!domainFilter || e.domain === domainFilter)).sort(byName);
  const groups = byDevice(list).sort((a, b) => a.name.localeCompare(b.name, undefined, NATURAL));

  const counts = { all: byDevice(all).length, active: byDevice(all.filter((e) => !isBad(e))).length,
                   offline: byDevice(all.filter(isBad)).length };
  const seg = `<div class="seg" role="group" aria-label="Filter by status">` +
    [['all', 'All'], ['active', 'Reporting'], ['offline', 'Not reporting']].map(([k, label]) =>
      `<button data-act="status" data-status="${k}" aria-pressed="${statusFilter === k}">` +
      `${label}<span class="n">${counts[k]}</span></button>`).join('') + `</div>`;

  const chips = domains.length > 1 ? `<div class="chips">` + domains.map((d) => {
    const n = scoped.filter((e) => e.domain === d).length;
    return `<button class="chip${domainFilter === d ? ' on' : ''}" aria-pressed="${domainFilter === d}" ` +
      `data-domain="${escapeHtml(d)}">${escapeHtml(humanDomain(d))}<span class="n">${n}</span></button>`;
  }).join('') + `</div>` : '';

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
    const shownNote = g.ents.length !== whole.ents.length ? `${g.ents.length} of ${whole.ents.length} readings` : `${whole.ents.length} ${plural(whole.ents.length, 'reading', 'readings')}`;
    return `<section class="dgroup${open ? ' open' : ''}">
      <button class="dgroup-head" data-act="dev-open" data-dev="${escapeHtml(g.id)}" aria-expanded="${open}">
        <span class="dgroup-main"><span class="dgroup-name">${escapeHtml(g.name)}</span>
          <span class="dgroup-meta">${escapeHtml(areaName(g.area))} · ${shownNote}</span></span>
        ${status}${arrow('i-chevron', 'dgroup-chev')}
      </button>
      ${open ? `<div class="dgroup-body">${g.ents.map((e) => row(e)).join('')}</div>` : ''}
    </section>`;
  }).join('');

  return head('All devices', `${counts.all} ${plural(counts.all, 'device', 'devices')} · ${all.length} readings`, '', 'Everything in a room') +
    `<div class="toolbar-row">${seg}</div>` + chips +
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
  pomegranate: 'pomegranate', backwash: 'backwash',
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
  const reachable = reportsGate();
  const blocked = !reachable.ok;
  const builder = canControl
    ? `<div class="rep-builder">
        <label class="rep-field"><span>Report</span>
          <select id="irr-type" data-act="irr-type">${options}</select></label>
        <label class="rep-field"${showRange ? '' : ' hidden'}><span>From</span>
          <input id="irr-from" type="date" value="${escapeHtml(irrFrom)}" data-act="irr-from" max="${escapeHtml(def.to)}"></label>
        <label class="rep-field"${showRange ? '' : ' hidden'}><span>To</span>
          <input id="irr-to" type="date" value="${escapeHtml(irrTo)}" data-act="irr-to" max="${escapeHtml(def.to)}"></label>
        <button class="btn btn-primary" data-act="irr-gen"${pending || blocked ? ' disabled' : ''}>` +
          `${pending ? 'Working…' : 'Generate report'}</button>
      </div>
      ${blocked ? `<p class="more-note note-off">${escapeHtml(reachable.why)}</p>` : ''}
      ${pending ? `<p class="more-note">Pulling from the vendor — the result lands below, usually within a minute.</p>` : ''}`
    : `<p class="more-note">Report generation is limited to controllers — ` +
      `your account can view results below, but not run new pulls.</p>`;

  const reports = irrReports();
  const repsSec = sectionHead('i-menu', 'Reports') +
    (reports.length
      ? reports.slice().reverse().map(([k, r], i) => irrReportCard(k, r, reportOpen.has(k) ? reportOpen.get(k) : i === 0)).join('')
      : emptyBlock('No reports yet',
          !canControl ? 'No reports have been run yet.'
          : blocked ? reachable.why
          : 'Build one above — pick a report and press Generate.'));

  const n = irrig();
  const valves = n.valves || [];
  const dcon = n.dcon || {};
  const readings = [...(n.electricity || []), ...(n.pressure || [])];
  const names = n.valveNames || [];
  const lastNote = n.meta?.lastUpdated
    ? `<p class="more-note">Last results from ` +
      `${escapeHtml(n.meta.lastType || 'a report')} · ` +
      `${escapeHtml(new Date(n.meta.lastUpdated).toLocaleString())}.` +
      `${n.meta.lastError ? ` Last error: ${escapeHtml(n.meta.lastError)}.` : ''}</p>`
    : '';

  const valvesOpen = valves.filter((v) => v.status === 'on').length;
  const latest = (rows) => {
    const last = (rows || [])[(rows || []).length - 1];
    return last ? [last.value, last.unit].filter(Boolean).join(' ') : '—';
  };
  const cacheSec = (valves.length || dcon.device || readings.length || names.length)
    ? sectionHead('i-water_heater', 'Last results') + lastNote +
      `<div class="stats">
        <div class="stat stat-on"><span class="stat-label">Valves open</span>
          <span class="stat-value">${valvesOpen}</span>
          <span class="stat-note">of ${valves.length} last seen</span></div>
        <div class="stat"><span class="stat-label">Pressure</span>
          <span class="stat-value">${escapeHtml(latest(n.pressure))}</span>
          <span class="stat-note">${escapeHtml((n.pressure || []).length ? 'last reading' : 'no pull yet')}</span></div>
        <div class="stat"><span class="stat-label">Electricity</span>
          <span class="stat-value">${escapeHtml(latest(n.electricity))}</span>
          <span class="stat-note">${escapeHtml((n.electricity || []).length ? 'last reading' : 'no pull yet')}</span></div>
      </div>` +
      // Each list gets a titled panel, as in a room: three unlabelled
      // stacks of rows read as one list of unrelated things.
      (dcon.device
        ? `<section class="panel cache-sec">` + panelHead('Controller') + `<div class="list">` +
          [['Device', dcon.device], ['Serial', dcon.serial],
           ['Last packet', dcon.lastPacket], ['Controller clock', dcon.serverTime]]
            .filter(([, v]) => v)
            .map(([k, v]) => irrigRow('i-menu', String(v), k, '')).join('') +
          `</div></section>` : '') +
      (names.length
        ? `<section class="panel cache-sec">` + panelHead('Valves', null, names.length) +
          `<div class="list${names.length > 8 ? ' cols' : ''}">` +
          names.map((v) => irrigRow('i-valve', v.name,
            v.type || `valve ${v.id}`, '', valveArt(v.name, v.type))).join('') + `</div></section>` : '') +
      (valves.length
        ? `<section class="panel cache-sec">` + panelHead('Last valve run', null, valves.length) +
          `<div class="list${valves.length > 8 ? ' cols' : ''}">` +
          valves.map((v) => irrigRow('i-valve', v.name || `Valve ${v.id || ''}`,
            [v.runtime, v.id].filter(Boolean).join(' · ') || 'valve',
            irrigStatusTag(v.status), valveArt(v.name, v.type, v.status))).join('') + `</div></section>` : '')
    : '';

  return head('Irrigation', 'Build a report from the irrigation controller.', '', 'Mobitech DCON') +
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

/* ---- Mobitech sign-in (admins) ----
 * Valve commands need a Mobitech *session*. The app creates one exactly the
 * way Mobitech's own iOS app does (captured 2026-09-24): ask for an SMS code
 * (POST /v1/otp/), then log in with it and a device token of our own making
 * (POST /v1/http/ action=login type=otp). Mobitech answers `state: ok` and
 * echoes the token as `id`; that is what commands are sent with. The browser
 * talks to Mobitech directly (it allows any origin; it refuses Google Cloud,
 * so a function could not), then stores the token where no client can read
 * it (/private/mobitech) and a non-secret line for everyone to see
 * (farms/<farm>/mobitech_status). The number and the code are never stored. */
const MOBITECH = 'https://dcon.mobitechwireless.com';
let mbStep = 'mobile';   // mobile | code
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

async function mobitechSendCode() {
  const mobile = mobitechDigits(mbMobile);
  if (!/^\d{10}$/.test(mobile)) { mbError = 'Enter the 10-digit mobile number on the Mobitech account.'; render(); return; }
  mbBusy = true; mbError = ''; mbInfo = ''; render();
  try {
    // Byte for byte what the app sends: a JSON object as the whole
    // form-encoded body.
    const r = await fetch(`${MOBITECH}/v1/otp/`, { method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' },
      body: JSON.stringify({ mobile: `91${mobile}` }) });
    if (!r.ok) throw new Error(`Mobitech answered ${r.status}`);
    mbStep = 'code'; mbCode = ''; mbToken = mobitechDeviceToken();
    mbInfo = `Mobitech sent a code to the number ending ${mobile.slice(-4)}.`;
  } catch (err) {
    mbError = `Could not ask Mobitech for a code: ${err.message}`;
  }
  mbBusy = false; render();
}

async function mobitechSignIn() {
  const mobile = mobitechDigits(mbMobile);
  const otp = String(mbCode || '').replace(/\D/g, '');
  if (!/^\d{4,8}$/.test(otp)) { mbError = 'Enter the code from the SMS.'; render(); return; }
  mbBusy = true; mbError = ''; render();
  try {
    const body = new URLSearchParams({ action: 'login', type: 'otp', otp, mobile,
      token: mbToken || mobitechDeviceToken(), product: 'DCON', app_id: 'com.mobitech.drip' });
    const r = await fetch(`${MOBITECH}/v1/http/?`, { method: 'POST',
      headers: { 'content-type': 'application/x-www-form-urlencoded' }, body });
    const text = await r.text();
    let who = {};
    try { who = JSON.parse(text); } catch { /* not JSON */ }
    if (!r.ok || who.state !== 'ok') {
      throw new Error(who.msg || who.message || who.reason || 'the code was not accepted');
    }
    const token = String(who.id || body.get('token'));
    if (!token.endsWith('@ios')) throw new Error('Mobitech did not return a session');
    const db = firebase.database();
    const at = firebase.database.ServerValue.TIMESTAMP;
    await db.ref('private/mobitech').set({ token, at, uid: currentUser.uid });
    await db.ref(`farms/${FARM}/mobitech_status`).set({ at, uid: currentUser.uid,
      name: String(who.name || '').slice(0, 64), user: String(who.uname || '').slice(0, 64),
      mobileLast4: mobile.slice(-4) });
    mbStep = 'mobile'; mbMobile = ''; mbCode = ''; mbToken = ''; mbInfo = '';
    toast('ok', `Signed in to Mobitech as ${who.name || who.uname || 'the farm account'}. Valve commands use this session.`);
  } catch (err) {
    mbError = `Not signed in: ${err.message}`;
  }
  mbBusy = false; render();
}

function mobitechPanel() {
  const st = state.mobitechStatus || {};
  const since = st.at ? new Date(st.at).toLocaleString('en-GB', { day: 'numeric', month: 'short', hour: '2-digit', minute: '2-digit' }) : '';
  const now = st.at
    ? `<p class="more-note">Signed in as <strong>${escapeHtml(st.name || st.user || 'the farm account')}</strong>` +
      `${st.user ? ` (${escapeHtml(st.user)})` : ''} · number ending ${escapeHtml(st.mobileLast4 || '····')} · ${escapeHtml(since)}. ` +
      `Valve commands are sent with this session. Sign in again if they report an expired token.</p>`
    : `<p class="more-note note-off">Not signed in yet: valve commands need a Mobitech session.</p>`;
  const form = mbStep === 'mobile'
    ? `<div class="rep-builder" data-key="mobitech">
        <label class="rep-field"><span>Mobitech mobile number</span>
          <input id="mb-mobile" type="tel" inputmode="numeric" autocomplete="tel-national" placeholder="10 digits"
                 value="${escapeHtml(mbMobile)}" data-act="mb-mobile"></label>
        <button class="btn btn-primary" data-act="mb-send"${mbBusy ? ' disabled' : ''}>${mbBusy ? 'Sending…' : 'Send code'}</button>
      </div>`
    : `<div class="rep-builder" data-key="mobitech">
        <label class="rep-field"><span>Code from the SMS</span>
          <input id="mb-code" type="text" inputmode="numeric" autocomplete="one-time-code" placeholder="6 digits"
                 value="${escapeHtml(mbCode)}" data-act="mb-code"></label>
        <button class="btn btn-primary" data-act="mb-signin"${mbBusy ? ' disabled' : ''}>${mbBusy ? 'Signing in…' : 'Sign in'}</button>
        <button class="btn btn-ghost" data-act="mb-back"${mbBusy ? ' disabled' : ''}>Use another number</button>
      </div>`;
  return sectionHead('n-admin', 'Mobitech account') + now + form +
    (mbInfo ? `<p class="more-note">${escapeHtml(mbInfo)}</p>` : '') +
    (mbError ? `<p class="more-note note-off">${escapeHtml(mbError)}</p>` : '');
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

  return head('Admin', 'Add people and grant or revoke dashboard access.', '', 'Access') +
    mobitechPanel() +
    sectionHead('n-admin', 'Add a person') + addForm +
    sectionHead('n-admin', 'People') + list +
    `<p class="more-note">Admin status is granted from the command line ` +
    `(<code>npm run grant -- someone@example.com --admin</code>), not from here — ` +
    `the one tier this page cannot hand out.</p>`;
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
