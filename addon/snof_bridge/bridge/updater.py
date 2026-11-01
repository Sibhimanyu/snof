"""Remote add-on update: the fourth writable path, admins only.

An admin presses "Update" in the web or iOS app, which appends `{uid, at}` to
/farms/<slug>/addon_update_requests. This module streams that queue, re-checks
every request, and asks the Supervisor to update THIS add-on. It also keeps the
running/latest version published in the heartbeat, so the apps know there is
something to press.

Gates, all of which must hold:
  1. RTDB rules: only acl/admins/<uid> may append, uid == auth.uid, at == now.
  2. This consumer: re-reads acl/admins/<uid> with the service account, drops a
     request older than MAX_AGE_SECONDS, deletes every node whether it ran or
     not, acts only if the Supervisor says an update exists, and allows one
     update per UPDATE_COOLDOWN_SECONDS.
  3. `allow_remote_update` in the add-on options, off by default.

The Supervisor stops this container mid-update; that is expected. The next
start settles the `meta/bridge/update` node (`finish_state`). The Supervisor
token is only ever sent to http://supervisor and never logged.

Pure decisions live at the top (no aiohttp), so tests/test_logic.py can run them.
"""
from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from typing import Any

from .wire import STREAM_READ_TIMEOUT_SECONDS

_LOGGER = logging.getLogger(__name__)

QUEUE = "addon_update_requests"
SUPERVISOR = "http://supervisor"
INFO_EVERY_SECONDS = 600.0           # self/info at most every 10 min
STORE_RELOAD_EVERY_SECONDS = 6 * 3600.0
UPDATE_COOLDOWN_SECONDS = 600.0      # one update per 10 min
MAX_AGE_SECONDS = 120.0
STREAM_RETRY_SECONDS = 5.0
SEEN_LIMIT = 256


# ---- pure logic -------------------------------------------------------------

def parse_self_info(body: Any) -> dict | None:
    """Reduce a Supervisor /addons/self/info answer to what we use."""
    data = body.get("data") if isinstance(body, dict) else None
    if not isinstance(data, dict):
        return None
    version = data.get("version")
    latest = data.get("version_latest")
    slug = data.get("slug")
    if not isinstance(version, str) or not isinstance(latest, str) or not isinstance(slug, str):
        return None
    return {
        "slug": slug,
        "version": version,
        "versionLatest": latest,
        "updateAvailable": data.get("update_available") is True and version != latest,
    }


def check_request(req: Any, now_ms: float, is_admin: bool, allowed: bool,
                  info: dict | None, last_update: float | None, now_s: float,
                  max_age: float = MAX_AGE_SECONDS) -> str | None:
    """None when the request may run, else the reason it may not."""
    if not allowed:
        return "remote updates are off on the farm box"
    if not isinstance(req, dict) or set(req) != {"uid", "at"}:
        return "not a valid request"
    uid, at = req.get("uid"), req.get("at")
    if not isinstance(uid, str) or not uid or len(uid) > 128 or "/" in uid:
        return "not a valid request"
    if not isinstance(at, (int, float)) or isinstance(at, bool):
        return "no timestamp"
    age = now_ms / 1000.0 - at / 1000.0
    if age > max_age or age < -60:
        return f"stale by {age:.0f}s"
    if not is_admin:
        return "not an admin"
    if info is None:
        return "could not read the add-on's version"
    if not info["updateAvailable"]:
        return "already up to date"
    if last_update is not None and now_s - last_update < UPDATE_COOLDOWN_SECONDS:
        return "an update was started in the last 10 minutes"
    return None


def finish_state(update: Any, running_version: str | None, now_ms: int) -> dict | None:
    """What to write at start-up for a leftover `updating` node, else None."""
    if not isinstance(update, dict) or update.get("state") != "updating":
        return None
    if running_version and running_version == update.get("to"):
        return {"state": "done", "from": update.get("from"), "to": update.get("to"),
                "at": now_ms, "by": update.get("by")}
    return {"state": "failed", "from": update.get("from"), "to": update.get("to"),
            "reason": f"still on {running_version or 'an unknown version'}",
            "at": now_ms, "by": update.get("by")}


