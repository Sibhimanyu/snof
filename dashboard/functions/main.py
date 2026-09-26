"""Cloud Function: answer one irrigation report request.

    dashboard / iOS                 this function                 Mobitech DCON
      append ──▶ /farms/snof/irrigation_requests/<id>
                        │ onValueCreated
                        ▼
                  validate ─▶ 1–3 named reads ─▶ /relay/jobs ─▶ NUC ─▶ /v1/http/
                        │      (answers come back through /relay/results)
                        │
      render ◀── /farms/snof/irrigation_reports/<id>   (+ /irrigation cache)
                  delete the request, whatever happened

Runs once per Generate press and never on a schedule, so an idle farm costs
nothing. It writes to irrigation_reports, irrigation and meta/reports, never
to irrigation_requests except to delete the node that triggered it — a
delete is not a create, so nothing here can re-trigger itself.

The DCON token and serial are Secret Manager secrets (DCON_TOKEN_ID,
DCON_SERIAL). They never reach the database or a client.

Kill switch: set /farms/snof/meta/reports/enabled to false (service account
only — clients cannot write meta) and every request is answered with a
plain "switched off" report instead of a vendor call. No redeploy needed.
"""
from __future__ import annotations

import logging
import os
import time
from typing import Any

from firebase_admin import db, initialize_app
from firebase_functions import db_fn, https_fn, options, scheduler_fn
from firebase_functions.params import SecretParam, StringParam

import dcon
import irrigation_control
import motor_control
import reports
import water

DCON_TOKEN_ID = SecretParam("DCON_TOKEN_ID")
DCON_SERIAL = SecretParam("DCON_SERIAL")
DCON_BASE = StringParam("DCON_BASE", default="https://dcon.mobitechwireless.com")
# The one farm this project serves. A controller can append under any
# /farms/<slug>, so the slug is checked rather than trusted.
FARM_SLUG = StringParam("FARM_SLUG", default="snof")
# "relay": the NUC makes the vendor calls (Mobitech refuses Google Cloud
# addresses — see dcon.py). "direct": this Function makes them itself, which
# is the target: the NUC is for the Home Assistant bridge only. Direct works
# once DCON_VPC_CONNECTOR routes egress through a static IP Mobitech allows.
DCON_TRANSPORT = StringParam("DCON_TRANSPORT", default="relay")
# Irrigation control's credentials: the Mobitech app's command authorization
# ("…@ios") and the controller's device id, both secrets; the user slot the
# command is sent as (A8 = sibhi) and the longest run allowed.
DCON_COMMAND_AUTH = SecretParam("DCON_COMMAND_AUTH")
DCON_DEVICE_ID = SecretParam("DCON_DEVICE_ID")
DCON_USER_SLOT = StringParam("DCON_USER_SLOT", default="A8")
IRRIGATION_MAX_MINUTES = StringParam("IRRIGATION_MAX_MINUTES", default="60")

# Static egress for Mobitech, which refuses every Google Cloud address unless
# allowlisted. A plain string at deploy time (the SDK does not take a param
# here), read from the per-machine functions/.env; unset, nothing changes.
_VPC = os.environ.get("DCON_VPC_CONNECTOR", "").strip()
_EGRESS = ({"vpc_connector": _VPC,
            "vpc_connector_egress_settings": options.VpcEgressSetting.ALL_TRAFFIC}
           if _VPC else {})

_LOG = logging.getLogger("irrigation")
_app = None


def _db():
    global _app
    if _app is None:
        _app = initialize_app()
    return db


@db_fn.on_value_created(
    reference="/farms/{farm}/irrigation_requests/{req}",
    instance="snof-live-default-rtdb",
    region="asia-southeast1",
    secrets=[DCON_TOKEN_ID, DCON_SERIAL],
    memory=options.MemoryOption.MB_512,
    **_EGRESS,
    # Up to three relayed reads, each allowed RELAY_WAIT_SECONDS.
    timeout_sec=180,
    # Requests arrive one press at a time. Two instances is headroom for two
    # people pressing at once, and a hard ceiling on what a runaway client
    # could cost.
    max_instances=2,
    concurrency=1,
)
def irrigation_report(event: db_fn.Event[Any]) -> None:
    farm, req_id = event.params["farm"], event.params["req"]
    if farm != FARM_SLUG.value:
        _LOG.warning("Ignored request %s for unknown farm %r", req_id, farm)
        _db().reference(f"farms/{farm}/irrigation_requests/{req_id}").delete()
        return
    root = f"farms/{farm}"
    store = _db()
    try:
        _handle(store, root, req_id, event.data)
    finally:
        # Refused, failed or fine, the node goes: a request left behind is
        # litter on the one client-writable path in this subtree.
        store.reference(f"{root}/irrigation_requests/{req_id}").delete()


