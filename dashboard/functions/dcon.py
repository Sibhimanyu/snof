"""The Mobitech DCON read API: the eight calls reports use, and no others.

Two ways to make them:

* **Relay** (the default). Mobitech answers every Google Cloud address with
  HTTP 403 — tested from asia-southeast1 and asia-south1 on 2026-09-24 — so
  the Function cannot call it directly. It writes a *named* read to
  /relay/jobs, the bridge on the NUC makes it from the farm's own connection
  (addon/snof_bridge/bridge/relay.py), and the compressed answer comes back
  through /relay/results. /relay is outside /farms, so the RTDB rules'
  default deny keeps it away from every client. The job carries a call name
  and dates, never a URL, a serial or a token.
* **Direct**, kept for the day Mobitech stops refusing cloud addresses, or a
  proxy it accepts sits in between. Same eight calls, same spelling.

Either way the only endpoint is <base>/v1/http/. The vendor's write endpoint
is not reachable from this module: there is no method for it and no way to
pass a path. Keep it that way — see reports.py.

Besides these eight, the survey found logs?method=valve_log (get_all_valve
under another name) and logs?method=flow_log (always empty: no flow meter).
Every other report type tried comes back "Invalid request parameter".
"""
from __future__ import annotations

import base64
import gzip
import json
import time
from typing import Any

TIMEOUT_SECONDS = 30
# How long the Function waits for the NUC to answer one relayed read. Most
# come back in 1–3 s; a month of electricity packets takes longer.
RELAY_WAIT_SECONDS = 50.0
RELAY_POLL_SECONDS = 0.5
# The bridge reconnects a silent stream after 75 s and writes its heartbeat
# every 30 s; past these the relay is not listening, whatever Mobitech does.
RELAY_IDLE_LIMIT_SECONDS = 150
BRIDGE_SILENT_LIMIT_SECONDS = 180


class DconError(RuntimeError):
    pass


def _answer(what: str, status: int, text: str) -> Any:
    if status >= 400:
        raise DconError(f"DCON {what}: HTTP {status}")
    try:
        body = json.loads(text)
    except ValueError:
        raise DconError(f"DCON {what}: not JSON") from None
    if isinstance(body, dict) and body.get("status") == "failed":
        raise DconError(f"DCON {what}: {str(body.get('reason') or 'refused')[:80]}")
    # The dashboard says it differently: {"state": "failed", "message": …}.
    # Taken as data, it read as "nothing running" with a blank controller
    # (2026-09-25: the session had been signed in on another phone).
    if isinstance(body, dict) and body.get("state") == "failed":
        msg = str(body.get("message") or "refused")
        if "other mobile" in msg.lower() or "re-sign" in msg.lower():
            msg = "Mobitech signed this session out (the account was signed in on another phone)"
        raise DconError(f"DCON {what}: {msg[:120]}")
    return body


class DirectTransport:
    """Calls the controller API from wherever this code runs."""

    def __init__(self, base: str, serial: str, token_id: str,
                 product: str = "DCON", session=None):
        if not (serial and token_id):
            raise DconError("DCON is not configured")
        import requests

        self._url = base.rstrip("/") + "/v1/http/"
        self._serial, self._token, self._product = serial, token_id, product or "DCON"
        self._http = session or requests.Session()

    def _fields(self, call: str, args: dict) -> tuple[str, dict]:
        s, p = self._serial, self._product
        if call == "dashboard":
            return "POST", {"action": "dashboard", "p": "app", "token_id": self._token, "product": p}
        if call == "nodes":
            return "POST", {"action": "dcon_node", "method": "get_node", "serial_no": s}
        if call == "valves":
            return "POST", {"action": "dcon_node", "method": "get_all_valve",
                            "from": args["from"], "to": args["to"], "serial_no": s}
        if call in ("timer_log", "motor_log"):
            return "POST", {"action": "logs", "method": call, "serial_no": s,
                            "from": args["from"], "to": args["to"]}
        if call in ("electricity", "pressure_now"):
            return "GET", {"action": "reports",
                           "type": "electricity" if call == "electricity" else "pressure_cond",
                           "serial_no": s, "dt": args["since"], "product": p}
        if call == "pressure_range":
            return "GET", {"action": "reports", "type": "pressure_timer", "serial_no": s,
                           "from": f"{args['from']} 00:00:00", "to": f"{args['to']} 23:59:59",
                           "product": p}
        raise DconError(f"unknown call {call}")

    def call(self, call: str, args: dict) -> Any:
        import requests

        method, fields = self._fields(call, args)
        try:
            if method == "POST":
                resp = self._http.post(self._url, data=fields, timeout=TIMEOUT_SECONDS)
            else:
                resp = self._http.get(self._url, params=fields, timeout=TIMEOUT_SECONDS)
        except requests.RequestException as err:
            raise DconError(f"DCON {call}: {type(err).__name__}") from None
        return _answer(call, resp.status_code, resp.text)


