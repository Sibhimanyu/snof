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
/* Room sections named for what they are, not Home Assistant's domains
 * ("Binary Sensor", "Alarm Control Panel"), in this order after the operable
 * ones. Mirrors Entity.sectionTitles in SNOFCore. */
const SECTION_TITLE = { light: 'Lights', switch: 'Switches', fan: 'Fans', input_boolean: 'Toggles',
  climate: 'Air conditioning', media_player: 'TVs & speakers', remote: 'Remotes', camera: 'Cameras',
  alarm_control_panel: 'Alarm', binary_sensor: 'Detectors', sensor: 'Readings', device_tracker: 'Presence' };
const SECTION_ORDER = Object.keys(SECTION_TITLE);
/* Settings rather than things to look at (a switch's power-on behaviour, an
 * AC's timer, a firmware notice): left out of room and system pages unless
 * searched for. Mirrors Entity.settingDomains. */
const SETTING_DOMAINS = new Set(['select', 'input_select', 'number', 'input_number', 'time', 'date', 'datetime',
  'button', 'input_button', 'image', 'text', 'input_text', 'update', 'event']);
/* Diagnostics ("Goats Debug (station)"): the bridge does not export Home
 * Assistant's entity category, so the name is what says it. */
const isBackstage = (e) => SETTING_DOMAINS.has(e.domain) || /\bdebug\b/i.test(e.name || '');

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
  motorCmd = null; motorCmdKey = null; motorCmdConfirming = false; clearTimeout(motorCmdTimer);
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
  // Motor presses go only over a live connection: a write the SDK queues
  // offline would reach the farm late (the rules and function refuse it
  // too, by its press time).
  {
    const cRef = db.ref('.info/connected');
    const cCb = cRef.on('value', (snap) => { dbConnected = snap.val() === true; });
    refs.push({ ref: cRef, ev: 'value', cb: cCb });
  }
  {
    const mRef = db.ref(`farms/${FARM}/motor_command_results`).limitToLast(10);
    const mCb = mRef.on('value', (snap) => { settleMotor(snap.val() || {}); render(); }, () => {});
    refs.push({ ref: mRef, ev: 'value', cb: mCb });
  }
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
  tidyNames(out);
  return out;
}

/* Some integrations name a device by its serial number: the 3D printer is
 * "P1S_01P09C510500118", its AMS "P1S_01P09C510500118_AMS_1", a camera
 * station "T8400P202040124D". They read as what they are here; renaming the
 * device in Home Assistant fixes it at the source. Mirrors DeviceNames in
 * SNOFCore. */
const BAMBU_NAME = /^(P1S|P1P|X1C|X1E|X1|A1M|A1|H2D|H2S)_(?=(?:[A-Z]*\d){6})[0-9A-Z]{12,}(?:_(.+))?$/;
const SERIAL_NAME = /^(?=(?:[A-Z]*\d){6})[A-Z0-9]{10,}$/;
function tidyDeviceName(raw, objectIds) {
  const b = BAMBU_NAME.exec(raw || '');
  if (b) {
    if (!b[2]) return `${b[1]} printer`;
    const rest = b[2].replace(/_/g, ' ').replace(/([a-z])([A-Z])/g, '$1 $2');
    return `${b[1]} ${/^[A-Z]{2}/.test(rest) ? rest : rest.toLowerCase()}`;
  }
  // Two ids at least: one id's "prefix" is the whole id ("goats_motion_detected").
  if (SERIAL_NAME.test(raw || '') && objectIds.length >= 2) {
    // Home Assistant keeps the name a device had when its entities were made
    // in their ids: "goats_motion_detected", under a station now called by
    // its serial number.
    const parts = objectIds.map((o) => o.split('_'));
    let n = 0;
    while (parts.every((p) => p.length > n && p[n] === parts[0][n])) n++;
    const slug = parts[0].slice(0, n).join(' ');
    if (slug.length >= 3 && !raw.toLowerCase().startsWith(parts[0][0])) return slug.charAt(0).toUpperCase() + slug.slice(1);
  }
  return raw;
}

/** deviceId -> { raw, tidy } for the devices tidyDeviceName() renamed. */
let renamedDevices = new Map();
function tidyNames(ents) {
  const ids = new Map();
  for (const e of ents) if (e.device) (ids.get(e.device) || ids.set(e.device, []).get(e.device)).push(e.objectId);
  renamedDevices = new Map();
  for (const [id, oids] of ids) {
    const raw = state.devices?.[id]?.name;
    const tidy = raw && tidyDeviceName(raw, oids);
    if (tidy && tidy !== raw) renamedDevices.set(id, { raw, tidy });
  }
  for (const e of ents) {
    // "Solar Solar Power": a device named "Solar" with the integration's own
    // "Solar Power" sensor. Say the device once.
    const own = state.devices?.[e.device]?.name;
    if (own && typeof e.name === 'string' && e.name.startsWith(`${own} ${own}`) && [undefined, ' '].includes(e.name[own.length * 2 + 1])) {
      e.name = e.name.slice(own.length + 1);
    }
    const d = renamedDevices.get(e.device);
    if (d && typeof e.name === 'string' && e.name.startsWith(d.raw) && [undefined, ' '].includes(e.name[d.raw.length])) {
      // "T8400P202040124D Goats" is the station's own entity: "Goats", not "Goats Goats".
      const rest = e.name.slice(d.raw.length).trim();
      const repeats = rest.toLowerCase().startsWith(d.tidy.toLowerCase()) && [undefined, ' '].includes(rest[d.tidy.length]);
      e.name = repeats ? rest : rest ? `${d.tidy} ${rest}` : d.tidy;
    }
  }
}
/** A device's name as the farm reads it; `rawDeviceName` for matching on. */
const deviceName = (id) => renamedDevices.get(id)?.tidy || state.devices?.[id]?.name || '';
const rawDeviceName = (id) => state.devices?.[id]?.name || '';

const areaName = (id) => state.areas?.[id]?.name || id;

/* The farm thinks in devices — "the printer is off" — while Home Assistant
 * reports entities, dozens per device. Group back into devices for anything
 * that counts. An entity without a device id (an older bridge) stands alone. */