def _handle(store, root: str, req_id: str, req: Any) -> None:
    report_ref = store.reference(f"{root}/irrigation_reports/{req_id}")
    # Triggers are at-least-once. A report already written means this is a
    # redelivery; do not pull the vendor twice.
    if report_ref.get(shallow=True) is not None:
        return
    try:
        rtype, params = reports.validate(req)
    except reports.Refused as why:
        _LOG.warning("Refused irrigation request %s: %s", req_id, why)
        _status(store, root, refused=True)
        return

    base = {"type": rtype, "label": reports.REPORT_LABELS[rtype], "params": params,
            "at": reports.SERVER_TIMESTAMP}
    if store.reference(f"{root}/meta/reports/enabled").get() is False:
        report_ref.set({**base, "status": "error", "summary": "", "sections": [],
                        "rows": [], "error": "Reports are switched off."})
        return

    started = time.monotonic()
    try:
        if DCON_TRANSPORT.value == "direct":
            transport = dcon.DirectTransport(DCON_BASE.value, DCON_SERIAL.value.strip(),
                                             DCON_TOKEN_ID.value.strip())
        else:
            transport = dcon.RelayTransport(store)
        src = dcon.Dcon(transport)
        report, patch = reports.build(rtype, params, src)
    except dcon.DconError as err:
        report, patch = {**base, "status": "error", "summary": "", "sections": [],
                         "rows": [], "error": str(err)[:200]}, {}
    report_ref.set(report)
    try:
        reports.prune_reports(store, root)
    except Exception:          # noqa: BLE001 — retention must never cost a report
        _LOG.exception("Could not prune old reports")
    if patch:
        store.reference(f"{root}/irrigation").update(patch)
    store.reference(f"{root}/irrigation/meta").update(
        {"lastUpdated": reports.SERVER_TIMESTAMP, "lastType": rtype,
         "lastError": report.get("error", "")})
    store.reference(f"{root}/irrigation/meta/errors/{rtype}").set(reports.read_error(report))
    _status(store, root, ok=report["status"] != "error",
            error=report.get("error", ""), rtype=rtype)
    _LOG.info("Irrigation report %s (%s): %s in %.1fs", req_id, rtype,
              report["status"], time.monotonic() - started)


def _status(store, root: str, ok: bool = False, error: str = "", rtype: str = "",
            refused: bool = False) -> None:
    """meta/reports: what the dashboard reads to say reports are live. A
    patch, so `enabled` — the kill switch — is never touched from here."""
    # transport: "relay" while controller reads go through the NUC (the apps
    # then close Refresh when the bridge is quiet), "direct" once the function
    # has a static egress IP Mobitech allowlists (docs/dcon-off-the-nuc.md).
    patch: dict[str, Any] = {"runtime": "cloud-functions", "transport": DCON_TRANSPORT.value,
                             "lastSeen": reports.SERVER_TIMESTAMP}
    if refused:
        patch["lastRefused"] = reports.SERVER_TIMESTAMP
    else:
        patch["lastType"] = rtype
        patch["lastError"] = error
        if ok:
            patch["lastOk"] = reports.SERVER_TIMESTAMP
    try:
        store.reference(f"{root}/meta/reports").update(patch)
    except Exception:          # noqa: BLE001 — status is best-effort
        _LOG.exception("Could not update meta/reports")


