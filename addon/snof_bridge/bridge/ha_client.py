"""Minimal Home Assistant WebSocket client.

Only the four things the bridge needs: authenticate, pull the registries, pull a
full state snapshot, then stream state_changed events. Reconnects with backoff so
a core restart does not take the bridge down with it.
"""
from __future__ import annotations

import asyncio
import itertools
import logging
from typing import Any, AsyncIterator, Callable

import aiohttp

_LOGGER = logging.getLogger(__name__)

# Registry changes are rare; when one arrives we just reload the whole registry.
REGISTRY_EVENTS = ("area_registry_updated", "device_registry_updated", "entity_registry_updated")


class HAClient:
    def __init__(self, url: str, token: str, session: aiohttp.ClientSession) -> None:
        self._url = url
        self._token = token
        self._session = session
        self._ws: aiohttp.ClientWebSocketResponse | None = None
        self._ids = itertools.count(1)
        self._pending: dict[int, asyncio.Future] = {}
        self.ha_version = "unknown"

    async def connect(self) -> None:
        _LOGGER.debug("Connecting to %s", self._url)
        self._ws = await self._session.ws_connect(self._url, heartbeat=30, max_msg_size=0)
        hello = await self._ws.receive_json()
        if hello.get("type") != "auth_required":
            raise RuntimeError(f"Unexpected greeting from Home Assistant: {hello!r}")
        await self._ws.send_json({"type": "auth", "access_token": self._token})
        reply = await self._ws.receive_json()
        if reply.get("type") != "auth_ok":
            raise RuntimeError(f"Home Assistant rejected our token: {reply!r}")
        self.ha_version = reply.get("ha_version") or "unknown"
        _LOGGER.info("Authenticated with Home Assistant %s", self.ha_version)

    async def close(self) -> None:
        if self._ws is not None and not self._ws.closed:
            await self._ws.close()

    async def _command(self, payload: dict) -> Any:
        assert self._ws is not None
        msg_id = next(self._ids)
        future: asyncio.Future = asyncio.get_running_loop().create_future()
        self._pending[msg_id] = future
        await self._ws.send_json({"id": msg_id, **payload})
        return await asyncio.wait_for(future, timeout=30)

    async def get_states(self) -> list[dict]:
        return await self._command({"type": "get_states"})

    async def get_registries(self) -> tuple[list, list, list]:
        areas = await self._command({"type": "config/area_registry/list"})
        devices = await self._command({"type": "config/device_registry/list"})
        entities = await self._command({"type": "config/entity_registry/list"})
        return areas, devices, entities

    async def call_service(self, domain: str, service: str, entity_id: str,
                           data: dict | None = None) -> Any:
        """Operate one entity. The caller is responsible for having checked the
        domain and service against an allow-list first — this issues whatever it
        is given."""
        return await self._command({
            "type": "call_service",
            "domain": domain,
            "service": service,
            "service_data": dict(data or {}),
            "target": {"entity_id": entity_id},
        })

    async def subscribe(self, event_type: str) -> None:
        await self._command({"type": "subscribe_events", "event_type": event_type})

    async def listen(self, on_event: Callable[[str, dict], Any]) -> None:
        """Pump messages until the socket closes. Resolves pending commands and
        forwards events to `on_event`."""
        assert self._ws is not None
        async for msg in self._ws:
            if msg.type is not aiohttp.WSMsgType.TEXT:
                break
            data = msg.json()
            kind = data.get("type")

            if kind == "result":
                future = self._pending.pop(data.get("id"), None)
                if future and not future.done():
                    if data.get("success"):
                        future.set_result(data.get("result"))
                    else:
                        future.set_exception(RuntimeError(str(data.get("error"))))
            elif kind == "event":
                event = data.get("event") or {}
                result = on_event(event.get("event_type", ""), event.get("data") or {})
                if asyncio.iscoroutine(result):
                    await result

        # Socket died: fail anything still waiting so callers do not hang.
        for future in self._pending.values():
            if not future.done():
                future.set_exception(ConnectionError("Home Assistant socket closed"))
        self._pending.clear()


async def backoff_delays(start: float = 1.0, cap: float = 60.0) -> AsyncIterator[float]:
    delay = start
    while True:
        yield delay
        delay = min(delay * 2, cap)
