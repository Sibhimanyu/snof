"""The water chain: the river motor (Livesky) and the other farm's two motors
(Niagara), read into /farms/<farm>/water. Read-only.

    river ──[Livesky "River Motor"]──▶ other farm
                                        ├─[Niagara, "Water 7.5hp"]──▶ main farm (Mobitech DCON)
                                        └─[Niagara, "GROUP ONE"]───▶ that farm's own drip zones

Ground truth for both vendors is a mitmproxy capture of their iOS apps
(docs/livesky-app.md, docs/niagara-app.md). Both answer Google Cloud
addresses (probed 2026-09-24), so unlike Mobitech this needs no relay and no
static IP, and never touches the NUC.

Three rules, the same as vendors.py:

* **Allow-lists, never dumps.** Each parser names what it keeps. Livesky's
  state carries the modem's public IP and the account email; Niagara's
  carries the SIM number, the IMEI and "OPERATED BY:<phone>" inside its
  free-text message. None of it is kept, and scrub() redacts any 10+ digit
  run in whatever text is.
* **Ids are credentials.** Niagara has no authentication at all: its API
  answers anyone who knows the user and controller ids. They live in Secret
  Manager and in this process, never in the database: a motor is keyed by a
  slug of its name.
* **Confirm from the controller.** Niagara's `status` is only what the app
  last asked for; whether a motor runs comes from the controller's own
  report (liveMessage, msgcode/msgDesc). Livesky marks an unacknowledged
  change with "-inprogress".

Parsers are pure (vendor JSON in, plain dicts out) so tests/test_water.py
runs with nothing installed. Fetching is LiveskyClient / NiagaraClient;
pull() ties them to the database.
"""
from __future__ import annotations

import base64
import datetime as _dt
import json
import re
from typing import Any

from vendors import scrub

SERVER_TIMESTAMP = {".sv": "timestamp"}
FARM_TZ = _dt.timezone(_dt.timedelta(hours=5, minutes=30))

# /private is outside /farms, so no read grant reaches it; rules deny every
# client write. Only this function's service account reads or writes it.
LIVESKY_PATH = "private/livesky"
TIMEOUT = 20

# ---------------------------------------------------------------- Livesky

# dueto_* fields hold "<code>:<n>"; a non-zero n is why the starter tripped.
LIVESKY_TRIPS = {
    "dueto_low_volt": "low voltage",
    "dueto_high_volt": "high voltage",
    "dueto_different_volt": "voltage imbalance",
    "dueto_amps_problem": "current fault",
    "dueto_dry_load": "dry run",
    "dueto_overload": "overload",
}
_TIMER = re.compile(r":(\d{1,4}):(\d{2}):(\d{2})$")    # RUNT:003:16:04


def _num(value: Any) -> float | None:
    try:
        n = float(value)
    except (TypeError, ValueError):
        return None
    return n if n == n else None


def _clean_num(n: float | None) -> float | int | None:
    if n is None:
        return None
    return int(n) if n == int(n) else round(n, 1)


def timer_minutes(value: Any) -> int | None:
    """ "RUNT:003:16:04" -> 196 (hours:minutes:seconds, hours zero-padded)."""
    m = _TIMER.search(str(value or ""))
    if not m:
        return None
    return int(m.group(1)) * 60 + int(m.group(2))


def _code_value(value: Any) -> int:
    """ "DDL:0" -> 0, "DOL:1" -> 1; anything unreadable counts as 0."""
    try:
        return int(str(value).rsplit(":", 1)[-1])
    except (TypeError, ValueError):
        return 0


def farm_iso(stamp: str, fmt: str) -> str:
    """A farm-time stamp from a vendor -> ISO 8601 with +05:30, or ""."""
    try:
        return _dt.datetime.strptime(stamp.strip(), fmt).replace(tzinfo=FARM_TZ).isoformat()
    except (ValueError, AttributeError):
        return ""


