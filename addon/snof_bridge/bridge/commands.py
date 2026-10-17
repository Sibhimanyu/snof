"""Command consumer: the one path from the dashboard back to the farm.

The dashboard cannot talk to Home Assistant. All it can do is append a node to
/farms/<slug>/commands, which RTDB rules restrict to allowlisted controllers and
to a fixed shape. This module streams that queue, re-checks every command against
its own allow-list, calls the matching Home Assistant service, and deletes the
node. Nothing is executed twice and nothing survives in the queue.

Defence in depth, because this is the only inbound path that exists:
  * `allow_control` is off unless the add-on options turn it on
  * `control_domains` is an allow-list, never a deny-list
  * only entities in a room are operable - the same check that decides what is
    published, so nothing a user cannot see can be switched
  * commands older than `control_max_age_seconds` are dropped, not run, so a
    queue that piles up while the bridge is down does not fire all at once when
    it comes back
  * a command is deleted whether it ran or was refused, so a bad one cannot loop
"""
from __future__ import annotations

import asyncio
import json
import logging
import re
import time
from typing import TYPE_CHECKING, Any

from .wire import STREAM_READ_TIMEOUT_SECONDS

if TYPE_CHECKING:          # aiohttp is imported where it is used, so the pure
    import aiohttp         # validation logic stays testable with no deps installed.

_LOGGER = logging.getLogger(__name__)

# Services the bridge will ever call, per domain. Anything else is refused even
# if it somehow got past the database rules.
ALLOWED_SERVICES = {
    "switch": {"turn_on", "turn_off", "toggle"},
    "light": {"turn_on", "turn_off", "toggle"},
    "fan": {"turn_on", "turn_off", "toggle", "set_percentage"},
    "input_boolean": {"turn_on", "turn_off", "toggle"},
    # The ACs (owner, 2026-09-25): power, target temperature, mode, fan speed
    # and preset. Nothing else — no swing, no humidity, no scheduling.
    "climate": {"turn_on", "turn_off", "set_temperature", "set_hvac_mode",
                "set_fan_mode", "set_preset_mode"},
}

# Service-data keys we forward, with the range Home Assistant expects.
ALLOWED_DATA = {
    "brightness": (0, 255),
    "percentage": (0, 100),
    # °C. Home Assistant also refuses anything outside the AC's own
    # min_temp/max_temp (16–30 on the farm's Samsungs); this is the outer fence.
    "temperature": (10, 35),
}

# Service-data keys that are words, each with what a word may be. hvac_mode is
# Home Assistant's fixed set; fan and preset names are the AC's own, so they
# are held to a plain token here and Home Assistant refuses one the AC lacks.
HVAC_MODES = frozenset({"off", "heat", "cool", "heat_cool", "auto", "dry", "fan_only"})
_TOKEN = re.compile(r"^[a-z0-9_]{1,32}$")
ALLOWED_WORDS = {
    "hvac_mode": HVAC_MODES.__contains__,
    "fan_mode": lambda v: bool(_TOKEN.match(v)),
    "preset_mode": lambda v: bool(_TOKEN.match(v)),
}

# Which data keys each domain may carry at all: brightness is for lights,
# percentage for fans, the rest for ACs.
DOMAIN_DATA = {
    "light": {"brightness"},
    "fan": {"percentage"},
    "climate": {"temperature", "hvac_mode", "fan_mode", "preset_mode"},
}

# A climate service carries exactly its one value, and nothing else.
SERVICE_DATA = {
    ("climate", "set_temperature"): "temperature",
    ("climate", "set_hvac_mode"): "hvac_mode",
    ("climate", "set_fan_mode"): "fan_mode",
    ("climate", "set_preset_mode"): "preset_mode",
}

STREAM_RETRY_SECONDS = 5.0

# Ids of commands already handled, so a re-delivered snapshot cannot run one
# twice. Bounded because this process runs for months: a command is deleted from
# RTDB as soon as it is handled, so an id can only be re-delivered within one
# stream's lifetime, and far fewer than this many arrive in that window.
SEEN_LIMIT = 2048