@db_fn.on_value_created(
    reference="/farms/{farm}/irrigation_commands/{cmd}",
    instance="snof-live-default-rtdb",
    region="asia-southeast1",
    secrets=[DCON_TOKEN_ID, DCON_SERIAL, DCON_COMMAND_AUTH, DCON_DEVICE_ID],
    memory=options.MemoryOption.MB_256,
    # Send, then up to 2 min of confirmation reads (irrigation_control.py).
    timeout_sec=200,
    # One at a time, ever: this operates valves. The once-only claim in the
    # database covers redelivery; a single instance covers ordering.
    max_instances=1,
    concurrency=1,
    **_EGRESS,
)
def irrigation_command(event: db_fn.Event[Any]) -> None:
    """Run or stop a manual irrigation run. Does nothing at all — the NUC
    still owns the queue — until meta/irrigationControl/enabled is true."""
    farm, cmd_id = event.params["farm"], event.params["cmd"]
    if farm != FARM_SLUG.value:
        return
    store = _db()
    root = f"farms/{farm}"
    try:
        max_minutes = max(1, min(180, int(IRRIGATION_MAX_MINUTES.value or 60)))
    except ValueError:
        max_minutes = 60

    def reads():
        # The dashboard checks the token like a command does: read with the
        # same session, SNOF's own when an admin has signed in.
        token = irrigation_control.pick_token(store.reference(irrigation_control.TOKEN_PATH).get(),
                                              DCON_TOKEN_ID.value) or DCON_TOKEN_ID.value.strip()
        return dcon.Dcon(dcon.DirectTransport(DCON_BASE.value, DCON_SERIAL.value.strip(), token))

    class _LazyReads:
        # Build the read client only if a command gets that far: a switched-off
        # function must not even touch the secrets' values.
        def nodes(self):
            return reads().nodes()

        def dashboard(self):
            return reads().dashboard()

    result = irrigation_control.handle(
        store, root, cmd_id, event.data, reads=_LazyReads(),
        # The session an admin created by signing in to Mobitech wins over the
        # secret, whose hand-copied session ends and cannot be renewed.
        commander_factory=lambda: irrigation_control.Commander(
            DCON_BASE.value, DCON_DEVICE_ID.value.strip(),
            irrigation_control.pick_token(store.reference(irrigation_control.TOKEN_PATH).get(),
                                          DCON_COMMAND_AUTH.value)),
        slot=DCON_USER_SLOT.value.strip(), max_minutes=max_minutes)
    if result is not None:
        _LOG.info("Irrigation command %s: %s %s", cmd_id,
                  "sent" if result.get("ok") else "not sent", result.get("message", ""))


# ---------------------------------------------------------------- water chain
#
# The river motor (Livesky) and the other farm's two motors (Niagara), read
# into /farms/<farm>/water. Read-only; docs/water.md. Both vendors answer
# Google Cloud addresses, so these call them directly, never through the NUC.
#
# Kill switch: /farms/<farm>/meta/water/enabled must be true (service account
# only). Off, nothing calls a vendor. Cost shape: one pull (1 Livesky + up to
# 4 Niagara GETs) every 10 minutes, plus at most one per 15 s while someone
# has the Water screen open. Refresh requests are deleted by the function
# that reads them, and a delete is not a create, so nothing re-triggers.

# Niagara has no authentication: the user id in the path is the credential,
# and the host is a bare IP. Both secrets. Livesky's session is a 24-hour JWT
# an admin creates by signing in (water_session), kept in /private/livesky.
NIAGARA_BASE = SecretParam("NIAGARA_BASE")
NIAGARA_USER_ID = SecretParam("NIAGARA_USER_ID")
LIVESKY_BASE = StringParam("LIVESKY_BASE", default="https://gsm.liveskytech.com:3001")


def _water_pull(store, root: str) -> dict | None:
    """Pull both vendors unless switched off or another pull just ran."""
    if store.reference(f"{root}/meta/water/enabled").get() is not True:
        return None
    if not water.claim_pull(store, root, time.time() * 1000):
        return None
    niagara = None
    if NIAGARA_BASE.value.strip() and NIAGARA_USER_ID.value.strip():
        niagara = water.NiagaraClient(NIAGARA_BASE.value.strip(), NIAGARA_USER_ID.value.strip())
    result = water.pull(store, root, LIVESKY_BASE.value, niagara, time.time())
    _LOG.info("Water pull: %s", result)
    return result