def heartbeat_fields(info: dict | None, allowed: bool) -> dict:
    """What the heartbeat publishes. null clears a field we cannot know."""
    return {
        "version": info["version"] if info else None,
        "versionLatest": info["versionLatest"] if info else None,
        "updateAvailable": info["updateAvailable"] if info else None,
        "remoteUpdate": allowed,
    }


# ---- consumer ----------------------------------------------------------------

class AddonUpdater:
    def __init__(self, cfg, rtdb, session) -> None:
        self._cfg = cfg
        self._rtdb = rtdb
        self._session = session
        self._token = os.environ.get("SUPERVISOR_TOKEN", "")
        self.info: dict | None = None
        self._reload_at = 0.0
        self._last_update: float | None = None
        self._seen: list[str] = []
        self._lock = asyncio.Lock()

    @property
    def allowed(self) -> bool:
        return bool(self._cfg.allow_remote_update)

    def heartbeat(self) -> dict:
        return heartbeat_fields(self.info, self.allowed)

    # ---- Supervisor ----

    async def _supervisor(self, method: str, path: str, timeout: float = 30) -> Any:
        import aiohttp
        async with self._session.request(
            method, f"{SUPERVISOR}{path}",
            headers={"Authorization": f"Bearer {self._token}"},
            timeout=aiohttp.ClientTimeout(total=timeout),
        ) as resp:
            text = await resp.text()
            if resp.status >= 400:
                raise RuntimeError(f"Supervisor {method} {path} -> {resp.status}")
            try:
                return json.loads(text) if text else {}
            except ValueError:
                return {}

    async def _read_info(self) -> None:
        parsed = parse_self_info(await self._supervisor("GET", "/addons/self/info"))
        if parsed:
            self.info = parsed

    async def run_info(self) -> None:
        """Keep version/latest fresh; reload the store every 6 h."""
        if not self._token:
            _LOGGER.info("No Supervisor token; add-on version is not published")
            return
        while True:
            try:
                if time.monotonic() - self._reload_at >= STORE_RELOAD_EVERY_SECONDS:
                    self._reload_at = time.monotonic()
                    try:
                        await self._supervisor("POST", "/store/reload", timeout=120)
                    except Exception as err:
                        _LOGGER.warning("Store reload failed: %s", err)
                await self._read_info()
            except asyncio.CancelledError:
                raise
            except Exception as err:
                _LOGGER.warning("Could not read the add-on's info: %s", err)
            await asyncio.sleep(INFO_EVERY_SECONDS)

    # ---- update node ----

    def _node(self) -> str:
        return f"{self._cfg.root}/meta/bridge/update"

    async def finish_previous(self) -> None:
        try:
            await self._read_info()
            update = await self._rtdb.get(self._node())
            out = finish_state(update, self.info["version"] if self.info else None,
                               int(time.time() * 1000))
            if out:
                await self._rtdb.put(self._node(), out)
                _LOGGER.info("Previous update settled: %s", out["state"])
        except Exception as err:
            _LOGGER.warning("Could not settle the previous update: %s", err)

    async def _note(self, state: str, reason: str, req: Any) -> None:
        node: dict = {"state": state, "reason": reason, "at": int(time.time() * 1000)}
        if isinstance(req, dict) and isinstance(req.get("uid"), str):
            node["by"] = req["uid"]
        if self.info:
            node["from"] = self.info["version"]
            node["to"] = self.info["versionLatest"]
        try:
            await self._rtdb.put(self._node(), node)
        except Exception:
            _LOGGER.warning("Could not record the update result")

    # ---- handling ----

    async def handle(self, req_id: str, req: Any) -> None:
        if req is None or req_id in self._seen:
            return
        self._seen.append(req_id)
        del self._seen[:-SEEN_LIMIT]
        async with self._lock:
            try:
                await self._handle(req)
            except Exception:
                _LOGGER.exception("Update request %s failed", req_id)
            finally:
                try:
                    await self._rtdb.put(f"{self._cfg.root}/{QUEUE}/{req_id}", None)
                except Exception:
                    _LOGGER.exception("Could not clear update request %s", req_id)

    async def _handle(self, req: Any) -> None:
        uid = req.get("uid") if isinstance(req, dict) else None
        is_admin = False
        if self.allowed and isinstance(uid, str) and uid and "/" not in uid and len(uid) <= 128:
            is_admin = (await self._rtdb.get(f"acl/admins/{uid}")) is True
        info = None
        if self.allowed and self._token:
            try:
                await self._read_info()     # decide on a fresh answer, not a 10-minute-old one
            except Exception as err:
                _LOGGER.warning("Could not read the add-on's info: %s", err)
            info = self.info
        why = check_request(req, time.time() * 1000, is_admin, self.allowed, info,
                            self._last_update, time.monotonic())
        if why:
            _LOGGER.warning("Refused update request: %s", why)
            if self.allowed and why not in ("not an admin", "not a valid request"):
                await self._note("refused", why, req)
            return
        self._last_update = time.monotonic()
        await self._rtdb.put(self._node(), {
            "state": "updating", "from": info["version"], "to": info["versionLatest"],
            "at": int(time.time() * 1000), "by": uid})
        _LOGGER.info("Updating the add-on %s -> %s", info["version"], info["versionLatest"])
        try:
            # The Supervisor stops this container part-way; the call then never returns.
            await self._supervisor("POST", f"/store/addons/{info['slug']}/update", timeout=900)
        except asyncio.CancelledError:
            raise
        except Exception as err:
            await self._note("failed", str(err)[:120] or "the Supervisor refused", req)

    async def _dispatch(self, path: str, data: Any) -> None:
        path = (path or "/").strip("/")
        if not path:
            for req_id, req in (data or {}).items():
                await self.handle(req_id, req)
        elif "/" not in path:
            await self.handle(path, data)

    async def _purge(self) -> None:
        path = f"{self._cfg.root}/{QUEUE}"
        try:
            if await self._rtdb.get(path, shallow=True):
                await self._rtdb.put(path, None)
                _LOGGER.info("Remote update is off: dropped queued update requests")
        except Exception:
            _LOGGER.debug("Could not purge the update queue", exc_info=True)

    async def run(self) -> None:
        if self._token:
            await self.finish_previous()
        if not self.allowed:
            _LOGGER.info("Remote update is off; not watching the update queue")
            await self._purge()
            return
        _LOGGER.info("Watching update requests from admins")
        while True:
            try:
                await self._stream_once()
            except asyncio.CancelledError:
                raise
            except Exception as err:
                _LOGGER.error("Update stream error: %s", err or type(err).__name__)
            await asyncio.sleep(STREAM_RETRY_SECONDS)

    async def _stream_once(self) -> None:
        import aiohttp
        url = f"{self._cfg.firebase_db_url}/{self._cfg.root}/{QUEUE}.json"
        token = await self._rtdb._token()
        headers = {"Authorization": f"Bearer {token}", "Accept": "text/event-stream"}
        timeout = aiohttp.ClientTimeout(total=None, sock_connect=30,
                                        sock_read=STREAM_READ_TIMEOUT_SECONDS)
        async with self._session.get(url, headers=headers, timeout=timeout, allow_redirects=True) as resp:
            if resp.status >= 400:
                raise RuntimeError(f"update stream -> {resp.status}: {(await resp.text())[:200]}")
            _LOGGER.info("Update request stream open")
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
                            continue
                        await self._dispatch(body.get("path"), body.get("data"))
                    elif event == "auth_revoked":
                        return