class CommandConsumer:
    def __init__(self, cfg, rtdb, get_ha, session: aiohttp.ClientSession,
                 is_visible=None) -> None:
        self._cfg = cfg
        # entity_id -> bool: is this entity in a room, i.e. published at all?
        # Required in production; None only in tests that do not exercise it,
        # and then everything is refused rather than everything allowed.
        self._is_visible = is_visible or (lambda _eid: False)
        self._rtdb = rtdb
        self._get_ha = get_ha          # callable -> HAClient | None, re-read every time
        self._session = session
        self._seen: list[str] = []     # handled ids, newest last; see SEEN_LIMIT
        self.executed = 0
        self.refused = 0

    # ---- validation -------------------------------------------------------

    def _reject(self, cmd_id: str, reason: str, cmd: Any) -> None:
        self.refused += 1
        _LOGGER.warning("Refused command %s (%s): %r", cmd_id, reason, cmd)

    def validate(self, cmd_id: str, cmd: Any) -> tuple[str, str, dict] | None:
        """Return (domain, service, service_data) for a command worth running."""
        if not isinstance(cmd, dict):
            self._reject(cmd_id, "not an object", cmd)
            return None

        entity_id = cmd.get("entity_id")
        domain = cmd.get("domain")
        service = cmd.get("service")
        if not isinstance(entity_id, str) or not isinstance(domain, str) or not isinstance(service, str):
            self._reject(cmd_id, "missing fields", cmd)
            return None
        if domain not in self._cfg.control_domains:
            self._reject(cmd_id, f"domain {domain!r} not enabled", cmd)
            return None
        if service not in ALLOWED_SERVICES.get(domain, frozenset()):
            self._reject(cmd_id, f"service {service!r} not allowed for {domain}", cmd)
            return None
        if not entity_id.startswith(f"{domain}."):
            self._reject(cmd_id, "entity_id does not match domain", cmd)
            return None
        # An entity with no room is invisible to every user, so a command for
        # one was not made by pressing anything in the app. Refuse it.
        if not self._is_visible(entity_id):
            self._reject(cmd_id, "entity is not in a room", cmd)
            return None

        at = cmd.get("at")
        if not isinstance(at, (int, float)):
            self._reject(cmd_id, "no timestamp", cmd)
            return None
        age = time.time() - (at / 1000.0)
        # Negative age means the writer's clock ran ahead of ours; a small skew is
        # normal, a large one is not something to act on.
        if age > self._cfg.control_max_age_seconds or age < -60:
            self._reject(cmd_id, f"stale by {age:.0f}s", cmd)
            return None

        data: dict = {}
        raw = cmd.get("data") or {}
        if not isinstance(raw, dict):
            self._reject(cmd_id, "data is not an object", cmd)
            return None
        for key, value in raw.items():
            if key not in DOMAIN_DATA.get(domain, ()):
                self._reject(cmd_id, f"unexpected data key {key!r} for {domain}", cmd)
                return None
            if key in ALLOWED_WORDS:
                if not isinstance(value, str) or not ALLOWED_WORDS[key](value):
                    self._reject(cmd_id, f"{key}={value!r} is not allowed", cmd)
                    return None
            else:
                bounds = ALLOWED_DATA[key]
                if not isinstance(value, (int, float)) or isinstance(value, bool):
                    self._reject(cmd_id, f"{key} is not a number", cmd)
                    return None
                low, high = bounds
                if not (low <= value <= high):
                    self._reject(cmd_id, f"{key}={value} out of range", cmd)
                    return None
            data[key] = value

        need = SERVICE_DATA.get((domain, service))
        if need is not None and set(data) != {need}:
            self._reject(cmd_id, f"{service} takes {need} and nothing else", cmd)
            return None
        if domain == "climate" and need is None and data:
            self._reject(cmd_id, f"{service} takes no data", cmd)
            return None

        return domain, service, data

    # ---- execution --------------------------------------------------------

    async def handle(self, cmd_id: str, cmd: Any) -> None:
        if cmd is None or cmd_id in self._seen:
            return
        self._seen.append(cmd_id)
        if len(self._seen) > SEEN_LIMIT:
            del self._seen[: len(self._seen) - SEEN_LIMIT]
        checked = self.validate(cmd_id, cmd)
        try:
            if checked is not None:
                domain, service, data = checked
                ha = self._get_ha()
                if ha is None:
                    _LOGGER.warning("Dropping command %s: no Home Assistant connection", cmd_id)
                    # Let it retry when the stream next redelivers the queue.
                    if cmd_id in self._seen:
                        self._seen.remove(cmd_id)
                    return
                await ha.call_service(domain, service, cmd["entity_id"], data)
                self.executed += 1
                _LOGGER.info("Ran %s.%s on %s%s", domain, service, cmd["entity_id"],
                             f" {data}" if data else "")
        except Exception:
            _LOGGER.exception("Command %s failed", cmd_id)
        finally:
            # Refused or failed, the node still goes: a command left in the queue
            # would be retried on every reconnect.
            if cmd_id in self._seen:
                try:
                    await self._rtdb.put(f"{self._cfg.root}/commands/{cmd_id}", None)
                except Exception:
                    _LOGGER.exception("Could not clear command %s", cmd_id)

    async def _dispatch(self, path: str, data: Any) -> None:
        """Translate one RTDB stream event into zero or more commands."""
        path = (path or "/").strip("/")
        if not path:
            # Whole-queue snapshot: everything currently waiting.
            for cmd_id, cmd in (data or {}).items():
                await self.handle(cmd_id, cmd)
        elif "/" not in path:
            await self.handle(path, data)
        # Deeper paths only ever appear for a node we are already deleting.

    # ---- stream -----------------------------------------------------------

    async def _purge_queue(self) -> None:
        """Drop whatever is sitting in the queue when control is switched off.

        /commands is the one client-writable path in the tree and only this
        consumer deletes from it. With control off, a toggle pressed in the
        dashboard left its command there forever: three unexecuted turn_on
        commands for one switch were found in production on 2026-09-23. They
        could never have run anyway — they are long past control_max_age_seconds
        by the time anyone arms control, and the consumer would refuse them as
        stale. One read, one delete, at startup."""
        path = f"{self._cfg.root}/commands"
        try:
            existing = await self._rtdb.get(path, shallow=True)
        except Exception:
            _LOGGER.debug("Could not read the command queue to purge it",
                          exc_info=True)
            return
        if not existing:
            return
        try:
            await self._rtdb.put(path, None)
            _LOGGER.info("Control is off: dropped %d queued command(s) that "
                         "nothing would have executed", len(existing))
        except Exception:
            _LOGGER.warning("Could not clear the command queue")

    async def run(self) -> None:
        if not self._cfg.allow_control:
            _LOGGER.info("Device control is disabled; not watching the command queue")
            await self._purge_queue()
            return
        _LOGGER.info("Watching command queue for domains: %s",
                     ", ".join(sorted(self._cfg.control_domains)))
        while True:
            try:
                await self._stream_once()
            except asyncio.CancelledError:
                raise
            except Exception as err:
                _LOGGER.error("Command stream error: %s", err or type(err).__name__)
            await asyncio.sleep(STREAM_RETRY_SECONDS)

    async def _stream_once(self) -> None:
        import aiohttp

        url = f"{self._cfg.firebase_db_url}/{self._cfg.root}/commands.json"
        token = await self._rtdb._token()
        headers = {"Authorization": f"Bearer {token}", "Accept": "text/event-stream"}
        # No total timeout (the stream is idle by design), but RTDB's keep-alive
        # arrives every ~30 s, so a silent socket is a dead one: sock_read
        # raises and the retry loop reconnects.
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=30,
                                        sock_read=STREAM_READ_TIMEOUT_SECONDS)

        async with self._session.get(url, headers=headers, timeout=timeout,
                                     allow_redirects=True) as resp:
            if resp.status >= 400:
                raise RuntimeError(f"command stream -> {resp.status}: {(await resp.text())[:200]}")
            _LOGGER.info("Command queue stream open")
            event = ""
            async for raw in resp.content:
                line = raw.decode("utf-8", "replace").rstrip("\r\n")
                if line.startswith("event:"):
                    event = line[6:].strip()
                elif line.startswith("data:"):
                    payload = line[5:].strip()
                    if event in ("put", "patch") and payload and payload != "null":
                        try:
                            body = json.loads(payload)
                        except ValueError:
                            _LOGGER.warning("Unparseable command stream payload")
                            continue
                        await self._dispatch(body.get("path"), body.get("data"))
                    elif event == "auth_revoked":
                        _LOGGER.info("Stream token expired; reconnecting")
                        return