def parse_livesky_motor(row: Any, device_name: str = "") -> dict:
    """One getMotors row -> the river motor's state. Allow-list."""
    if not isinstance(row, dict):
        return {}
    status = str(row.get("motor_status") or "")
    base = status.replace("-inprogress", "")
    running = True if base == "MOTORON" else False if base == "MOTOROFF" else None
    volts = [v for v in (_clean_num(_num(row.get(f"l{i}_volt"))) for i in (1, 2, 3)) if v is not None]
    amps = [a for a in (_clean_num(_num(row.get(f"l{i}_amps"))) for i in (1, 2, 3)) if a is not None]
    auto = str((row.get("auto_status_mobilemode") if row.get("mode") == "MOBILEMODE"
                else row.get("auto_status_manualmode")) or "").replace("-inprogress", "")
    # Any field still carrying "-inprogress" is a change the controller has
    # not acknowledged: a command is on its way (20-40 s in the capture).
    settling = any(isinstance(v, str) and v.endswith("-inprogress") for v in row.values())
    out = {
        "name": scrub(str(device_name or "River motor"))[:64],
        "vendor": "livesky",
        "running": running,
        "pending": status.endswith("-inprogress") or settling,
        "connected": row.get("connection_status") == "connected",
        "reportedAt": farm_iso(str(row.get("time") or ""), "%Y-%m-%d %H:%M:%S"),
        "volts": volts,
        "amps": amps,
        # Three-phase supply is there when the phases read like mains.
        "power": bool(volts) and min(volts) > 100,
        "runMinutes": timer_minutes(row.get("runtime")),
        "stopMinutes": timer_minutes(row.get("stop_timer")),
        # Auto-start on power return. Turning it back on while the motor is
        # off and power is present starts the motor (seen in the capture).
        "autoStart": auto.endswith("AUTOON") if auto else None,
        "trips": [label for key, label in LIVESKY_TRIPS.items() if _code_value(row.get(key))],
        "signal": _clean_num(_num(row.get("signal_strength"))),
    }
    return {k: v for k, v in out.items() if v is not None and v != ""}


