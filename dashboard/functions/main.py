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
from firebase_functions import db_fn, options
from firebase_functions.params import SecretParam, StringParam

import dcon
import irrigation_control
import reports

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
    if patch:
        store.reference(f"{root}/irrigation").update(patch)
    store.reference(f"{root}/irrigation/meta").update(
        {"lastUpdated": reports.SERVER_TIMESTAMP, "lastType": rtype,
         "lastError": report.get("error", "")})
    _status(store, root, ok=report["status"] != "error",
            error=report.get("error", ""), rtype=rtype)
    _LOG.info("Irrigation report %s (%s): %s in %.1fs", req_id, rtype,
              report["status"], time.monotonic() - started)


def _status(store, root: str, ok: bool = False, error: str = "", rtype: str = "",
            refused: bool = False) -> None:
    """meta/reports: what the dashboard reads to say reports are live. A
    patch, so `enabled` — the kill switch — is never touched from here."""
    patch: dict[str, Any] = {"runtime": "cloud-functions",
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