function byDevice(ents) {
  const map = new Map();
  for (const e of ents) {
    const id = e.device || e.key;
    if (!map.has(id)) map.set(id, { id, name: deviceName(e.device) || e.name || e.key, raw: rawDeviceName(e.device), area: e.area, ents: [] });
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
  // The page says "offline"; the data says "unavailable". Both find it.
  const words = isBad(ent) ? ' offline not reporting' : '';
  return `${ent.name} ${ent.entity_id} ${ent.state} ${areaName(ent.area)}${words}`.toLowerCase().includes(search);
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

const ROUTES = new Set(['overview', 'irrigation', 'water', 'areas', 'devices', 'area', 'admin', 'sys']);
const route = () => {
  const h = (location.hash || '#/').slice(1);
  const [, head, arg] = h.match(/^\/([^/]*)\/?(.*)$/) || [, '', ''];
  const name = head || 'overview';
  return ROUTES.has(name) ? { name, arg: decodeURIComponent(arg || '') } : { name: 'overview', arg: '' };
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
  if (owner && a.dataset.act) return { key: owner.dataset.key, act: a.dataset.act, same: owner === a };
  // Buttons that carry their own identity (the day switch, a crop picker).
  if (a.dataset.act) return { act: a.dataset.act, day: a.dataset.day, valve: a.dataset.valve };
  const href = a.getAttribute('href');
  if (href) return { href };
  return null;
}

function restoreFocus(token) {
  if (!token) return;
  const q = (v) => CSS.escape(v);
  let sel;
  if (token.domain) sel = `.chip[data-domain="${q(token.domain)}"]`;
  else if (token.key) sel = token.same ? `[data-key="${q(token.key)}"][data-act="${q(token.act)}"]`
    : `[data-key="${q(token.key)}"] [data-act="${q(token.act)}"]`;
  else if (token.act) sel = `[data-act="${q(token.act)}"]` + (token.day ? `[data-day="${q(token.day)}"]` : '') + (token.valve ? `[data-valve="${q(token.valve)}"]` : '');
  else if (token.href) sel = `[href="${q(token.href)}"]`;
  if (sel) el('view').querySelector(sel)?.focus();
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
  // Each page names itself, so tabs, history and bookmarks tell them apart.
  const pageName = { overview: 'Home', irrigation: 'Irrigation', water: 'Water', areas: 'Rooms', devices: 'All devices',
    admin: 'Admin', area: areaName(r.arg), sys: SYSTEMS[r.arg]?.title }[r.name] || 'Home';
  document.title = `${pageName} · SNOF`;
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
const todayLine = () => new Date().toLocaleDateString('en-GB', { weekday: 'long', day: 'numeric', month: 'long' })
  .replace(/^(\w+),?\s/, '$1 · ');

function skeletonView() {
  const r = route();
  const title = { irrigation: 'Irrigation', water: 'Water', areas: 'Rooms', devices: 'Rooms', admin: 'Admin' }[r.name] || 'Home';
  return head(title, '', '') +
    `<div class="sk-grid">${'<div class="sk-card"></div>'.repeat(6)}</div>`;
}

/** Rooms with anything not reporting, worst first. */

/** Which devices are down, and where — a to-do list, not an entity count. */


/* Home: what needs a look, one line per system, and the switches. Every
 * number here is a link to the page that has the rest (owner, 2026-09-25:
 * "basic and simple to navigate"). */

/* ---- Home, drawn (owner, 2026-09-25: "so dull … I need more visuals") ----
 * Every picture is real data: the water chain as pipes that flow while their
 * motor runs, a ring for the irrigation run, solar, a donut of what is
 * reporting, and the switches as tiles. Colour still only means something:
 * brand green is on / flowing, brick is offline. */

const motorArt = (m) => artImg(m && m.running ? 'motor-on' : 'motor-off', 'flow-art');
const motorWord = (m) => (!m ? 'No reading' : m.running === true ? 'Running' : m.running === false ? 'Off' : 'Unknown');

/** Whether a motor's reading says what it is doing now: its vendor answered
 *  a recent pull and, for Livesky (the starter reports every few seconds),
 *  its own report is recent too. Niagara reports on change, so an hour-old
 *  "motor on" with no "off" since is still the state. A reading that is not
 *  current is drawn with its age and never as water flowing (2026-09-25: Home
 *  showed "River · Running" after the Livesky session had ended). */
function waterCurrent(m) {
  const w = state.water || {}, ws = state.meta?.water || {}, now = serverNow();
  if (!m) return false;
  // A vendor's own `at` is stamped only when its read succeeded; `pulledAt`
  // is stamped on every pull, failed or not.
  if (m.vendor === 'livesky') {
    const read = ws.livesky?.at || w.pulledAt;
    const at = Date.parse(m.liveAt || m.reportedAt || '');
    return liveskyState().kind === 'ok' && !!read && now - read <= 10 * 60000 && Number.isFinite(at) && now - at < 15 * 60000;
  }
  const read = ws.niagara?.at || (ws.niagara?.ok !== false ? w.pulledAt : 0);
  return !!read && now - read <= 10 * 60000;
}
/** How old a reading that is not current is: the starter's own report for
 *  Livesky, Niagara's last good read (its reports only mark changes); "not
 *  read" once SNOF's Livesky session is gone. */
const waterAge = (m) => (m.vendor === 'livesky' && liveskyState().kind !== 'ok' ? 'not read'
  : agoText(m.vendor === 'livesky' ? (m.liveAt || m.reportedAt) : (state.meta?.water?.niagara?.at || state.water?.pulledAt)));

function flowHero() {
  const w = state.water || {};
  const motors = Object.values(w.motors || {});
  const supply = motors.find((m) => m.role === 'main-farm');
  const drip = motors.find((m) => m.role === 'drip');
  const s = irrNowState();
  const live = (m) => !!m && m.running === true && waterCurrent(m);
  const node = (cls, art, title, sub, on, age = '') =>
    `<div class="flow-node ${cls}${on ? ' is-on' : ''}"><span class="flow-disc">${art}</span>` +
    `<span class="flow-title">${escapeHtml(title)}</span><span class="flow-sub">${escapeHtml(sub)}</span>` +
    (age ? `<span class="flow-age">${escapeHtml(age)}</span>` : '') + `</div>`;
  const pipe = (on, label) => `<div class="flow-pipe${on ? ' is-on' : ''}" aria-hidden="true">` +
    `<span class="pipe-line"></span>` +
    (label ? `<em>${escapeHtml(label)}</em>` : '') + `</div>`;
  const aged = (m) => (m && !waterCurrent(m) ? waterAge(m) : '');
  const drips = drip ? `<a class="flow-branch${live(drip) ? ' is-on' : ''}" href="#/water">${artImg(live(drip) ? 'motor-on' : 'motor-off', 'flow-mini')}` +
    `<span>${escapeHtml(drip.name)} · ${escapeHtml(motorWord(drip))}${drip.program ? ` · ${escapeHtml(drip.program)} zone ${drip.zone ?? ''}` : ''}` +
    `${aged(drip) ? ` · ${escapeHtml(aged(drip))}` : ''}</span></a>` : '';
  const hasWater = w.river || motors.length;
  // The pull's age only while every reading drawn is current; otherwise the
  // stale ones carry their own, and "just now" would vouch for them.
  const allCurrent = [w.river, supply].filter(Boolean).every(waterCurrent);
  return `<section class="panel flow" aria-label="Water from the river to the main farm">
    <div class="flow-head"><h2 class="panel-title">Water</h2>
      ${state.meta?.water?.enabled !== true ? '<span class="card-age">readings off</span>'
        : w.pulledAt && allCurrent ? `<span class="card-age">${escapeHtml(agoText(w.pulledAt))}</span>` : ''}
      <a class="panel-link" href="#/water">Details${arrow()}</a></div>
    <div class="flow-row">
      ${node('', motorArt(live(w.river) ? w.river : null), 'River', hasWater ? motorWord(w.river) : 'No reading', live(w.river), aged(w.river))}
      ${pipe(live(w.river), '')}
      ${node('', motorArt(live(supply) ? supply : null), 'Other farm', supply ? `7.5 HP ${motorWord(supply).toLowerCase()}` : 'No reading', live(supply), aged(supply))}
      ${pipe(live(supply), '')}
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
    // The same countdown as the Now card: from the controller's last report.
    const left = s.left ?? p.remainingMin, planned = p.plannedMin;
    frac = planned ? 1 - Math.max(0, left || 0) / planned : 0.5;
    tone = 'is-on'; label = left != null ? fmtMin(Math.max(0, left)) : 'On'; sub = 'left';
    valves = p.valves || '';
  } else {
    const last = irrRuns()[0];
    if (last) {
      frac = last.planned ? (last.delivered ?? (last.finished ? last.planned : 0)) / last.planned : 1;
      tone = last.finished ? 'is-done' : mayStillRun(last) ? '' : 'is-warn';
      label = runAmount(last).split(' of ')[0] || '—';
      sub = last.finished ? 'last run' : runOutcome(last).replace(/^,? /, '');
      valves = last.valves;
    }
  }
  const pics = String(valves).split(/,\s*/).filter(Boolean).slice(0, 5)
    .map((v) => { const a = valveArt(v, 'irrigation'); return a ? artImg(a, 'crop') : ''; }).join('');
  return `<a class="panel vcard" href="#/irrigation">
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
  const dev = deviceName(e.device);
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
    ${canControl ? controlNote() : `<p class="more-note">View only: your account can see these, not switch them.</p>`}<div class="tiles">${shown.map(tileFor).join('')}</div></section>`;
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
  solar: { title: 'Power', icon: 'i-sun', offline: 'warn' },
  switches: { title: 'Lights & switches', icon: 'i-light', offline: 'warn' },
  climate: { title: 'Climate', icon: 'i-climate', offline: 'none' },
  media: { title: 'TVs', icon: 'i-media_player', offline: 'none' },
  printer: { title: '3D printer', icon: 'i-printer', offline: 'none' },
  other: { title: 'Other', icon: 'i-default', offline: 'none' },
};
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
    if (id === 'printer') { printers.push(g.raw || g.name); put(id, g); } else rest.push([id, g]);
  }
  // A printer's add-ons (its AMS, the external spool) are named after it,
  // in Home Assistant's own names rather than the tidied ones.
  for (const [id, g] of rest) put(printers.some((p) => (g.raw || g.name).startsWith(`${p}_`)) ? 'printer' : id, g);
  return out;
}

/** A device that is an appliance (a fan, an AC, a TV, a remote) is "off at
 *  the wall" when unavailable, whatever system it sits in: a smart fan
 *  counted as a switch module was flagged every night (review, 2026-09-25). */
const isAppliance = (d) => d.ents.some((e) => ['fan', 'climate', 'media_player', 'remote'].includes(e.domain));

/** deviceId -> system id, so any page can tell a fault from an appliance at rest. */
function deviceSystems(all) {
  const out = new Map();
  for (const sys of Object.values(farmSystems(all))) for (const d of sys.devices) out.set(d.id, sys.id);
  return out;
}
/** Offline devices split into faults and appliances switched off. */
/** Whether a device being offline is a fault (a camera, the inverter, a
 *  switch module) rather than something switched off at the wall (an AC, a
 *  TV, the printer and its AMS). Mirrors Systems.offlineIsFault. */
const offlineIsFault = (d, index) => (SYSTEMS[index.get(d.id)] || SYSTEMS.other).offline !== 'none' && !isAppliance(d);
function offlineSplit(devices, index) {
  const down = devices.filter(deviceOffline);
  const fault = down.filter((d) => offlineIsFault(d, index));
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
      if (allOffline) return { state: 'off', line: 'Off', sub: '' };
      if (pct != null && pct > 0 && pct < 100) return { state: 'on', line: `Printing ${Math.round(pct)}%`, sub: stage && !isBad(stage) ? cap(String(stage.state).replace(/_/g, ' ')) : '' };
      return { state: 'rest', line: stage && !isBad(stage) ? cap(String(stage.state).replace(/_/g, ' ')) : 'Idle', sub: '' };
    }
    default: {
      const on = sys.devices.filter(deviceActive).length;
      return { state: on ? 'on' : 'rest', line: on ? `${on} active` : 'Quiet', sub: `${sys.devices.length} ${plural(sys.devices.length, 'device', 'devices')}` };
    }
  }
}

/* ---- power: the farm's three EB lines ----
 * Owner, 2026-09-25: three separate supplies from the electricity board.
 * Home and the sheds are on a single-phase line with the GoodWe inverter; a
 * three-phase line with the V-Guard inverter (a FoxESS unit) charges the XEV
 * 9e; and a second three-phase line, free for agriculture, runs the main farm
 * motor. Which inverter is on which line is a fact about this farm that Home
 * Assistant does not hold, so it is written here. The inverters themselves
 * are recognised by what their integrations report, not by typed names.
 * Mirrors Power.swift in SNOFCore; keep the two in step. */
const POWER_LINES = [
  { id: 'home', title: 'Home & sheds', phase: 'Single phase', short: '1-phase', inverter: 'goodwe', brand: 'GoodWe', use: 'The house and the sheds' },
  { id: 'ev', title: 'EV charging', phase: 'Three phase', short: '3-phase', inverter: 'foxess', brand: 'V-Guard', use: 'Charges the XEV 9e' },
  { id: 'farm', title: 'Farm motor', phase: 'Three phase', short: '3-phase', inverter: null, brand: '', use: 'Free agricultural supply' },
];

/** 'goodwe' | 'foxess' | null, from the entities the integration makes. */
function inverterKind(d) {
  const has = (re) => d.ents.some((e) => re.test(lname(e)));
  if (has(/on-grid l1 (voltage|power)$/)) return 'goodwe';
  if (has(/feed-in power$/) && has(/\br power$/)) return 'foxess';
  return null;
}

/** One inverter's readings. `watts` is PV input, as the old Solar card had it. */
function inverterReading(d) {
  const f = (re) => d.ents.find((e) => re.test(lname(e)) && !isBad(e));
  const pv = f(/\bpv power$/) || f(/solar power$/);
  let w = numOf(pv);
  if (w != null && unitOf(pv).toLowerCase() === 'kw') w *= 1000;
  const offline = deviceOffline(d) || w == null;
  return {
    offline, watts: offline ? null : w,
    kwh: numOf(f(/(today's pv generation|energy generated today)$/)),
    total: numOf(f(/(total pv generation|energy generated total)$/)),
    grid: numOf(f(/(on-grid l1 voltage|\br voltage)$/)),
    temp: numOf(f(/inverter temperature$/)),
    mode: f(/work mode$/)?.state || null,
  };
}
const fmtKwh = (k) => `${+k.toFixed(1)} kWh`;

/** The three lines, each with what is known about it right now. */
function powerLines(systems) {
  const inverters = (systems.solar?.devices || []).map((d) => ({ d, kind: inverterKind(d) }));
  return POWER_LINES.map((l) => {
    if (l.inverter) {
      const hit = inverters.find((i) => i.kind === l.inverter);
      return { ...l, dev: hit?.d || null, inv: hit ? inverterReading(hit.d) : null };
    }
    const rows = irrig().electricity || [];
    const val = (re) => rows.find((r) => re.test(String(r.label || '').toLowerCase()))?.value || null;
    const c = irrig();
    const checkedAt = c.program?.at || c.meta?.lastUpdated || 0;
    return { ...l, supply: irrSupply(), supplyToday: val(/^supply today/), pumpToday: val(/^pump today/),
             current: checkedAt > 0 && serverNow() - checkedAt < 60 * 60000 };
  });
}

/** { state, figure, unit, sub } for one line, as the Home panel says it. */
function lineStatus(l) {
  if (l.inverter) {
    const i = l.inv;
    if (!i) return { state: 'off', figure: 'No inverter', unit: '', sub: `${l.brand} not reporting to Home Assistant` };
    if (i.offline) return { state: 'offline', figure: 'Inverter offline', unit: '', sub: i.kwh ? `${fmtKwh(i.kwh)} today` : '' };
    const [v, u] = fmtPower(i.watts).split(' ');
    return { state: i.watts > 0 ? 'on' : 'rest', figure: v, unit: u,
             sub: i.kwh != null ? `${fmtKwh(i.kwh)} today` : 'solar' };
  }
  const sp = l.supply;
  if (!sp || !sp.v.length) return { state: 'off', figure: 'No reading', unit: '', sub: 'from the irrigation controller' };
  const at = sp.at ? ` · ${sp.at}` : '';
  // Free agricultural power comes and goes on the board's schedule, so a
  // line with no power is "off now", not a fault; a missing phase is.
  if (!sp.live) return { state: 'rest', figure: 'Power off', unit: '', sub: `${l.supplyToday ? `${l.supplyToday} today` : 'no supply'}${at}` };
  if (sp.missing) return { state: 'bad', figure: `${sp.live} of 3`, unit: 'phases', sub: `phase missing${at}` };
  return { state: 'on', figure: '3', unit: 'phases', sub: `${sp.drawing ? 'pump running' : 'pump off'}${at}` };
}

const lineArt = (id) => id === 'home' ? artImg('house', 'pw-art')
  : id === 'farm' ? artImg('motor-on', 'pw-art')
  : `<svg viewBox="0 0 24 24" class="ico pw-ico" aria-hidden="true"><use href="#i-car"/></svg>`;

/* Home: a meter board, not a picture. Water is a chain (river → farm), so it
 * is drawn as one; the three EB lines are separate supplies, so they are rows
 * that read down like a meter board: what the line is for, then its number.
 * Solar on top as one bar, split by inverter. (Owner, 2026-09-25: the two
 * panels looked the same.) */
function powerPanel(systems) {
  const lines = powerLines(systems);
  if (!lines.some((l) => l.dev || (l.supply && l.supply.v.length))) return '';
  const solar = lines.filter((l) => l.inverter);
  const solarW = solar.reduce((t, l) => t + (l.inv?.watts || 0), 0);
  const split = solarW > 0 ? `<div class="pw-split" role="img" aria-label="${escapeHtml(solar.map((l) => `${l.title} ${fmtPower(l.inv?.watts || 0)}`).join(', '))}">` +
    solar.map((l, i) => `<i class="pw-seg s${i}" style="flex:${(l.inv?.watts || 0).toFixed(0)}"></i>`).join('') + `</div>` : '';
  const right = (l, st) => {
    if (!l.inverter && l.supply && l.supply.v.length && st.state !== 'rest') {
      return `<span class="pw-right"><span class="pw-mini" aria-label="Phase voltages ${l.supply.v.map(Math.round).join(', ')} volts">` +
        l.supply.v.map((x) => `<i class="${x < 120 ? 'dead' : x < 200 || x > 260 ? 'warn' : ''}" style="height:${Math.max(8, Math.min(100, x / 300 * 100)).toFixed(0)}%"></i>`).join('') +
        `</span><span class="pw-sub">${escapeHtml(st.sub)}</span></span>`;
    }
    return `<span class="pw-right"><strong class="pw-fig">${escapeHtml(st.figure)}${st.unit ? `<small>${escapeHtml(st.unit)}</small>` : ''}</strong>` +
      `${st.sub ? `<span class="pw-sub">${escapeHtml(st.sub)}</span>` : ''}</span>`;
  };
  let seg = 0;
  return `<section class="panel power" aria-label="Power">
    <div class="pw-head"><h2 class="panel-title">Power</h2>
      <a class="panel-link" href="#/sys/solar">Details${arrow()}</a></div>
    ${solarW > 0 ? `<div class="pw-solar"><span class="pw-solar-n">${escapeHtml(fmtPower(solarW))}</span><span class="pw-solar-l">solar right now</span></div>${split}`
      : `<div class="pw-solar"><span class="pw-solar-l">No solar right now</span></div>`}
    <div class="pw-rows">${lines.map((l) => {
      const st = lineStatus(l);
      const stale = !l.inverter && !l.current;
      const key = l.inverter ? `<i class="pw-key s${seg++}"></i>` : '';
      return `<a class="pw-line is-${st.state}${stale ? ' is-stale' : ''}" href="#/sys/solar">
        <span class="pw-tile">${lineArt(l.id)}</span>
        <span class="pw-main"><span class="pw-title">${key}${escapeHtml(l.title)}</span>
          <span class="pw-phase">${escapeHtml(l.phase)} · ${escapeHtml(l.brand ? `${l.brand} solar` : 'free supply')}</span></span>
        ${right(l, st)}</a>`;
    }).join('')}</div></section>`;
}

/** Three phase bars against 0–300 V; out of 200–260 V or missing reads warm. */
function phaseBars(v) {
  return `<div class="phases" role="img" aria-label="Phase voltages ${v.map(Math.round).join(', ')} volts">` +
    v.map((x, i) => `<div class="phase${x < 120 ? ' dead' : x < 200 || x > 260 ? ' warn' : ''}"><span class="phase-bar"><i style="height:${Math.min(100, x / 300 * 100).toFixed(1)}%"></i></span>` +
      `<strong>${Math.round(x)}</strong><small>L${i + 1}</small></div>`).join('') + `</div>`;
}

/* The Power page: one panel per line. */
function powerPage(systems) {
  const lines = powerLines(systems);
  const facts = (list) => `<div class="mb-facts">${list.map(([k, v]) => `<div><span>${k}</span><strong>${escapeHtml(v)}</strong></div>`).join('')}</div>`;
  const solarW = lines.reduce((t, l) => t + (l.inv?.watts || 0), 0);
  const solarKwh = lines.reduce((t, l) => t + (l.inv?.kwh || 0), 0);
  const top = `<section class="panel sys-hero solar is-${solarW > 0 ? 'on' : 'rest'}"><span class="sun" aria-hidden="true"><svg viewBox="0 0 48 48"><circle cx="24" cy="24" r="9"/>` +
    [0, 45, 90, 135, 180, 225, 270, 315].map((d) => `<line x1="24" y1="5" x2="24" y2="10" transform="rotate(${d} 24 24)"/>`).join('') + `</svg></span>` +
    `<div class="sys-hero-body"><h2 class="sys-hero-title">${solarW > 0 ? `${escapeHtml(fmtPower(solarW))} solar` : 'No solar right now'}</h2>` +
    `<p class="sys-hero-sub">${escapeHtml(`${fmtKwh(solarKwh)} today from both inverters`)}</p></div></section>`;
  return top + lines.map((l) => {
    const st = lineStatus(l);
    let body = '';
    if (l.inverter) {
      const i = l.inv;
      if (i) {
        const f = (re) => l.dev.ents.find((e) => re.test(lname(e)) && !isBad(e));
        const list = [
          ['Solar now', i.watts != null ? fmtPower(i.watts) : '—'],
          ['Today', i.kwh != null ? fmtKwh(i.kwh) : '—'],
          ['Lifetime', i.total != null ? `${Math.round(i.total).toLocaleString('en-IN')} kWh` : '—'],
          ['Grid', i.grid != null ? `${Math.round(i.grid)} V` : '—'],
          ['Inverter', i.temp != null ? `${i.temp} °C` : '—'],
        ];
        if (i.mode) list.push(['Mode', i.mode]);
        const sw = f(/export limit switch$/), pct = numOf(f(/grid export limit$/));
        if (sw) list.push(['Export limit', `${sw.state === 'on' ? 'On' : 'Off'}${pct != null ? ` (limit ${pct}%)` : ''}`]);
        body = facts(list);
      } else body = `<p class="more-note">The ${escapeHtml(l.brand)} inverter is not reporting to Home Assistant.</p>`;
    } else {
      const sp = l.supply;
      const list = [['Supply today', l.supplyToday || '—'], ['Pump today', l.pumpToday || '—']];
      if (sp && sp.a.length) list.push(['Current', `${sp.a.map((x) => x.toFixed(1)).join(' / ')} A`]);
      if (sp && sp.imbalance != null) list.push(['Imbalance', `${sp.imbalance}%`]);
      if (sp && sp.at) list.push(['Read at', sp.at]);
      body = (sp && sp.v.length ? phaseBars(sp.v) : '') + facts(list) +
        `<a class="panel-link pw-more" href="#/irrigation">Pump & irrigation${arrow()}</a>`;
    }
    return `<section class="panel pw-sec is-${st.state}" aria-label="${escapeHtml(l.title)}">
      <div class="pw-sec-head"><span class="pw-tile">${lineArt(l.id)}</span>
        <div><h2 class="panel-title">${escapeHtml(l.title)}</h2>
          <p class="pw-sec-sub">${escapeHtml([l.phase, l.inverter && `${l.brand} solar`, l.use].filter(Boolean).join(' · '))}</p></div>
        <strong class="pw-fig">${escapeHtml(st.figure)}${st.unit ? `<small>${escapeHtml(st.unit)}</small>` : ''}</strong></div>
      ${body}</section>`;
  }).join('');
}

/* ---- needs a look ----
 * Everything across every system that deserves a look, worst first, each
 * with where to go about it. Appliances switched off never appear here. */
function attentionItems(all, systems) {
  const items = [];
  const add = (level, text, sub, href) => items.push({ level, text, sub, href });
  const b = bridgeStatus();
  if (b.cls === 'pill-offline' || b.cls === 'pill-stale') {
    // "Bridge", as the pill, the account menu and the gates say it.
    add('bad', 'Bridge not reporting', `Switches and controller reads are paused${b.ageSec ? ` · quiet for ${humanAge(b.ageSec)}` : ''}`, null);
  }
  // Irrigation.
  const c = irrig(), p = c.program;
  // Only what the controller said recently: an hours-old "no signal" or
  // "no power" must not read as a present problem.
  const checkedAt = p?.at || c.meta?.lastUpdated || 0;
  const recent = serverNow() - checkedAt < 60 * 60000;
  if (irrNowState().running) for (const f of p.faults || []) add('bad', `Valve ${f}`, 'during the running program', '#/irrigation');
  const sup = recent ? irrSupply() : null;
  if (sup && sup.v.length && !sup.live) add('warn', 'No power at the pump', sup.at ? `as of ${sup.at}` : '', '#/irrigation');
  else if (sup && sup.missing) add('bad', 'A power phase is missing', `${sup.live} of 3 phases live${sup.at ? ` · ${sup.at}` : ''}`, '#/irrigation');
  const since = serverNow() - 864e5;
  // Programs with no valves assigned end at 0m by design; they are not faults.
  const stopped = irrRuns().filter((r) => !r.finished && r.planned != null && r.valves && !mayStillRun(r) && (farmMs(r.start) ?? 0) >= since);
  if (stopped.length) add('warn', `${stopped.length} ${plural(stopped.length, 'run', 'runs')} cut short in the last 24 h`, stopped.slice(0, 2).map((r) => `${r.name} ${runAmount(r)}`).join(' · '), '#/irrigation');
  const repErr = c.meta?.lastError;
  if (repErr) add('warn', 'Could not reach the controller', repErr.replace(/^DCON [a-z_]+: /, '').slice(0, 80), '#/irrigation');
  if (isAdmin && mobitechState().kind !== 'ok') add('warn', 'Mobitech sign-in needed', 'sign in so valve commands keep working', '#/irrigation');
  // Water chain.
  const w = state.water || {};
  for (const m of [w.river, ...Object.values(w.motors || {})].filter(Boolean)) {
    if ((m.trips || []).length) add('bad', `${m.name} tripped`, m.trips.join(', '), '#/water');
    if (m.skippedZone != null) add('warn', `${m.name}: zone ${m.skippedZone} skipped`, 'no valve feedback', '#/water');
  }
  const ws = state.meta?.water || {};
  if (ws.enabled === true) {
    if (isAdmin && ['none', 'expired'].includes(liveskyState().kind)) add('warn', 'Livesky sign-in needed', 'the river motor is not being read', '#/water');
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
      const panels = sys.ents.filter((e) => e.domain === 'alarm_control_panel');
      if (panels.length && panels.every(isBad)) add('warn', 'Alarm station offline', 'the alarm state is unknown', '#/sys/security');
      const camsDown = sys.ents.filter((e) => e.domain === 'camera' && isBad(e));
      if (camsDown.length) add('warn', `${camsDown.length === 1 ? camsDown[0].name.replace(/ camera$/i, '') + ' camera' : `${camsDown.length} cameras`} offline`,
        camsDown.length > 1 ? camsDown.map((e) => e.name).join(', ') : areaName(camsDown[0].area), '#/sys/security');
      continue;
    }
    if (id === 'solar') {
      // Per inverter: one down while the other generates is still a look.
      const h = new Date(serverNow() + 330 * 60000).getUTCHours();
      if (h >= 7 && h < 18) for (const l of powerLines(systems)) {
        if (l.inv?.offline) add('warn', `${l.brand} inverter offline`, `${l.title} line · during daylight`, '#/sys/solar');
      }
      continue;
    }
    const down = sys.devices.filter((d) => deviceOffline(d) && !isAppliance(d));
    // A module named after its room ("Family Room" in the family room) says
    // what it is, or the row reads as the whole room being down.
    const one = down[0] && (down[0].name.toLowerCase() === areaName(down[0].area).toLowerCase() ? `${down[0].name} switch module` : down[0].name);
    if (down.length) add('warn', `${down.length === 1 ? one : `${down.length} switch modules`} offline`,
      down.length === 1 ? areaName(down[0].area) : down.map((d) => d.name).join(', '), '#/sys/switches');
  }
  return items.sort((a, b) => (a.level === b.level ? 0 : a.level === 'bad' ? -1 : 1));
}

let attnOpen = false;      // collapsed until asked: the count stays on top, the list waits
let attnAll = false;       // "N more" opened by hand
function attentionPanel(items) {
  if (!items.length) {
    return `<section class="panel attn is-clear" aria-label="Needs a look"><span class="attn-ok">${arrow('i-check')}</span>` +
      `<span><strong>All clear</strong><span>Nothing on the farm needs a look.</span></span></section>`;
  }
  const bad = items.filter((i) => i.level === 'bad').length;
  const shown = attnAll ? items : items.slice(0, 5);
  // Closed, the header still names the worst thing, so a glance says enough.
  const peek = items[0].text + (items.length > 1 ? ` · +${items.length - 1} more` : '');
  return `<section class="panel attn${bad ? ' is-bad' : ''}${attnOpen ? ' open' : ''}" aria-label="Needs a look">
    <button class="attn-head" data-act="attn-open" aria-expanded="${attnOpen}"><span class="attn-n">${items.length}</span>
      <span class="attn-title"><h2 class="panel-title">${plural(items.length, 'Thing needs', 'Things need')} a look</h2>` +
      `${attnOpen ? '' : `<span class="attn-peek">${escapeHtml(peek)}</span>`}</span>${arrow('i-chevron', 'attn-chev attn-toggle')}</button>
    ${attnOpen ? shown.map((i) => {
      const inner = `<span class="attn-dot"></span><span class="attn-main"><strong>${escapeHtml(i.text)}</strong>` +
        `${i.sub ? `<span>${escapeHtml(i.sub)}</span>` : ''}</span>`;
      return i.href ? `<a class="attn-row ${i.level}" href="${i.href}">${inner}${arrow('i-chevron', 'attn-chev')}</a>`
        : `<div class="attn-row ${i.level}">${inner}</div>`;
    }).join('') : ''}
    ${attnOpen && items.length > 5 ? `<button class="attn-more" data-act="attn-more" aria-expanded="${attnAll}">${attnAll ? 'Show fewer' : `${items.length - 5} more`}</button>` : ''}
  </section>`;
}

function securityCard(systems) {
  const sys = systems.security;
  if (!sys) return '';
  const s = systemSummary(sys);
  const tone = s.state === 'bad' ? 'is-bad' : s.armed ? 'is-on' : '';
  return `<a class="panel vcard sec ${tone}" href="#/sys/security">
    <span class="vcard-label">Security</span>
    <div class="vcard-body"><span class="shield" aria-hidden="true"><svg viewBox="0 0 24 24" class="ico"><use href="#i-shield"/></svg></span>
      <div class="vcard-text"><strong>${escapeHtml(s.line)}</strong>
        <span>${escapeHtml(s.sub || (s.cams ? `${s.camsOn} of ${s.cams} cameras online` : ''))}</span>
        ${s.cams ? `<span class="cam-dots" aria-hidden="true">${sys.ents.filter((e) => e.domain === 'camera').map((e) => `<i class="${isBad(e) ? 'off' : 'on'}"></i>`).join('')}</span>` : ''}</div></div>
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
  const b = bridgeStatus();
  const pill = `<span id="head-bridge" class="pill pill-head ${b.cls}" role="status"><span class="dot"></span><span id="head-bridge-text">${escapeHtml(b.long)}</span></span>`;
  // Nothing is "all clear" until the farm has actually been heard from.
  const heard = !!(state.meta && (state.meta.bridge || state.meta.updatedAt));
  return head('Home', '', `<div class="head-actions">${pill}${refresh}</div>`) + (heard ? attentionPanel(attentionItems(all, systems)) : '') + flowHero() +
    `<div class="vcards">${powerPanel(systems)}${irrigationCard()}${securityCard(systems)}</div>` +
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
    top = powerPage(systems);
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
      `<div class="list">${d.ents.filter((e) => !isBad(e) && !CONTROLLABLE.has(e.domain) && !isBackstage(e)).sort(byName).slice(0, 12).map((e) => row(e)).join('') || `<p class="more-note">${escapeHtml(areaName(d.area))}</p>`}</div></section>`).join('');
  // Per device, as on a room page: a fan on the switches page is switched
  // off, not offline.
  const offFault = id === 'security' ? [] : off.filter((d) => SYSTEMS[id].offline !== 'none' && !isAppliance(d));
  const offRest = id === 'security' ? [] : off.filter((d) => !offFault.includes(d));
  const offNote = (offFault.length ? `<p class="more-note note-off">Offline: ${escapeHtml(offFault.map((d) => d.name).join(', '))}</p>` : '') +
    (offRest.length ? `<p class="more-note">Switched off: ${escapeHtml(offRest.map((d) => d.name).join(', '))}</p>` : '');
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
  // A device that is wholly offline has nothing to show but "unavailable"
  // on every reading: it becomes one line at the end instead (a switched-off
  // printer was 56 dead rows). A search still finds its readings.
  const dead = devices.filter(deviceOffline);
  const deadIds = new Set(dead.map((d) => d.id));
  const byDomain = new Map();
  for (const e of list) {
    if (!search && (deadIds.has(e.device || e.key) || isBackstage(e))) continue;
    if (!byDomain.has(e.domain)) byDomain.set(e.domain, []);
    byDomain.get(e.domain).push(e);
  }
  // Operable domains first: the reason to open a room is usually to do something.
  const rank = (d) => (SECTION_ORDER.includes(d) ? SECTION_ORDER.indexOf(d) : 99);
  const order = [...byDomain.keys()].sort((a, b) => {
    const ca = CONTROLLABLE.has(a) ? 0 : 1, cb = CONTROLLABLE.has(b) ? 0 : 1;
    return ca - cb || rank(a) - rank(b) || a.localeCompare(b);
  });
  const split = offlineSplit(devices, deviceSystems(all));
  const sub = `${devices.length} ${plural(devices.length, 'device', 'devices')}` +
    (split.fault ? ` · ${split.fault} offline` : '') + (split.off ? ` · ${split.off} off` : '');

  return head(areaName(id), sub, '', back) +
    (canControl && !bridgeGate('control').ok ? controlNote() : '') +
    order.map((d) => {
      const items = byDomain.get(d).sort(byName);
      const title = SECTION_TITLE[d] || cap(humanDomain(d));
      return `<section class="panel area-sec">` + panelHead(title, null, items.length) + (CONTROLLABLE.has(d)
        ? `<div class="dev-list${items.length > 8 ? ' cols' : ''}">${items.map((e) => deviceCard(e, 'area')).join('')}</div>`
        : `<div class="list${items.length > 8 ? ' cols' : ''}">${items.map((e) => row(e, false, false)).join('')}</div>`) +
        `</section>`;
    }).join('') + (search ? '' : (() => {
      const index = deviceSystems(all);
      const faults = dead.filter((d) => offlineIsFault(d, index));
      const off = dead.filter((d) => !faults.includes(d));
      return (faults.length ? `<p class="more-note note-off">Offline: ${escapeHtml(faults.map((d) => d.name).join(', '))}</p>` : '') +
        (off.length ? `<p class="more-note">Switched off: ${escapeHtml(off.map((d) => d.name).join(', '))}</p>` : '');
    })());
}

/* All devices is a list of devices, not of the hundreds of readings they
 * publish: a printer is one line with a status, and opens to show its 67
 * readings. Filters and search still work on readings; a device appears when
 * any of its readings match, and opens itself when a filter is doing the
 * choosing, so what matched is visible without a click. */
function devicesView(all) {
  // "Not reporting" is a device that is wholly offline, not one with a
  // couple of readings down (the inverter, 2 of 54).
  const full = new Map(byDevice(all).map((d) => [d.id, d]));
  const deadIds = new Set([...full.values()].filter(deviceOffline).map((d) => d.id));
  const byStatus = (e) => statusFilter === 'all' ? true
    : statusFilter === 'active' ? !isBad(e) : deadIds.has(e.device || e.key);
  const scoped = all.filter(byStatus);
  const list = scoped.filter((e) => matches(e) && (!domainFilter || e.domain === domainFilter)).sort(byName);
  const index = deviceSystems(all);
  const fault = (g) => offlineIsFault(full.get(g.id) || g, index);
  // Not reporting: the faults first, then what is only switched off.
  const groups = byDevice(list).sort((a, b) => (statusFilter === 'offline' ? fault(b) - fault(a) : 0) ||
    a.name.localeCompare(b.name, undefined, NATURAL));

  const counts = { all: full.size, active: byDevice(all.filter((e) => !isBad(e))).length, offline: deadIds.size };
  const seg = `<div class="seg" role="group" aria-label="Filter by status">` +
    [['all', 'All'], ['offline', 'Not reporting']].map(([k, label]) =>
      `<button data-act="status" data-status="${k}" aria-pressed="${statusFilter === k}">` +
      `${label}<span class="n">${counts[k]}</span></button>`).join('') + `</div>`;


  // Opened by hand, or by a search: a list of dead devices opened by the
  // filter was ~170 rows of "unavailable".
  const filtering = !!(search || domainFilter);
  const body = groups.map((g) => {
    // No device id (an older bridge, or the synthetic fixture): a plain row.
    if (g.id === g.ents[0].key && !g.ents[0].device) return `<div class="list dgroup-solo">${row(g.ents[0], true)}</div>`;
    const whole = full.get(g.id) || g;
    const down = whole.ents.filter(isBad).length;
    const open = filtering || openDevices.has(g.id);
    // Off at the wall is "Off", as on Home and Rooms: the printer's AMS too,
    // which is no appliance but sits in a system whose offline is no fault.
    const status = down === 0 ? `<span class="tag tag-on">All reporting</span>`
      : down === whole.ents.length ? (fault(whole) ? `<span class="tag tag-bad">Offline</span>` : `<span class="tag">Off</span>`)
      : `<span class="tag tag-warn">${down} of ${whole.ents.length} readings down</span>`;
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
  // Farm dates: between 00:00 and 05:30 IST the UTC date is still yesterday.
  const now = serverNow();
  return { from: farmDay(now - 2 * 864e5), to: farmDay(now) };
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
  const reads = feature === 'reports';
  // bridge: closed because the bridge is quiet (two such gates are said once).
  if (!hb || !hb.lastSeen) {
    return { ok: false, bridge: true, why: reads ? 'The bridge has not checked in yet, so the controller cannot be read.'
      : 'The bridge has not checked in yet, so a press would not reach the farm.' };
  }
  const ageSec = (Date.now() + clockSkewMs - hb.lastSeen) / 1000;
  if (hb.status === 'offline' || ageSec > (hb.heartbeatSeconds || 30) * STALE_FACTOR) {
    return { ok: false, bridge: true, why: reads ? 'The bridge is not reporting in, so the controller cannot be read right now.'
      : 'The bridge is not reporting in, so a press would not reach the farm.' };
  }
  if (feature === 'control' && hb.control === false) {
    return { ok: false, why: 'Switching from the app is turned off at the farm.' };
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
  // Controller reads go through the NUC's relay until the function has a
  // static egress IP (docs/dcon-off-the-nuc.md): with the bridge quiet, a
  // Refresh would only time out. No field yet means relay.
  if (state.meta?.reports?.transport !== 'direct') return bridgeGate('reports');
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
      toast('ok', 'Report requested. The controller is being asked now.');
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
  let delivered = null, planned = null, finished = false, going = false;
  const first = pieces[0] || '';
  const tail = /^(.*?)(?:, (finished|stopped)| (so far))$/.exec(first);
  if (tail) {
    finished = tail[2] === 'finished';
    going = !!tail[3];
    const amount = tail[1];
    const parts = amount.split(' of ');
    if (parts.length === 2) { delivered = parseRuntimeMinutes(parts[0]); planned = parseRuntimeMinutes(parts[1]); }
    else { planned = parseRuntimeMinutes(amount); delivered = finished ? planned : null; }
    pieces.shift();
  }
  let valves = pieces[0] || '';
  const l = valves.toLowerCase();
  if (l.includes('backwash') || l.startsWith('started by') || l.startsWith('ended by') || valves === 'no valves') valves = '';
  // "ended by A8": the controller says who ended it (a Stop, a fault), so it
  // is over whatever the clock says.
  const ended = pieces.some((p) => /^ended by /i.test(p));
  return { kind, name, start: r.at, day: r.at.slice(0, 10), delivered, planned, finished, going, ended, valves };
}
/** Not known to have ended, so never "cut short": the function writes "so
 *  far" for a run it caught part-way, and an older log (which wrote every
 *  unfinished run as "stopped") is judged against when it was read, not
 *  against this clock. A run read 22 minutes into its hour is not cut short
 *  two hours later (2026-09-25). The slack is the backwash pauses, as
 *  RUN_SLACK_MIN in reports.py. */
const RUN_SLACK_MS = 30 * 60000;
const logReadAt = () => Math.min(serverNow(), irrig().timerLogAt || irrig().meta?.lastUpdated || serverNow());
const runEnd = (r) => (farmMs(r.start) ?? 0) + (r.planned || 0) * 60000 + RUN_SLACK_MS;
const mayStillRun = (r) => !r.finished && !r.ended && (r.going || (r.planned != null && runEnd(r) > logReadAt()));
/** When the log was read, as the farm's clock: "00:02". */
const readClock = () => new Date(logReadAt() + farmTz() * 60000).toISOString().slice(11, 16);
/** ", finished" / " so far" / ", cut short" after a run's amount; " by 00:02"
 *  once its time is up but the last read caught it part-way — "so far" would
 *  claim it is still going. */
const runOutcome = (r) => (r.finished ? ', finished' : !mayStillRun(r) ? ', cut short'
  : r.planned != null && runEnd(r) <= serverNow() ? ` by ${readClock()}` : ' so far');
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
               checked: p.at ? agoText(p.at) : '', valves: p.valves || '', left };
    }
  }
  const last = irrRuns()[0];
  if (last) {
    const bits = [];
    const a = runAmount(last);
    if (a) bits.push(a + runOutcome(last));
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
  if (!hb || !hb.lastSeen) return { ok: false, bridge: true, why: 'Valve control has not checked in yet.' };
  const ageSec = (serverNow() - hb.lastSeen) / 1000;
  if (hb.status === 'offline' || ageSec > (hb.heartbeatSeconds || 30) * STALE_FACTOR) {
    return { ok: false, bridge: true, why: 'Valve control is not answering right now.' };
  }
  if (hb.irrigationControl !== true) return { ok: false, why: 'Valve control is switched off at the farm.' };
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
  if (!window.confirm(`Water ${names.join(', ')} for ${mins} min?`)) return;
  runOpen = false; runPick = [];
  sendIrrigation({ action: 'run', valves: ids.join(','), minutes: mins });
}
function stopIrrigation() {
  if (!window.confirm('Stop the manual run? The controller closes the valves.')) return;
  sendIrrigation({ action: 'stop' });
}

/* ---- motor control: on and off, confirmed by the motor itself ----
 * docs/motor-control.md. Admins only, and only for a motor the service
 * account has armed (meta/motorControl/motors/<key>). A press appends one
 * command; the motor_command function re-checks everything, reads the motor,
 * sends once, never retries, and reads the motor until its own report shows
 * the change. Here the buttons stay closed while any motor change is in
 * flight (motor_lock), during the per-motor cooldown, and whenever the
 * reading is not current — nobody switches a motor off a stale picture. */
let motorCmd = null, motorCmdKey = null, motorCmdConfirming = false, motorCmdTimer = null;
let dbConnected = true;
const MOTOR_COOLDOWN_MS = 120000;
const motorArmed = (key) => isAdmin && state.meta?.motorControl?.enabled === true && state.meta.motorControl.motors?.[key] === true;
const zonesArmed = (key) => motorArmed(key) && state.meta.motorControl.zones?.[key] === true;
function motorRefusal(key, action = 'on') {
  const mc = state.meta?.motorControl || {};
  if (!isAdmin) return 'Only farm admins can switch motors.';
  if (!motorArmed(key)) return 'Switching this motor is turned off at the farm.';
  if (motorCmd) return motorCmdConfirming ? 'Sent once. Waiting for the motor to confirm…' : 'Sending…';
  if ((mc.lock?.until || 0) > serverNow()) return 'The last motor change is still being confirmed.';
  if (!dbConnected) return 'Offline. Motors are switched only over a live connection.';
  // Stopping is never held back by the cooldown; zones keep their own.
  const last = action === 'off' ? null : (action === 'zone' ? mc.lastZoneByMotor : mc.lastByMotor)?.[key];
  if (last && serverNow() - last < MOTOR_COOLDOWN_MS) {
    return `This motor changed moments ago. Wait ${Math.ceil((MOTOR_COOLDOWN_MS - (serverNow() - last)) / 1000)}s.`;
  }
  return null;
}
function motorByKey(key) {
  const w = state.water || {};
  return key === 'river' ? w.river : (w.motors || {})[key];
}
function confirmMotor(key, action) {
  const m = motorByKey(key);
  if (!m) return;
  const why = motorRefusal(key, action) || (!waterCurrent(m) ? 'The reading is not current. Refresh before switching a motor.' : '');
  if (why) { toast('err', why); render(); return; }
  if (action === 'on' ? m.running !== false : m.running !== true) { toast('err', 'The motor is not in the state that button was for.'); render(); return; }
  const name = m.name || 'the motor';
  const what = action === 'off'
    ? `Stop ${name}?` + (m.vendor === 'livesky' && m.autoStart ? ' Auto-start is on: the starter may start it again when power returns.' : '')
    : `Start ${name}?` + (m.role === 'drip' || m.program ? ' Its drip program starts with it; the controller picks the zones.'
      : m.role === 'main-farm' ? ' It sends water to the main farm.' : m.vendor === 'livesky' ? ' It pumps river water to the other farm.' : '');
  if (!window.confirm(`${what}\n\nSNOF sends it once and waits for the motor to confirm (up to 2½ minutes).`)) return;
  sendMotor(key, action);
}
function sendMotor(key, action, zone = null) {
  const why = motorRefusal(key, action);
  if (why) { toast('err', why); render(); return; }
  const ref = firebase.database().ref(`farms/${FARM}/motor_commands`).push();
  motorCmd = ref.key; motorCmdKey = key; motorCmdConfirming = false;
  clearTimeout(motorCmdTimer);
  // Sending plus the function's 150 s of confirmation reads.
  motorCmdTimer = setTimeout(() => {
    if (motorCmd !== ref.key) return;
    motorCmd = null; motorCmdConfirming = false;
    toast('err', 'No answer about the motor. Check it before trying again.');
    render();
  }, 240000);
  // clientAt: the press, on the server's clock; a write that arrives more
  // than 30 s later (queued offline) is refused by the rules and the function.
  const node = { motor: key, action, uid: currentUser.uid, at: firebase.database.ServerValue.TIMESTAMP, clientAt: serverNow() };
  if (action === 'zone') node.zone = zone;
  ref.set(node, (err) => {
    if (!err) return;
    motorCmd = null; clearTimeout(motorCmdTimer);
    toast('err', err.code === 'PERMISSION_DENIED' ? 'The database refused that (switched off, or a change is in flight).' : `Could not send: ${err.message}`);
    render();
  });
  render();
}
function settleMotor(results) {
  const node = motorCmd && results ? results[motorCmd] : null;
  if (!node) return;
  if (node.ok && node.confirming === true) { motorCmdConfirming = true; return; }
  motorCmd = null; motorCmdConfirming = false; clearTimeout(motorCmdTimer);
  const name = motorByKey(node.motor)?.name || 'The motor';
  if (node.ok && node.verified === true) {
    toast('ok', node.action === 'zone' ? `Confirmed: ${name} is on zone ${node.zone}.` : `Confirmed: ${name} is ${node.action === 'on' ? 'running' : 'off'}.`);
  } else if (node.ok && node.action === 'zone') toast('err', `Sent once. ${cap(node.message || 'The controller has not confirmed it.')}`);
  else if (node.ok) toast('err', 'Sent once, but the motor has not confirmed it. Check it before trying again.');
  else toast('err', node.message ? `Not sent: ${node.message}` : 'The farm refused that.');
  requestWater(true);
}
/** Continue the running program from another zone (the zoned Niagara
 *  controller): only while it runs a program, never the current zone. */
function confirmZone(key, zone) {
  const m = motorByKey(key);
  if (!m || !zonesArmed(key)) return;
  const why = zoneRefusal({ ...m, key }) || (m.zone === zone ? `It is already on zone ${zone}.` : '');
  if (why) { toast('err', why); render(); return; }
  if (!window.confirm(`Move ${m.name || 'the motor'} from zone ${m.zone} to zone ${zone}?\n\nThe controller continues ${m.program} from zone ${zone}. SNOF sends it once and waits for the controller to confirm (up to 2½ minutes).`)) return;
  sendMotor(key, 'zone', zone);
}
/** Why no zone may be picked now, or ''. As the function: a program running,
 *  the controller heard from in the last 90 s, and 5+ minutes left on the
 *  current zone (or a natural advance could read as success). */
function zoneRefusal(m) {
  const liveAt = Date.parse(m.liveAt || '');
  const [h, mi, se] = String(m.zoneLeft || '').split(':').map(Number);
  const left = [h, mi, se].every(Number.isFinite) ? h * 3600 + mi * 60 + se : null;
  return motorRefusal(m.key, 'zone') || (!waterCurrent(m) ? 'The reading is not current. Refresh before changing zones.' : '')
    || (m.running !== true || !m.program || m.zone == null ? 'No program is running, so there is no zone to change.' : '')
    || (!Number.isFinite(liveAt) || serverNow() - liveAt > 90000 ? 'The controller has not reported in the last 90 s. Refresh first.' : '')
    || (left == null || left < 300 ? 'The current zone ends in under 5 minutes. Change it after the program moves on.' : '');
}
function zoneControls(m) {
  const key = m.key;
  if (!key || !zonesArmed(key) || m.running !== true || !m.program || m.zone == null) return '';
  const why = zoneRefusal(m);
  const closed = !!why;
  const chips = [1, 2, 3, 4, 5, 6, 7, 8].map((z) => `<button class="zchip${z === m.zone ? ' is-now' : ''}" data-act="motor-zone"` +
    ` data-motor="${escapeHtml(key)}" data-zone="${z}" aria-pressed="${z === m.zone}"${z === m.zone || closed ? ' disabled' : ''}>${z}</button>`).join('');
  return `<div class="wzones"><span class="wzones-label">Zone · ${escapeHtml(m.program)}</span><div class="zchips">${chips}</div>` +
    (why ? `<p class="more-note">${escapeHtml(why)}</p>` : '') + `</div>`;
}

/** The on/off control on a motor's card: only for an armed motor. */
function motorControls(m) {
  const key = m.key;
  if (!key || !motorArmed(key)) return '';
  const busy = motorCmd && motorCmdKey === key;
  const action = m.running ? 'off' : 'on';
  const why = motorRefusal(key, action) || (!waterCurrent(m) ? 'The reading is not current. Refresh before switching.' : '')
    || (m.running == null ? "The motor's state is unknown." : '');
  const label = busy ? (motorCmdConfirming ? 'Confirming…' : 'Sending…') : action === 'on' ? 'Turn on' : 'Turn off';
  return `<div class="now-actions wmotor-actions"><button class="btn ${action === 'on' ? 'btn-primary' : 'btn-danger'}" data-act="motor-cmd"` +
    ` data-motor="${escapeHtml(key)}" data-action="${action}"${why ? ' disabled' : ''}>${label}</button></div>` +
    (why ? `<p class="more-note${busy ? '' : ' note-off'}">${escapeHtml(why)}</p>` : '');
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
    const timer = setTimeout(() => finish('No answer from the farm yet. It shows up here when the controller replies.'), IRR_TIMEOUT_MS);
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
  // Why Refresh (and Run) are off, said once when the quiet bridge is both reasons.
  const rg = reportsGate(), vg = irrControlGate();
  const both = isAdmin && !rg.ok && rg.bridge && !vg.ok && vg.bridge;
  const readNote = canControl && !rg.ok
    ? `<p class="more-note note-off">${escapeHtml(both ? 'The bridge is not reporting in, so the controller cannot be read or sent a Run or Stop.' : rg.why)}</p>` : '';
  const controls = isAdmin ? `<div class="now-actions">
      <button class="btn btn-primary" data-act="run-open"${refusal || runOpen || (s.running && s.manual) || !valveRows().some(isIrrigationValve) ? ' disabled' : ''}>Run valves</button>
      ${s.running && s.manual ? `<button class="btn btn-danger" data-act="irr-stop"${refusal ? ' disabled' : ''}>Stop</button>` : ''}
    </div>
    ${irrPending ? `<p class="more-note">${irrConfirming ? 'Confirming with the controller…' : 'Sent. Waiting for the farm…'}</p>`
      : refusal && refusal !== 'Only farm admins can open or close valves.' && !both ? `<p class="more-note note-off">${escapeHtml(refusal)}</p>`
      : mobitechState().kind !== 'ok' ? `<p class="more-note note-off">${escapeHtml(mobitechState().text)}</p>`
      : s.running && s.manual ? '<p class="more-note">One manual run at a time.</p>' : ''}` : '';
  return `<section class="panel now${s.running ? ' is-on' : ''}" aria-label="Now">
    <div class="now-top">
      <p class="now-label"><span class="dot"></span>${s.running ? 'Watering now' : 'Not watering'}</p>
      ${s.checked ? `<span class="now-checked">checked ${escapeHtml(s.checked)}</span>` : ''}${refresh}
    </div>
    ${empty ? `<h2 class="now-title">No data yet</h2><p class="now-detail">${canControl ? 'Press Refresh to ask the controller.' : 'Nothing has been pulled yet.'}</p>`
      : `<h2 class="now-title">${escapeHtml(s.title)}</h2>${s.detail ? `<p class="now-detail">${escapeHtml(s.detail)}</p>` : ''}`}
    ${faults.map((f) => `<span class="tag tag-bad">${escapeHtml(f)}</span>`).join('')}
    ${next && next.name ? `<p class="now-next"><span>Next</span>${escapeHtml([next.name, next.plannedMin != null ? fmtMin(next.plannedMin) : ''].filter(Boolean).join(' · '))}</p>` : ''}
    ${controls}${readNote}
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
  // Only irrigation valves can be run: the tank, pumps and backwash are not
  // listed at all rather than shown greyed out.
  const pickRows = picking ? rows.filter(isIrrigationValve) : rows;
  const cells = pickRows.map((r) => {
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
    panelHead(picking ? `Pick up to ${IRR_MAX_VALVES} valves${runPick.length ? ` · ${runPick.length} picked` : ''}` : 'Valves', null) +
    `${bar}<div class="valve-grid">${cells}</div></section>`;
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
/** "12 Coco 1" -> 12; also "valve 12", which is what a report writes when
 *  its name lookup failed. */
const valveNo = (name) => { const m = /^(?:valve\s+)?(\d{1,2})\b/i.exec(String(name || '').trim()); return m ? Number(m[1]) : null; };

function cropBreakdown(day) {
  // The controller's own names and types, by number, so a report whose name
  // lookup failed ("valve 12") still reads as "12 Coco 1" with its picture.
  const byNo = new Map(valveRows().map((r) => [Number(r.id), r]));
  const runs = irrRuns().filter((r) => r.day === day && r.valves);
  const valves = new Map();
  for (const r of runs) {
    const cut = !r.finished && !mayStillRun(r);
    for (const raw of r.valves.split(/,\s*/).filter(Boolean)) {
      const no = valveNo(raw);
      const name = (no != null && byNo.get(no)?.name) || raw;
      const v = valves.get(name) || { name, no, min: 0, cut: 0, runs: 0, cutRuns: new Set() };
      v.min += r.delivered || 0; v.runs += 1; if (cut) { v.cut += 1; v.cutRuns.add(`${r.start}|${r.name}`); }
      valves.set(name, v);
    }
  }
  const crops = new Map();
  for (const v of valves.values()) {
    const art = valveArt(v.name, 'irrigation');
    const key = art && art !== 'backwash' ? art : `v:${v.name}`;
    const c = crops.get(key) || { key, art: art && art !== 'backwash' ? art : null,
      label: CROP_LABELS[art] || String(v.name).replace(/^\d+\s*/, '') || v.name, min: 0, cut: 0, valves: [], cutRuns: new Set() };
    // Valves of one crop can run in separate programs (Mango1, Mango2):
    // the crop shows its longest, and each valve keeps its own minutes.
    for (const id of v.cutRuns) c.cutRuns.add(id);
    c.min = Math.max(c.min, v.min); c.cut = c.cutRuns.size; c.valves.push(v);
    crops.set(key, c);
  }
  const watered = new Set([...valves.values()].map((v) => v.no).filter((n) => n != null));
  const dry = valveRows().filter((r) => isIrrigationValve(r) && !watered.has(Number(r.id))).map((r) => r.name);
  // The cache holds the newest runs only; if its oldest row is on this day,
  // earlier runs that day may be missing.
  const log = irrig().timerLog || [];
  const oldest = log.reduce((m, r) => (r.at && (!m || r.at < m) ? r.at : m), '');
  // The function keeps 150 runs; at the cap, earlier runs may be missing.
  const partial = log.length >= 150 && oldest.slice(0, 10) >= day;
  return { crops: [...crops.values()].sort((a, b) => b.min - a.min || a.label.localeCompare(b.label)), dry, runs, partial };
}

function irrCropsModule() {
  const now = serverNow(), today = farmDay(now), yesterday = farmDay(now - 864e5);
  const hasToday = irrRuns().some((r) => r.day === today && r.valves);
  const pick = cropDayPick || (hasToday ? 'today' : 'yesterday');
  const day = pick === 'today' ? today : yesterday;
  const { crops, dry, runs, partial } = cropBreakdown(day);
  const pumps = (irrig().motorLog || []).map(parsePumpDay).filter(Boolean);
  const pump = pumps.find((p) => p.day === day);
  if (!irrRuns().length && !pumps.length) return '';
  const seg = `<div class="seg seg-sm" role="group" aria-label="Which day">` +
    [['today', 'Today'], ['yesterday', 'Yesterday']].map(([k, l]) =>
      `<button data-act="crop-day" data-day="${k}" aria-pressed="${pick === k}">${l}</button>`).join('') + `</div>`;
  const water = runs.reduce((s, r) => s + (r.delivered || 0), 0);
  const fig = (v, label) => `<div class="fig"><span class="fig-v">${v}</span><span class="fig-l">${label}</span></div>`;
  const max = Math.max(1, ...crops.map((c) => c.min));
  const rows = crops.map((c) => {
    const same = c.valves.every((v) => v.min === c.valves[0].min);
    const valveText = same ? c.valves.map((v) => v.name).join(', ') : c.valves.map((v) => `${v.name} ${fmtMin(v.min)}`).join(', ');
    return `<div class="crop-row${c.cut ? ' is-cut' : ''}">
      ${c.art ? artImg(c.art, 'crop-art') : `<span class="crop-art crop-ico">${arrow('i-valve')}</span>`}
      <span class="crop-main"><span class="crop-name">${escapeHtml(c.label)}</span>
        <span class="crop-valves">${escapeHtml(valveText)}${c.cut ? ` · ${c.cut} cut short` : ''}</span>
        <span class="crop-bar"><i style="width:${(c.min / max * 100).toFixed(1)}%"></i></span></span>
      <span class="crop-min">${escapeHtml(fmtMin(c.min))}</span></div>`;
  }).join('');
  return `<section class="panel irr-mod watered" aria-label="Watered">
    <div class="panel-head"><h2 class="panel-title">Watered</h2>${irrChecked() ? `<span class="card-age">${escapeHtml(irrChecked())}</span>` : ''}${seg}</div>
    <div class="figs">${fig(runs.length, plural(runs.length, 'Run', 'Runs'))}${fig(fmtMin(water), 'Water')}` +
    (pump ? fig(fmtMin(pump.pumpMin), 'Pump') : '') + (pump?.kwh != null ? fig(`${Math.round(pump.kwh)}<small>kWh</small>`, 'Energy') : '') + `</div>` +
    (crops.length ? `<div class="crop-list">${rows}</div>` : `<p class="more-note crop-empty">Nothing watered ${pick === 'today' ? 'yet today' : 'yesterday'}.</p>`) +
    (partial ? `<p class="more-note crop-dry">Only the latest runs of this day are here. Refresh for the full day.</p>`
      : dry.length && crops.length ? `<p class="more-note crop-dry">Not watered: ${dry.map((n) => escapeHtml(n).replace(/ /g, '&nbsp;')).join(', ')}</p>` : '') +
    `</section>`;
}


function irrSupplyModule() {
  const s = irrSupply(), p = irrPressure();
  if (!s && !p) return '';
  const bars = s && s.v.length ? phaseBars(s.v) : '';
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
    `<div class="panel-head"><h2 class="panel-title">Pump &amp; power</h2>${irrChecked() ? `<span class="card-age">${escapeHtml(irrChecked())}</span>` : ''}</div>` +
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
    `<div class="irr-grid"><div class="irr-col">${irrNowModule()}${irrValvesModule()}</div>` +
    `<div class="irr-col">${irrSupplyModule()}</div></div>` + `<div class="irr-wide">${irrCropsModule()}</div>` +
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
  if (!currentUser || document.hidden || !waterGate().ok) return false;
  const now = Date.now();
  if (!force && now - waterAsked < WATER_ASK_MS - 2000) return false;
  if (force && now - waterAsked < 5000) return false;
  waterAsked = now;
  // A background refresh must never take the view down with it: this runs
  // inside render(), so anything it throws would stop the page updating.
  try {
    Promise.resolve(firebase.database().ref(`farms/${FARM}/water_requests`).push({
      uid: currentUser.uid, at: firebase.database.ServerValue.TIMESTAMP,
    })).catch(() => {});
  } catch (err) { console.warn('water refresh not sent', err); return false; }
  return true;
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

/** current: false for a reading that no longer says what the motor is
 *  doing now (waterCurrent): its last state, in grey. */
function motorStateTag(m, current = true) {
  if (m.running === true) return current ? `<span class="tag tag-on">Running</span>` : `<span class="tag">Running</span>`;
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
  // Timers are only true as of the controller's report: say when that was
  // once it is more than 15 minutes old.
  const reportAt = Date.parse(m.liveAt || m.reportedAt || '');
  const stale = Number.isFinite(reportAt) && serverNow() - reportAt > 15 * 60000;
  const timed = new Set(['Running for', 'Off for', 'Zone time left']);
  const headline = facts.filter(([k]) => mainKeys.has(k)).map(([k, v]) => [k, stale && timed.has(k) ? `${v} · as of ${agoText(reportAt)}` : v]);
  const details = facts.filter(([k]) => !mainKeys.has(k));

  const when = m.liveAt || m.reportedAt;
  const notes = [];
  const pend = motorPending(m);
  if (pend) notes.push(`<p class="more-note note-off">${escapeHtml(pend)}</p>`);
  if ((m.trips || []).length) notes.push(`<p class="more-note note-bad">Tripped: ${escapeHtml(m.trips.join(', '))}.</p>`);
  if (m.skippedZone != null) notes.push(`<p class="more-note note-bad">Zone ${m.skippedZone} was skipped: no valve feedback.</p>`);
  if (vendorErr) notes.push(`<p class="more-note note-off">${escapeHtml(vendorErr)}</p>`);
  const sub = [m.vendor === 'livesky' ? 'Livesky' : 'Niagara', WATER_ROLE[m.role] || m.group].filter(Boolean).join(' · ');
  // Green only on a current reading, as on Home.
  const live = m.running === true && waterCurrent(m);
  return `<article class="panel wmotor${live ? ' is-on' : ''}">
    <div class="wmotor-head">
      <img class="wmotor-art" src="/art/${live ? 'motor-on' : 'motor-off'}.png" alt="" width="44" height="44">
      <div class="wmotor-title"><h3>${escapeHtml(m.name || 'Motor')}</h3><p>${escapeHtml(sub)}</p></div>
      ${motorStateTag(m, waterCurrent(m))}
    </div>
    ${headline.length ? `<div class="mb-facts">${headline.map(([k, v]) => {
      const [main, asOf] = String(v).split(' · as of ');
      return `<div><span>${escapeHtml(k)}</span><strong>${escapeHtml(main)}</strong>${asOf ? `<em class="as-of">as of ${escapeHtml(asOf)}</em>` : ''}</div>`;
    }).join('')}</div>` : ''}
    ${notes.join('')}
    ${motorControls(m)}${zoneControls(m)}
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
  // Each motor with its key (the function's name for it: "river", or the
  // slug the water pull gives a Niagara controller).
  const motors = Object.entries(w.motors || {}).map(([key, m]) => ({ ...m, key }));
  const supply = motors.filter((m) => m.role === 'main-farm');
  const others = motors.filter((m) => m.role !== 'main-farm');
  const liveskyErr = st.livesky && st.livesky.ok === false ? st.livesky.error : '';
  const niagaraErr = st.niagara && st.niagara.ok === false ? st.niagara.error : '';
  const refresh = `<button class="btn btn-ghost btn-sm" data-act="water-refresh"${gate.ok ? '' : ' disabled'}>Refresh</button>`;

  const livesky = isAdmin ? liveskyState() : { kind: 'ok' };
  // Said once: the account note above the card already carries a session problem.
  const riverBody = w.river
    ? waterMotorCard({ ...w.river, key: 'river' }, liveskyErr && livesky.kind === 'ok' ? `${liveskyErr} Showing the last reading.` : '')
    : emptyBlock('No reading from the river motor', liveskyErr || 'It appears after the first pull.');
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
  // When it was read, and that it only reads: the owner asked why these
  // motors cannot be switched from here (2026-09-24).
  const canSwitch = isAdmin && state.meta?.motorControl?.enabled === true && Object.values(state.meta.motorControl.motors || {}).includes(true);
  return head('Water', `${w.pulledAt ? `Read ${agoText(w.pulledAt)}` : 'Not read yet'}${canSwitch ? '' : ' · read-only'}`, refresh) +
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
let adminEmail = '', adminTier = 'view';   // the add-a-person form, kept across rebuilds
function sendInvite() {
  if (!isAdmin) return;
  const emailInput = el('admin-add-email');
  const email = (emailInput?.value || adminEmail || '').trim().toLowerCase();
  const tier = (el('admin-add-tier')?.value || adminTier) === 'control' ? 'control' : 'view';
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
    adminEmail = ''; adminTier = 'view';
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
      <span class="row-meta">${escapeHtml(email || 'signed in, no email on record')}</span>
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
  if (!st.at) return { kind: 'none', text: 'SNOF is not signed in to Mobitech. Sign in so valve commands keep working.' };
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
      <input id="admin-add-email" type="email" placeholder="someone@example.com" autocomplete="off" spellcheck="false" value="${escapeHtml(adminEmail)}"></label>
    <label class="rep-field"><span>Access</span>
      <select id="admin-add-tier"><option value="view">View</option><option value="control"${adminTier === 'control' ? ' selected' : ''}>View + control</option></select></label>
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
    `<p class="more-note">Only the farm owner can make someone an admin.</p>`;
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

/** withDomain: off under a room section that already names the kind. */
function row(ent, withArea = false, withDomain = true) {
  const meta = [withArea ? areaName(ent.area) : withDomain ? humanDomain(ent.domain) : '', subtitle(ent).replace(/^ · /, '')]
    .filter(Boolean).join(' · ');
  return `<div class="row ${isBad(ent) ? 'is-bad' : isOn(ent) ? 'is-on' : ''}" data-key="${escapeHtml(ent.key)}">
    <span class="row-icon"><svg viewBox="0 0 24 24" class="ico ico-sm"><use href="#i-${iconFor(ent)}"/></svg></span>
    <span class="row-main">
      <span class="row-name" title="${escapeHtml(ent.name || ent.entity_id)}">${escapeHtml(ent.name || ent.entity_id)}</span>
      ${meta ? `<span class="row-meta">${escapeHtml(meta)}</span>` : ''}
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
    btn.onclick = () => {
      const who = state.acl?.directory?.[btn.dataset.uid]?.email || 'this person';
      if (window.confirm(`Remove all access for ${who}?`)) aclSet(btn.dataset.uid, 'none');
    };
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
  view.querySelectorAll('[data-act="attn-open"]').forEach((btn) => { btn.onclick = () => { attnOpen = !attnOpen; render(); }; });
  view.querySelectorAll('[data-act="attn-more"]').forEach((btn) => { btn.onclick = () => { attnAll = !attnAll; render(); }; });
  view.querySelectorAll('[data-act="crop-day"]').forEach((btn) => { btn.onclick = () => { cropDayPick = btn.dataset.day; render(); }; });
  view.querySelectorAll('[data-act="home-refresh"]').forEach((btn) => {
    btn.onclick = () => { requestWater(true); if (canControl) refreshIrrigation(); else toast('ok', 'Asked for fresh water readings.'); };
  });
  view.querySelectorAll('[data-act="irr-builder"]').forEach((a) => {
    a.onclick = (e) => { e.preventDefault(); irrBuilderOpen = !irrBuilderOpen; render(); };
  });
  view.querySelectorAll('[data-act="motor-cmd"]').forEach((btn) => {
    btn.onclick = () => confirmMotor(btn.dataset.motor, btn.dataset.action);
  });
  view.querySelectorAll('[data-act="motor-zone"]').forEach((btn) => {
    btn.onclick = () => confirmZone(btn.dataset.motor, Number(btn.dataset.zone));
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
    btn.onclick = () => { if (requestWater(true)) toast('ok', 'Asked the controllers for fresh readings.'); };
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

  // Typing into the add-a-person form holds live rebuilds, as the sign-in
  // fields do: the farm updates about once a second.
  for (const id of ['admin-add-email', 'admin-add-tier']) {
    const input = el(id);
    if (!input) continue;
    input.onfocus = beginInteract;
    input.oninput = input.onchange = () => { if (id === 'admin-add-email') adminEmail = input.value; else adminTier = input.value; };
    // Moving from the email to the tier keeps the hold; leaving the form ends it.
    input.onblur = () => setTimeout(() => {
      if (!['admin-add-email', 'admin-add-tier'].includes(document.activeElement?.id)) endInteract();
    }, 300);
  }
  view.querySelectorAll('[data-act="admin-invite"]').forEach((btn) => {
    btn.onclick = () => sendInvite();
  });
  view.querySelectorAll('[data-act="acl-cancel-invite"]').forEach((btn) => {
    btn.onclick = () => cancelInvite(btn.dataset.key);
  });
}

/* ---- formatting ---- */

/* Domains without a drawing of their own borrow the nearest one, not the
 * placeholder square, which reads as broken. */
const ICON_ALIAS = { alarm_control_panel: 'shield', remote: 'media_player', siren: 'alert', input_select: 'select', input_number: 'number' };
function iconName(domain) {
  const d = ICON_ALIAS[domain] || domain;
  return document.getElementById(`i-${d}`) ? d : 'default';
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
  if (isBad(ent)) return String(s);              // "unavailable", never "unavailable kWh"
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
  if (sec < 172800) return `${Math.round(sec / 3600)}h`;
  return `${Math.round(sec / 86400)}d`;
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