def jwt_expiry(token: str) -> int | None:
    """The `exp` claim (seconds) of a JWT, unverified: only to know when the
    24-hour Livesky session ends. Never logs or returns the token."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        exp = json.loads(base64.urlsafe_b64decode(payload)).get("exp")
        return int(exp) if exp else None
    except (IndexError, ValueError, TypeError, AttributeError):
        return None


# ---------------------------------------------------------------- Niagara

# What each group does in the chain, from the owner's description
# (2026-09-24). Matched on the group name, lowercased; anything else is
# shown without a role rather than guessed.
NIAGARA_ROLES = {
    "water 7.5hp": "main-farm",       # sends water to the main farm
    "group one": "drip",              # the other farm's own drip zones
}
MSG_CODES = {"001": "Motor on", "020": "Motor off", "044": "Zone changed",
             "045": "Zone open", "114": "Zone skipped: no feedback"}
_CTRL_STAMP = re.compile(r"DATE=(\d{1,2}/\d{1,2}/\d{4})\s+TIME=(\d{1,2}:\d{1,2}:\d{1,2})")
_SKIPPED = re.compile(r"ZONE=(\d{1,3}) SKIPPED")
_ZONE = re.compile(r"(\d{1,3})")
_HMS = re.compile(r"^\d{2}:\d{2}:\d{2}$")


def slug(name: str) -> str:
    s = re.sub(r"[^a-z0-9]+", "-", str(name or "").lower()).strip("-")
    return s[:40] or "motor"


def _stamp(date: str, time: str) -> str:
    """ "24/9/2026", "22:4:4" -> ISO +05:30 (Niagara drops leading zeros)."""
    try:
        d, mo, y = (int(x) for x in date.split("/"))
        h, mi, s = (int(x) for x in time.split(":"))
        return _dt.datetime(y, mo, d, h, mi, s, tzinfo=FARM_TZ).isoformat()
    except (ValueError, AttributeError):
        return ""


def _motor_from_text(text: str) -> bool | None:
    t = re.sub(r"\s+", " ", text.upper())
    if "MOTOR ON" in t:
        return True
    if "MOTOR OFF" in t:
        return False
    return None


def parse_live_message(text: Any) -> dict:
    """The zoned controller's liveMessage CSV (docs/niagara-app.md).

    Positions, from real packets: 0 motor 1/0; 3 motor text; 5-7 phase-to-
    neutral volts; 11 and 13 phase currents (ctrlLatestMsg's C1 and C3);
    21 outlet pressure (matches ctrlLatestMsg's Pout, unit unstated).
    Only those. Position 12 is not a current on this controller: it read 0.0
    when C2 was 00.0 and 116.3 a packet later. Position 33 is a long number
    (never read)."""
    f = [p.strip() for p in str(text or "").split(",")]
    if len(f) < 22 or f[2] != "$L":
        return {}
    out: dict[str, Any] = {}
    if f[0] in ("0", "1"):
        out["running"] = f[0] == "1"
    else:
        on = _motor_from_text(f[3])
        if on is not None:
            out["running"] = on
    volts = [_clean_num(_num(v)) for v in f[5:8]]
    if all(v is not None for v in volts):
        out["volts"] = volts
    amps = [_clean_num(_num(f[11])), _clean_num(_num(f[13]))]
    if all(a is not None for a in amps):
        out["amps"] = amps
    p = _num(f[21])
    if p is not None:
        out["pressureOut"] = _clean_num(p)
    return out


def parse_niagara_controller(c: Any, group: str = "") -> tuple[str, dict] | None:
    """One controller from cluster/<group>/controller -> (slug, state).
    Allow-list: the ids, SIM, IMEI and the phone in ctrlLatestMsg are never
    read into the result."""
    if not isinstance(c, dict) or not c.get("deviceName"):
        return None
    name = str(c["deviceName"])[:64]
    code = str(c.get("msgcode") or "").strip()
    desc = re.sub(r"\s+", " ", str(c.get("msgDesc") or "")).strip()
    latest = str(c.get("ctrlLatestMsg") or "")
    live = parse_live_message(c.get("liveMessage"))

    # Running: the zoned controller says it in every live packet; zone events
    # (044/045/114) overwrite msgcode, so msgcode alone would lose it. The
    # 7.5 HP controller sends no live packet: its last motor report stands.
    running = live.get("running")
    if running is None:
        running = True if code == "001" else False if code == "020" else _motor_from_text(desc)

    m = _CTRL_STAMP.search(latest)
    out: dict[str, Any] = {
        "name": scrub(name),
        "group": scrub(str(group or ""))[:64],
        "role": NIAGARA_ROLES.get(str(group or "").strip().lower(), ""),
        "vendor": "niagara",
        "model": _clean_num(_num(c.get("model_Id"))),
        "running": running,
        # What the app last asked for. Not the motor's state: it flips the
        # moment a command is sent. A difference means one is on its way.
        "requested": {"1": True, "0": False}.get(str(c.get("status"))),
        "power": str(c.get("Power")) == "1",
        "supply": scrub(str(c.get("motorStatus") or ""))[:24],
        "event": scrub(desc or MSG_CODES.get(code, ""))[:80],
        "eventCode": code if re.fullmatch(r"\d{3}", code) else "",
        # The controller's clock (runs ~2 min ahead of the server).
        "reportedAt": _stamp(m.group(1), m.group(2)) if m else "",
        # The server's stamp of the last live packet (zoned controller only).
        "liveAt": _stamp(str(c.get("livesyncDate") or ""), str(c.get("livesyncTime") or "")),
    }
    for key in ("volts", "amps", "pressureOut"):
        if key in live:
            out[key] = live[key]
    program = str(c.get("programNo") or "")
    if re.fullmatch(r"P\d{1,2}", program):
        out["program"] = program
        zm = _ZONE.search(str(c.get("zoneNo") or ""))
        if zm:
            out["zone"] = int(zm.group(1))
        for src, dst in (("ZoneRunTime", "zoneRun"), ("zoneRemainingTime", "zoneLeft")):
            v = str(c.get(src) or "")
            if _HMS.match(v):
                out[dst] = v
    sk = _SKIPPED.search(latest)
    if code == "114" and sk:
        out["skippedZone"] = int(sk.group(1))
    return slug(name), {k: v for k, v in out.items() if v is not None and v != ""}


# ---------------------------------------------------------------- clients

class VendorError(Exception):
    pass


def _http():
    import requests  # lazily, so the parsers import with nothing installed
    return requests


class LiveskyClient:
    """gsm.liveskytech.com:3001. Bearer JWT, 24 h, from an SMS code."""

    def __init__(self, base: str, token: str = ""):
        self.base, self.token = base.rstrip("/"), token
        self.timeout = TIMEOUT

    def _get(self, path: str, **params) -> Any:
        r = _http().get(f"{self.base}{path}", params=params, timeout=self.timeout,
                        headers={"Authorization": f"Bearer {self.token}"} if self.token else {})
        if r.status_code == 401:
            raise VendorError("Livesky refused the session (signed out or expired).")
        if r.status_code != 200:
            raise VendorError(f"Livesky: HTTP {r.status_code}")
        try:
            return r.json()
        except ValueError as e:
            raise VendorError("Livesky: not JSON") from e

    def devices(self) -> list[dict]:
        """The account's own devices, the only source of the IMEI."""
        rows = self._get("/getimeis")
        return [r for r in rows if isinstance(r, dict) and r.get("imei")] if isinstance(rows, list) else []

    def motors(self, imei: str) -> list[dict]:
        rows = self._get("/getMotors", imei=imei)
        return rows if isinstance(rows, list) else []

    def send_code(self, mobile: str) -> None:
        r = _http().post(f"{self.base}/send_mobile_otp", json={"mobile_no": mobile, "dialingcode": "91"},
                         timeout=TIMEOUT)
        body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
        if r.status_code != 200 or body.get("output") != "Success":
            raise VendorError("Livesky did not send a code to that number.")

    def login(self, mobile: str, code: str) -> str:
        r = _http().get(f"{self.base}/otpuserlogin", timeout=TIMEOUT,
                        params={"mobile_no": mobile, "dialingcode": "91", "mobile_otp": code,
                                "app_version": "4.2.8"})
        body = r.json() if r.headers.get("content-type", "").startswith("application/json") else {}
        token = body.get("token") if isinstance(body, dict) else None
        if r.status_code != 200 or body.get("output") != "Success" or not token:
            raise VendorError("Livesky did not accept that code.")
        return str(token)


class NiagaraClient:
    """http://<host>:8080/api/v1. No authentication: ids in the path."""

    def __init__(self, base: str, user_id: str):
        self.base, self.user = base.rstrip("/"), user_id.strip()
        self.timeout = TIMEOUT

    def _get(self, path: str) -> Any:
        r = _http().get(f"{self.base}/{path}", timeout=self.timeout, headers={"deviceType": "web"})
        if r.status_code not in (200, 304):
            raise VendorError(f"Niagara: HTTP {r.status_code}")
        try:
            return r.json()
        except ValueError as e:
            raise VendorError("Niagara: not JSON") from e

    def groups(self) -> list[dict]:
        body = self._get(f"controller/user/{self.user}/cluster")
        return [g for g in (body.get("data") or []) if isinstance(g, dict)] if isinstance(body, dict) else []

    def controllers(self, group_id: Any) -> list[dict]:
        body = self._get(f"user/{self.user}/cluster/{int(group_id)}/controller")
        if not isinstance(body, dict) or body.get("code") != 200:
            return []          # 201 "No controllers in group"
        return [c for c in (body.get("data") or []) if isinstance(c, dict)]


# ---------------------------------------------------------------- pull

def read_river(store, livesky_base: str, now_s: float) -> tuple[dict | None, dict]:
    """(river state or None, status patch for meta/water/livesky)."""
    sess = store.reference(LIVESKY_PATH).get() or {}
    token = sess.get("token") if isinstance(sess, dict) else None
    if not token:
        return None, {"ok": False, "error": "Not signed in to Livesky."}
    exp = sess.get("exp") or jwt_expiry(token)
    if exp and exp <= now_s:
        return None, {"ok": False, "error": "The Livesky session has expired.", "expires": exp * 1000}
    client = LiveskyClient(livesky_base, token)
    try:
        imei, name = sess.get("imei"), sess.get("device") or ""
        if not imei:
            devices = client.devices()
            if not devices:
                return None, {"ok": False, "error": "The Livesky account lists no starter."}
            imei, name = str(devices[0]["imei"]), str(devices[0].get("device_name") or "")
            store.reference(LIVESKY_PATH).update({"imei": imei, "device": name[:64]})
        rows = client.motors(imei)
    except VendorError as e:
        return None, {"ok": False, "error": str(e)[:160]}
    except Exception as e:          # noqa: BLE001 — network: report, don't crash the pull
        return None, {"ok": False, "error": f"Livesky unreachable ({type(e).__name__})."}
    if not rows:
        return None, {"ok": False, "error": "Livesky returned no motor."}
    patch = {"ok": True, "error": ""}
    if exp:
        patch["expires"] = exp * 1000
    return parse_livesky_motor(rows[0], name), patch


def read_motors(niagara: NiagaraClient | None) -> tuple[dict | None, dict]:
    if niagara is None:
        return None, {"ok": False, "error": "Niagara is not configured."}
    motors: dict[str, dict] = {}
    try:
        for g in niagara.groups():
            gname = str(g.get("groupName") or "")
            for c in niagara.controllers(g.get("userGroupId")):
                parsed = parse_niagara_controller(c, gname)
                if parsed:
                    key, node = parsed
                    while key in motors:
                        key += "-2"
                    motors[key] = node
    except VendorError as e:
        return None, {"ok": False, "error": str(e)[:160]}
    except Exception as e:          # noqa: BLE001
        return None, {"ok": False, "error": f"Niagara unreachable ({type(e).__name__})."}
    return motors, {"ok": True, "error": ""}


def pull(store, root: str, livesky_base: str, niagara: NiagaraClient | None, now_s: float) -> dict:
    """Read both vendors and write what came back. A vendor that fails keeps
    its last good state (with its error beside it), so one outage does not
    blank the other farm."""
    river, lpatch = read_river(store, livesky_base, now_s)
    motors, npatch = read_motors(niagara)
    update: dict[str, Any] = {"pulledAt": SERVER_TIMESTAMP}
    if river is not None:
        update["river"] = river
    if motors is not None:
        update["motors"] = motors
    store.reference(f"{root}/water").update(update)
    status = {"lastPull": SERVER_TIMESTAMP, "runtime": "cloud-functions"}
    for vendor, patch in (("livesky", lpatch), ("niagara", npatch)):
        for k, v in patch.items():
            status[f"{vendor}/{k}"] = v
        if patch.get("ok"):
            status[f"{vendor}/at"] = SERVER_TIMESTAMP
    store.reference(f"{root}/meta/water").update(status)
    return {"river": river is not None, "motors": len(motors or {}),
            "livesky": lpatch.get("error", ""), "niagara": npatch.get("error", "")}


def mobile10(raw: Any) -> str | None:
    digits = re.sub(r"\D", "", str(raw or ""))
    if len(digits) == 12 and digits.startswith("91"):
        digits = digits[2:]
    return digits if re.fullmatch(r"[6-9]\d{9}", digits) else None


# Refreshes from open screens and the schedule share one pull: at most one
# every PULL_GAP_SECONDS, whoever asks. The vendor apps poll every 2-5 s
# while open; this never goes faster than one pull per 15 s.
PULL_GAP_SECONDS = 15


def claim_pull(store, root: str, now_ms: float, gap_s: float = PULL_GAP_SECONDS) -> bool:
    """Take the next pull slot, or say another pull just ran. A transaction,
    so two requests landing together cannot both reach the vendors."""
    won = {"ok": False}

    def txn(last):
        if isinstance(last, (int, float)) and now_ms - last < gap_s * 1000:
            won["ok"] = False
            return last
        won["ok"] = True
        return now_ms

    store.reference(f"{root}/meta/water/pullClaim").transaction(txn)
    return won["ok"]
