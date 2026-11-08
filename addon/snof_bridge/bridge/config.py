"""Add-on configuration.

Supervisor renders the user's add-on options to /data/options.json. When running
outside the Supervisor (local dev) we fall back to environment variables so the
bridge can be exercised against a real HA instance from a laptop.
"""
from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field
from pathlib import Path

OPTIONS_PATH = Path("/data/options.json")

_LOG_LEVELS = {
    "trace": logging.DEBUG,
    "debug": logging.DEBUG,
    "info": logging.INFO,
    "warning": logging.WARNING,
    "error": logging.ERROR,
}


@dataclass
class Config:
    firebase_db_url: str
    service_account_path: str
    farm_slug: str = "snof"
    farm_name: str = "Sibhi Natural Orchards and Farms"
    exclude_domains: frozenset[str] = frozenset()
    exclude_entities: frozenset[str] = frozenset()
    include_domains: frozenset[str] = frozenset()
    expose_location: bool = False
    min_interval_seconds: float = 2.0
    flush_interval_seconds: float = 1.0
    heartbeat_seconds: int = 30
    # Device control. Off unless the add-on options turn it on, and an
    # allow-list even then: this is the only inbound path to farm hardware.
    allow_control: bool = False
    control_domains: frozenset[str] = frozenset({"switch", "light", "fan", "input_boolean", "climate"})
    control_max_age_seconds: float = 120.0
    log_level: int = logging.INFO
    # DCON relay (bridge/relay.py). Mobitech refuses Google Cloud addresses, so
    # the report Function asks the NUC to make its read calls. Off unless
    # `dcon_relay` is true; the serial and token stay here, in the options.
    dcon_relay: bool = False
    dcon_base: str = "https://dcon.mobitechwireless.com"
    dcon_serial: str = field(default="", repr=False)
    dcon_token_id: str = field(default="", repr=False)
    dcon_product: str = "DCON"
    # Irrigation control (bridge/irrigation_control.py): start a manual run on
    # irrigation valves, or stop one. Off unless the options turn it on, and
    # then only with the command credential, device id and user slot all set.
    allow_irrigation_control: bool = False
    dcon_device_id: str = field(default="", repr=False)
    dcon_command_auth: str = field(default="", repr=False)
    dcon_user_slot: str = ""
    irrigation_max_minutes: int = 60
    # Start a saved program (ET01-…): a second switch on top of the one above,
    # off by default. Mobitech does not guard programs the way the valves are.
    allow_program_start: bool = False
    # Remote add-on update (bridge/updater.py). Off unless the options turn it on.
    allow_remote_update: bool = False

    # Resolved at construction, not user-facing.
    ha_ws_url: str = field(default="", repr=False)
    ha_token: str = field(default="", repr=False)

    @property
    def root(self) -> str:
        """RTDB prefix that every write lands under."""
        return f"farms/{self.farm_slug}"


def _raw_options() -> dict:
    if OPTIONS_PATH.is_file():
        return json.loads(OPTIONS_PATH.read_text())
    return {
        "firebase_db_url": os.environ.get("FIREBASE_DB_URL", ""),
        "service_account_path": os.environ.get("SERVICE_ACCOUNT_PATH", ""),
        "farm_slug": os.environ.get("FARM_SLUG", "snof"),
        "log_level": os.environ.get("LOG_LEVEL", "info"),
    }


def load() -> Config:
    opts = _raw_options()

    db_url = (opts.get("firebase_db_url") or "").strip().rstrip("/")
    if not db_url:
        raise SystemExit(
            "firebase_db_url is not set. Open the add-on Configuration tab and "
            "paste your Realtime Database URL (https://<db>.firebaseio.com)."
        )

    sa_path = (opts.get("service_account_path") or "").strip()
    if not Path(sa_path).is_file():
        raise SystemExit(
            f"Service account key not found at {sa_path!r}. Copy the JSON key into "
            f"the add-on config folder (/addon_configs/*_snof_bridge/) and make sure "
            f"service_account_path points at it."
        )

    # Inside the Supervisor the add-on reaches core through the internal proxy and
    # authenticates with the injected token, so no long-lived token is ever stored.
    token = os.environ.get("SUPERVISOR_TOKEN", "")
    if token:
        ws_url = "ws://supervisor/core/websocket"
    else:
        ws_url = os.environ.get("HA_WS_URL", "")
        token = os.environ.get("HA_TOKEN", "")
        if not ws_url or not token:
            raise SystemExit(
                "No SUPERVISOR_TOKEN present and HA_WS_URL/HA_TOKEN are unset. "
                "Run this as a Home Assistant add-on, or set both for local dev."
            )

    return Config(
        firebase_db_url=db_url,
        service_account_path=sa_path,
        farm_slug=opts.get("farm_slug") or "snof",
        farm_name=opts.get("farm_name") or "Sibhi Natural Orchards and Farms",
        exclude_domains=frozenset(opts.get("exclude_domains") or []),
        exclude_entities=frozenset(opts.get("exclude_entities") or []),
        include_domains=frozenset(opts.get("include_domains") or []),
        expose_location=bool(opts.get("expose_location", False)),
        min_interval_seconds=float(opts.get("min_interval_seconds", 2.0)),
        flush_interval_seconds=float(opts.get("flush_interval_seconds", 1.0)),
        heartbeat_seconds=int(opts.get("heartbeat_seconds", 30)),
        allow_control=bool(opts.get("allow_control", False)),
        control_domains=frozenset(opts.get("control_domains")
                                  or ["switch", "light", "fan", "input_boolean", "climate"]),
        control_max_age_seconds=float(opts.get("control_max_age_seconds", 120.0)),
        log_level=_LOG_LEVELS.get(str(opts.get("log_level", "info")).lower(), logging.INFO),
        dcon_relay=bool(opts.get("dcon_relay", False)),
        dcon_base=(opts.get("dcon_base") or "https://dcon.mobitechwireless.com").strip().rstrip("/"),
        dcon_serial=(opts.get("dcon_serial") or "").strip(),
        dcon_token_id=(opts.get("dcon_token_id") or "").strip(),
        dcon_product=(opts.get("dcon_product") or "DCON").strip(),
        allow_irrigation_control=bool(opts.get("allow_irrigation_control", False)),
        dcon_device_id=str(opts.get("dcon_device_id") or "").strip(),
        dcon_command_auth=(opts.get("dcon_command_auth") or "").strip(),
        dcon_user_slot=(opts.get("dcon_user_slot") or "").strip().upper(),
        irrigation_max_minutes=max(1, min(180, int(opts.get("irrigation_max_minutes", 60)))),
        allow_program_start=bool(opts.get("allow_program_start", False)),
        allow_remote_update=bool(opts.get("allow_remote_update", False)),
        ha_ws_url=ws_url,
        ha_token=token,
    )