class RelayTransport:
    """Asks the bridge on the NUC to make the call. `store` is firebase_admin's
    db module (or anything with .reference(path) -> push/get/delete)."""

    def __init__(self, store, wait: float = RELAY_WAIT_SECONDS,
                 poll: float = RELAY_POLL_SECONDS, clock=time.monotonic, sleep=time.sleep,
                 bridge_path: str | None = None):
        self._store, self._wait, self._poll = store, wait, poll
        self._clock, self._sleep = clock, sleep
        self._bridge_path = bridge_path

    def _not_listening(self) -> str:
        """Why the relay cannot be answering right now, or "" when it may be.
        Reads the bridge's own heartbeat; anything missing or unreadable means
        "may be" (an older add-on has no stream age), never a refusal."""
        if not self._bridge_path:
            return ""
        try:
            bridge = self._store.reference(self._bridge_path).get() or {}
        except Exception:          # noqa: BLE001 — the wait still decides
            return ""
        if not isinstance(bridge, dict):
            return ""
        seen = bridge.get("lastSeen")
        if isinstance(seen, (int, float)) and not isinstance(seen, bool):
            silent = time.time() - seen / 1000.0
            if silent > BRIDGE_SILENT_LIMIT_SECONDS:
                return f"the farm box has not reported for {int(silent // 60)} min"
        relay = bridge.get("relay")
        if isinstance(relay, dict) and relay.get("enabled") is False:
            return "the relay is switched off on the farm box"
        idle = relay.get("streamIdleSeconds") if isinstance(relay, dict) else None
        if isinstance(idle, (int, float)) and not isinstance(idle, bool) \
                and idle > RELAY_IDLE_LIMIT_SECONDS:
            return f"the relay has not been listening for {int(idle // 60)} min"
        return ""

    def call(self, call: str, args: dict) -> Any:
        why = self._not_listening()
        if why:
            raise DconError(f"DCON {call}: the farm's bridge did not answer — {why}")
        job = self._store.reference("relay/jobs").push(
            {"call": call, "args": args, "at": {".sv": "timestamp"}})
        result_ref = self._store.reference(f"relay/results/{job.key}")
        deadline = self._clock() + self._wait
        try:
            while self._clock() < deadline:
                result = result_ref.get()
                if result:
                    if not result.get("ok"):
                        raise DconError(f"DCON {call}: {result.get('error') or 'failed'}")
                    text = gzip.decompress(base64.b64decode(result.get("gz") or "")).decode("utf-8")
                    return _answer(call, int(result.get("status") or 200), text)
                self._sleep(self._poll)
            raise DconError(f"DCON {call}: the farm's bridge did not answer — "
                            "is the NUC online?")
        finally:
            # Whatever happened, neither node stays behind.
            for ref in (result_ref, self._store.reference(f"relay/jobs/{job.key}")):
                try:
                    ref.delete()
                except Exception:          # noqa: BLE001 — cleanup is best-effort
                    pass


class Dcon:
    """The eight reads, as the report builders call them."""

    def __init__(self, transport):
        self._t = transport

    def dashboard(self) -> Any:
        body = self._t.call("dashboard", {})
        # A dashboard names its controller (one node per serial). One with
        # none is not "nothing running": the relay used to trim a refusal to
        # {} (2026-09-26), and a controller that sent nothing is not idle.
        if not (isinstance(body, dict) and any(isinstance(v, dict) for v in body.values())):
            raise DconError("DCON dashboard: Mobitech sent no controller data")
        return body

    def nodes(self) -> Any:
        return self._t.call("nodes", {})

    def valves(self, start: str, end: str) -> Any:
        return self._t.call("valves", {"from": start, "to": end})

    def timer_log(self, start: str, end: str) -> Any:
        return self._t.call("timer_log", {"from": start, "to": end})

    def motor_log(self, start: str, end: str) -> Any:
        return self._t.call("motor_log", {"from": start, "to": end})

    def electricity(self, since: str) -> Any:
        return self._t.call("electricity", {"since": since})

    def pressure_now(self, since: str) -> Any:
        return self._t.call("pressure_now", {"since": since})

    def pressure_range(self, start: str, end: str) -> Any:
        return self._t.call("pressure_range", {"from": start, "to": end})