@db_fn.on_value_created(
    reference="/farms/{farm}/water_requests/{req}",
    instance="snof-live-default-rtdb",
    region="asia-southeast1",
    secrets=[NIAGARA_BASE, NIAGARA_USER_ID],
    memory=options.MemoryOption.MB_256,
    timeout_sec=60,
    # One pull at a time, and the claim spaces them 15 s apart: a screen left
    # open, or a client gone wrong, costs at most four pulls a minute.
    max_instances=1,
    concurrency=1,
)
def water_refresh(event: db_fn.Event[Any]) -> None:
    """Someone has the Water screen open: pull now, unless a pull just ran."""
    farm, req_id = event.params["farm"], event.params["req"]
    store = _db()
    try:
        if farm == FARM_SLUG.value:
            _water_pull(store, f"farms/{farm}")
    finally:
        store.reference(f"farms/{farm}/water_requests/{req_id}").delete()


@scheduler_fn.on_schedule(
    schedule="every 10 minutes",
    region="asia-southeast1",
    secrets=[NIAGARA_BASE, NIAGARA_USER_ID],
    memory=options.MemoryOption.MB_256,
    timeout_sec=60,
    max_instances=1,
)
def water_poll(event: scheduler_fn.ScheduledEvent) -> None:
    """Keep the water chain roughly current when nobody is looking."""
    store, root = _db(), f"farms/{FARM_SLUG.value}"
    _water_pull(store, root)
    # The apps close Refresh while reads are relayed and the bridge is quiet.
    # Written here too, not only after a report: at cut-over to direct with
    # the bridge down, no report would ever run to say so.
    try:
        store.reference(f"{root}/meta/reports").update({"transport": DCON_TRANSPORT.value})
    except Exception:          # noqa: BLE001 — best-effort, like _status
        _LOG.exception("Could not write meta/reports.transport")



# ---------------------------------------------------------------- motor control
#
# On and off for the river motor and the other farm's two motors: the one
# path, docs/motor-control.md. Triggered only by an admin's own append (the
# RTDB rules refuse everyone else, and refuse while switched off or while a
# change is in flight); nothing scheduled or automatic writes that queue.
# Cost shape: per press, one trigger, ~3 vendor reads before sending, one
# send, then at most 15 reads over 150 s. Nothing runs between presses.

@db_fn.on_value_created(
    reference="/farms/{farm}/motor_commands/{cmd}",
    instance="snof-live-default-rtdb",
    region="asia-southeast1",
    secrets=[NIAGARA_BASE, NIAGARA_USER_ID],
    memory=options.MemoryOption.MB_256,
    # Reads, one send, then up to 150 s of confirmation reads; the lock
    # (motor_control.LOCK_SECONDS) outlives this.
    timeout_sec=320,
    # One at a time, ever: this starts and stops pumps.
    max_instances=1,
    concurrency=1,
)
def motor_command(event: db_fn.Event[Any]) -> None:
    """Start or stop one motor, once, and confirm it from the motor itself."""
    farm, cmd_id = event.params["farm"], event.params["cmd"]
    if farm != FARM_SLUG.value:
        return
    store = _db()
    root = f"farms/{farm}"

    def motor_factory(motor: str):
        # Built only after every gate has passed: a refused command never
        # touches a vendor or a secret's value.
        if motor == motor_control.RIVER:
            return motor_control.LiveskyMotor(LIVESKY_BASE.value, store.reference(water.LIVESKY_PATH).get() or {})
        return motor_control.NiagaraMotor(NIAGARA_BASE.value.strip(), NIAGARA_USER_ID.value.strip(), motor)

    result = motor_control.handle(store, root, cmd_id, event.data, motor_factory=motor_factory)
    if result is not None:
        _LOG.info("Motor command %s: %s %s — %s", cmd_id, result.get("motor"), result.get("action"),
                  result.get("message", ""))

def _json(body: dict, status: int = 200) -> https_fn.Response:
    import json
    return https_fn.Response(json.dumps(body), status=status, content_type="application/json")


