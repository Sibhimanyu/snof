"""The Mobitech DCON HTTP API: the eight read calls reports use, and no others.

Every call goes to <base>/v1/http/. The command endpoint (/v1/command/, which
opens and closes valves) is not reachable from this class: there is no method
for it and no way to pass a path. Keep it that way — see reports.py.

Endpoints surveyed against the live controller on 2026-09-23. Besides these,
logs?method=valve_log answers (it is get_all_valve under another name) and
logs?method=flow_log answers with an empty list (no flow meter). Every other
report type tried — flow, energy, power, voltage, current, level, moisture… —
comes back "Invalid request parameter", and other log/node method names come
back empty. The data below is all there is.
"""
from __future__ import annotations

from typing import Any

import requests

TIMEOUT_SECONDS = 30


class DconError(RuntimeError):
    pass


class Dcon:
    def __init__(self, base: str, serial: str, token_id: str,
                 product: str = "DCON", session: requests.Session | None = None):
        if not (serial and token_id):
            raise DconError("DCON is not configured")
        self._url = base.rstrip("/") + "/v1/http/"
        self._serial = serial
        self._token = token_id
        self._product = product or "DCON"
        self._http = session or requests.Session()

    def _answer(self, what: str, resp: requests.Response) -> Any:
        if resp.status_code >= 400:
            raise DconError(f"DCON {what}: HTTP {resp.status_code}")
        try:
            body = resp.json()
        except ValueError:
            raise DconError(f"DCON {what}: not JSON") from None
        if isinstance(body, dict) and body.get("status") == "failed":
            raise DconError(f"DCON {what}: {str(body.get('reason') or 'refused')[:80]}")
        return body

    def _post(self, what: str, form: dict) -> Any:
        try:
            resp = self._http.post(self._url, data=form, timeout=TIMEOUT_SECONDS)
        except requests.RequestException as err:
            raise DconError(f"DCON {what}: {type(err).__name__}") from None
        return self._answer(what, resp)

    def _get(self, what: str, params: dict) -> Any:
        try:
            resp = self._http.get(self._url, params={**params, "serial_no": self._serial,
                                                     "product": self._product},
                                  timeout=TIMEOUT_SECONDS)
        except requests.RequestException as err:
            raise DconError(f"DCON {what}: {type(err).__name__}") from None
        return self._answer(what, resp)

    # ---- the calls ------------------------------------------------------

    def dashboard(self) -> Any:
        return self._post("dashboard", {"action": "dashboard", "p": "app",
                                        "token_id": self._token,
                                        "product": self._product})

    def nodes(self) -> Any:
        return self._post("get_node", {"action": "dcon_node", "method": "get_node",
                                       "serial_no": self._serial})

    def valves(self, start: str, end: str) -> Any:
        return self._post("get_all_valve", {"action": "dcon_node",
                                            "method": "get_all_valve",
                                            "from": start, "to": end,
                                            "serial_no": self._serial})

    def timer_log(self, start: str, end: str) -> Any:
        return self._post("timer_log", {"action": "logs", "method": "timer_log",
                                        "serial_no": self._serial,
                                        "from": start, "to": end})

    def motor_log(self, start: str, end: str) -> Any:
        return self._post("motor_log", {"action": "logs", "method": "motor_log",
                                        "serial_no": self._serial,
                                        "from": start, "to": end})

    def electricity(self, since: str) -> Any:
        return self._get("electricity", {"action": "reports", "type": "electricity",
                                         "dt": since})

    def pressure_now(self, since: str) -> Any:
        return self._get("pressure", {"action": "reports", "type": "pressure_cond",
                                      "dt": since})

    def pressure_range(self, start: str, end: str) -> Any:
        return self._get("pressure range", {"action": "reports",
                                            "type": "pressure_timer",
                                            "from": f"{start} 00:00:00",
                                            "to": f"{end} 23:59:59"})
