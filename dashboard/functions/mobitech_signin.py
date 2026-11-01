"""Signing SNOF in to Mobitech from the web dashboard (owner only).

    web ──ID token──▶ mobitech_session ──job──▶ /relay/jobs ──▶ NUC ──▶ Mobitech
                          │                      otp | login | prove
                          └─▶ /private/mobitech (token, no client reads)
                              farms/<slug>/mobitech_status (who, when)

The iOS app signs in directly; a browser cannot (Mobitech sends no CORS
header) and Google Cloud is refused, so the three sign-in calls go through the
farm's relay — an exception to "the NUC runs the bridge and nothing else",
owner's decision 2026-11-01 (docs/dcon-off-the-nuc.md). At cut-over to direct
calls this moves with the rest.

The function mints the device token itself, in the shape the app does
(Mobitech.deviceToken), so the token only ever travels function -> NUC ->
Mobitech and is never returned to the caller or logged. The code and the
number are never stored. Nothing here is scheduled.
"""
from __future__ import annotations

import re
import secrets
import time
from typing import Any, Callable

import dcon

SIGNIN_PATH = "private/mobitech_signin"      # {codeAt}; no client access
SESSION_PATH = "private/mobitech"            # {token, at, uid}
CODE_GAP_SECONDS = 30
SERVER_TIMESTAMP = {".sv": "timestamp"}
_ABC = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
TOKEN_SHAPE = re.compile(r"^[A-Za-z0-9_-]{22}:APA91b[A-Za-z0-9_-]{134}@ios$")
NO_BRIDGE = "The farm box is not answering, so Mobitech can't be reached."


def device_token(pick: Callable[[str], str] = secrets.choice) -> str:
    """Same shape as iOS Mobitech.deviceToken: 22 url-safe characters,
    ":APA91b", 134 more, "@ios"."""
    def run(n: int) -> str:
        return "".join(pick(_ABC) for _ in range(n))
    return f"{run(22)}:APA91b{run(134)}@ios"


def mobile10(raw: Any) -> str | None:
    digits = re.sub(r"\D", "", str(raw or ""))
    if len(digits) == 12 and digits.startswith("91"):
        digits = digits[2:]
    return digits if re.fullmatch(r"[6-9]\d{9}", digits) else None


def code_digits(raw: Any) -> str | None:
    code = "".join(ch for ch in str(raw or "") if ch.isdigit())
    return code if 4 <= len(code) <= 8 else None


def explain(err: Exception) -> str:
    """A DconError as one short line for the owner. The bridge being away is
    the likely case and gets its own words."""
    text = str(err)
    if "bridge did not answer" in text or "refused by the relay" in text:
        return NO_BRIDGE
    text = re.sub(r"^DCON \w+: ", "", text).strip()
    return f"Mobitech: {text}" if text else "Mobitech did not answer."


def send_code(store, src: "dcon.Dcon", mobile: str, now_ms: float | None = None) -> tuple[dict, int]:
    now_ms = time.time() * 1000 if now_ms is None else now_ms
    ref = store.reference(SIGNIN_PATH)
    last = (ref.get() or {}).get("codeAt") or 0
    if now_ms - last < CODE_GAP_SECONDS * 1000:
        return {"ok": False, "error": "A code was sent seconds ago. Wait for the SMS."}, 429
    ref.update({"codeAt": now_ms})
    try:
        answer = src.otp(mobile)
    except dcon.DconError as err:
        return {"ok": False, "error": explain(err)}, 502
    message = str(answer.get("message") or "") if isinstance(answer, dict) else ""
    if message not in ("", "Success"):
        return {"ok": False, "error": f"Mobitech: {message}"[:140]}, 502
    return {"ok": True}, 200


def verify(store, root: str, src: "dcon.Dcon", mobile: str, code: str, uid: str,
           mint: Callable[[], str] = device_token) -> tuple[dict, int]:
    token = mint()
    try:
        login = src.login(mobile, code, token)
        if not (isinstance(login, dict) and login.get("state") == "ok"):
            why = (login or {}).get("message") if isinstance(login, dict) else ""
            return {"ok": False, "error": f"Mobitech: {why or 'the code was not accepted'}"}, 502
        if login.get("idOk") is not True:
            return {"ok": False, "error": "Mobitech did not return a session."}, 502
        # Prove it before keeping it, as the app does: a dashboard read.
        proof = src.prove(token)
    except dcon.DconError as err:
        return {"ok": False, "error": explain(err)}, 502
    if not (isinstance(proof, dict) and proof.get("serves") is True):
        return {"ok": False,
                "error": "Signed in, but Mobitech would not serve the controller with it."}, 502
    name = str(login.get("name") or "")[:64]
    user = str(login.get("uname") or "")[:64]
    store.reference(SESSION_PATH).set({"token": token, "at": SERVER_TIMESTAMP, "uid": uid})
    # set(), not update(): a new session starts with no lastOk / lastRejected,
    # as the iOS app's sign-in does.
    store.reference(f"{root}/mobitech_status").set(
        {"at": SERVER_TIMESTAMP, "uid": uid, "name": name, "user": user,
         "mobileLast4": mobile[-4:]})
    return {"ok": True, "name": name or user}, 200