@https_fn.on_request(
    region="asia-southeast1",
    secrets=[NIAGARA_BASE, NIAGARA_USER_ID],
    memory=options.MemoryOption.MB_256,
    timeout_sec=60,
    max_instances=1,
    concurrency=1,
    cors=options.CorsOptions(cors_origins=["https://snof-live.web.app", "https://snof-live.firebaseapp.com"],
                             cors_methods=["post"]),
)
def water_session(req: https_fn.Request) -> https_fn.Response:
    """Sign SNOF in to Livesky with an SMS code, or out. Admins only.

    POST {"action": "send_code", "mobile"} | {"action": "verify", "mobile", "code"}
       | {"action": "sign_out"}, with the caller's Firebase ID token as
    Authorization: Bearer. The Livesky token goes to /private/livesky and is
    never returned; meta/water/livesky says who signed in and until when."""
    from firebase_admin import auth as fb_auth

    if req.method != "POST":
        return _json({"ok": False, "error": "POST only."}, 405)
    store = _db()
    header = req.headers.get("Authorization", "")
    try:
        uid = fb_auth.verify_id_token(header.removeprefix("Bearer ").strip())["uid"]
    except Exception:          # noqa: BLE001 — any failure is "not signed in"
        return _json({"ok": False, "error": "Sign in to SNOF first."}, 401)
    if store.reference(f"acl/admins/{uid}").get() is not True:
        return _json({"ok": False, "error": "Only farm admins can sign in to Livesky."}, 403)

    body = req.get_json(silent=True) or {}
    action = body.get("action")
    root = f"farms/{FARM_SLUG.value}"
    status = store.reference(f"{root}/meta/water/livesky")
    client = water.LiveskyClient(LIVESKY_BASE.value)

    if action == "sign_out":
        # Livesky's own logout revokes nothing (docs/livesky-app.md), so this
        # only stops SNOF using the session.
        store.reference(water.LIVESKY_PATH).delete()
        status.update({"signedInAt": None, "expires": None, "by": None, "mobileLast4": None,
                       "ok": False, "error": "Signed out of Livesky."})
        return _json({"ok": True})

    mobile = water.mobile10(body.get("mobile"))
    if not mobile:
        return _json({"ok": False, "error": "Enter the 10-digit mobile number on the Livesky account."}, 400)

    if action == "send_code":
        # One code per 30 s: each one is an SMS to the owner's phone.
        last = (status.get() or {}).get("codeAt") or 0
        if time.time() * 1000 - last < 30_000:
            return _json({"ok": False, "error": "A code was sent seconds ago. Wait for the SMS."}, 429)
        status.update({"codeAt": time.time() * 1000})
        try:
            client.send_code(mobile)
        except water.VendorError as e:
            return _json({"ok": False, "error": str(e)}, 502)
        except Exception as e:          # noqa: BLE001
            return _json({"ok": False, "error": f"Could not reach Livesky ({type(e).__name__})."}, 502)
        return _json({"ok": True})

    if action == "verify":
        code = "".join(ch for ch in str(body.get("code") or "") if ch.isdigit())
        if not 4 <= len(code) <= 8:
            return _json({"ok": False, "error": "Enter the code from the SMS."}, 400)
        try:
            token = client.login(mobile, code)
            # Prove the session before keeping it: list the account's starters
            # (read-only), which is also where the IMEI comes from.
            devices = water.LiveskyClient(LIVESKY_BASE.value, token).devices()
        except water.VendorError as e:
            return _json({"ok": False, "error": str(e)}, 502)
        except Exception as e:          # noqa: BLE001
            return _json({"ok": False, "error": f"Could not reach Livesky ({type(e).__name__})."}, 502)
        if not devices:
            return _json({"ok": False, "error": "Signed in, but the account lists no starter."}, 502)
        exp = water.jwt_expiry(token)
        device = str(devices[0].get("device_name") or "")[:64]
        store.reference(water.LIVESKY_PATH).set({
            "token": token, "exp": exp, "imei": str(devices[0]["imei"]), "device": device,
            "at": reports.SERVER_TIMESTAMP, "uid": uid})
        status.update({"signedInAt": reports.SERVER_TIMESTAMP, "expires": (exp or 0) * 1000 or None,
                       "by": uid, "mobileLast4": mobile[-4:], "ok": True, "error": ""})
        try:
            _water_pull(store, root)
        except Exception:          # noqa: BLE001 — the sign-in stands either way
            _LOG.exception("Water pull after Livesky sign-in failed")
        return _json({"ok": True, "expires": (exp or 0) * 1000, "device": water.scrub(device)})

    return _json({"ok": False, "error": "Unknown action."}, 400)
