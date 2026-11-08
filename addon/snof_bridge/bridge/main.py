"""SNOF Firebase Bridge entrypoint.

Home Assistant (WebSocket) -> filter/map -> Realtime Database -> hosted dashboard.

On every (re)connect the bridge republishes a full snapshot so entities deleted
in HA disappear from the mirror, then switches to streaming state_changed deltas.
"""
from __future__ import annotations

import asyncio
import hashlib
import json
import logging
import signal
import sys

import aiohttp
from aiohttp import web

from . import config
from .commands import CommandConsumer
from .irrigation_control import IrrigationControl
from .relay import DconRelay
from .updater import AddonUpdater
from .ha_client import REGISTRY_EVENTS, HAClient
from .mapper import StateMapper
from .registry import Registry
from .rtdb import RTDBWriter

_LOGGER = logging.getLogger("snof")

HEALTH_PORT = 8099
SERVER_TIMESTAMP = {".sv": "timestamp"}


class Bridge:
    def __init__(self, cfg: config.Config, session: aiohttp.ClientSession) -> None:
        self.cfg = cfg
        self.session = session
        self.registry = Registry()
        self.mapper = StateMapper(cfg, self.registry)
        self.rtdb = RTDBWriter(cfg, session)
        self.ha: HAClient | None = None
        # `lambda` rather than passing self.ha: the client is replaced on every
        # reconnect, and the consumer must always get the live one.
        # `is_visible` is the mapper's own publish check, so a command can only
        # ever reach an entity a user could have seen: one in a room.
        self.commands = CommandConsumer(cfg, self.rtdb, lambda: self.ha if self.connected else None, session,
                                        is_visible=self.mapper.should_publish)
        self.relay = DconRelay(cfg, self.rtdb, session)
        self.irrigation_control = IrrigationControl(cfg, self.rtdb, session)
        self.updater = AddonUpdater(cfg, self.rtdb, session)
        self.connected = False
        # entity_id -> digest of the last node we published, so an event that
        # changes nothing visible costs no write at all.
        self._fingerprints: dict[str, str] = {}
        self._areas_digest: str | None = None
        self._devices_digest: str | None = None
        self.skipped = 0
        self.ha_version = "unknown"
        self._registry_reload = asyncio.Event()

    # ---- publishing -------------------------------------------------------

    @staticmethod
    def _digest(node: dict) -> str:
        return hashlib.sha1(
            json.dumps(node, sort_keys=True, separators=(",", ":")).encode()
        ).hexdigest()

    def _queue_if_changed(self, domain: str, object_id: str, node: dict) -> bool:
        """Stage a node only when it differs from what we last published."""
        entity_id = node["entity_id"]
        digest = self._digest(node)
        if self._fingerprints.get(entity_id) == digest:
            self.skipped += 1
            return False
        self._fingerprints[entity_id] = digest
        self.rtdb.queue(entity_id, f"{self.cfg.root}/entities/{domain}/{object_id}", node)
        return True

    def _unpublish(self, entity_id: str) -> None:
        """Remove an entity from the mirror: deleted in HA, or no longer in a room."""
        if "." not in entity_id:
            return
        domain, object_id = entity_id.split(".", 1)
        self.rtdb.queue(entity_id, f"{self.cfg.root}/entities/{domain}/{object_id}", None)
        self._fingerprints.pop(entity_id, None)

    def _build_tree(self, states: list[dict]) -> dict[str, dict]:
        tree: dict[str, dict] = {}
        for state in states:
            entity_id = state.get("entity_id", "")
            if not self.mapper.should_publish(entity_id):
                continue
            domain, object_id, node = self.mapper.to_node(state)
            tree.setdefault(domain, {})[object_id] = node
        return tree

    async def publish_snapshot(self, states: list[dict]) -> int:
        """Full replace. Only on (re)connect, so entities deleted in Home
        Assistant while we were away disappear from the mirror."""
        tree = self._build_tree(states)
        self._fingerprints = {
            n["entity_id"]: self._digest(n)
            for objs in tree.values() for n in objs.values()
        }
        root = self.cfg.root
        await self.rtdb.put(f"{root}/areas", self.registry.areas_payload())
        self._areas_digest = self._digest(self.registry.areas_payload())
        await self.rtdb.put(f"{root}/devices", self.registry.devices_payload())
        self._devices_digest = self._digest(self.registry.devices_payload())
        await self.rtdb.put(f"{root}/entities", tree)
        count = sum(len(v) for v in tree.values())
        _LOGGER.info("Published snapshot: %d entities across %d domains", count, len(tree))
        return count

    async def resync(self, states: list[dict]) -> int:
        """Reconcile after a registry edit WITHOUT rewriting the world.

        Home Assistant emits registry events often, and almost none of them
        change anything we publish. The old code answered each one with a full
        PUT of every entity, so an idle farm rewrote ~200 KB repeatedly. Now
        each node goes through the same fingerprint check as a live update, so
        an event that changes nothing costs zero writes."""
        tree = self._build_tree(states)
        changed = 0
        # An entity taken out of its room (or deleted) must vanish, not linger
        # with a stale area: anything published before and absent now goes.
        live = {n["entity_id"] for objs in tree.values() for n in objs.values()}
        for entity_id in [e for e in self._fingerprints if e not in live]:
            self._unpublish(entity_id)
            changed += 1
        for domain, objs in tree.items():
            for object_id, node in objs.items():
                if self._queue_if_changed(domain, object_id, node):
                    changed += 1

        areas = self.registry.areas_payload()
        areas_digest = self._digest(areas)
        if areas_digest != self._areas_digest:
            await self.rtdb.put(f"{self.cfg.root}/areas", areas)
            self._areas_digest = areas_digest
            _LOGGER.info("Areas changed; republished")

        devices = self.registry.devices_payload()
        devices_digest = self._digest(devices)
        if devices_digest != self._devices_digest:
            await self.rtdb.put(f"{self.cfg.root}/devices", devices)
            self._devices_digest = devices_digest
            _LOGGER.info("Devices changed; republished")

        if changed:
            _LOGGER.info("Registry resync: %d of %d entities changed", changed,
                         sum(len(v) for v in tree.values()))
        else:
            _LOGGER.debug("Registry resync: nothing changed, no writes")
        return changed

    async def publish_meta(self, entity_count: int) -> None:
        await self.rtdb.patch(f"{self.cfg.root}/meta", {
            "name": self.cfg.farm_name,
            "slug": self.cfg.farm_slug,
            "entityCount": entity_count,
            "haVersion": self.ha_version,
            "updatedAt": SERVER_TIMESTAMP,
        })

    def on_state_changed(self, data: dict) -> None:
        new_state = data.get("new_state")
        entity_id = data.get("entity_id", "")

        if new_state is None:
            # Entity was removed from HA; drop it from the mirror too.
            self._unpublish(entity_id)
            return

        if not self.mapper.should_publish(entity_id):
            if entity_id in self._fingerprints:
                self._unpublish(entity_id)
            return
        domain, object_id, node = self.mapper.to_node(new_state)
        # Home Assistant fires state_changed for attribute-only updates too, so
        # events that carry no new information are common. Skip those.
        self._queue_if_changed(domain, object_id, node)

    def on_event(self, event_type: str, data: dict) -> None:
        if event_type == "state_changed":
            self.on_state_changed(data)
        elif event_type in REGISTRY_EVENTS:
            # Rooms or entity assignments moved; rebuild on the next loop tick.
            self._registry_reload.set()

    # ---- background loops -------------------------------------------------

    async def _flush_loop(self) -> None:
        while True:
            await asyncio.sleep(self.cfg.flush_interval_seconds)
            try:
                await self.rtdb.flush()
            except Exception:
                _LOGGER.exception("Flush failed; will retry with the next tick")

    async def _heartbeat_loop(self) -> None:
        """The dashboard decides the bridge is offline when this stops advancing;
        the Admin REST API has no onDisconnect, so liveness is staleness-based."""
        while True:
            try:
                await self.rtdb.patch(f"{self.cfg.root}/meta/bridge", {
                    "status": "online" if self.connected else "degraded",
                    "lastSeen": SERVER_TIMESTAMP,
                    "heartbeatSeconds": self.cfg.heartbeat_seconds,
                    "pending": self.rtdb.pending_count(),
                    "writes": self.rtdb.writes,
                    "skippedNoop": self.skipped,
                    "control": self.cfg.allow_control,
                    "commandsRun": self.commands.executed,
                    "commandsRefused": self.commands.refused,
                    # Irrigation reports moved to a Cloud Function in 0.8.0
                    # (dashboard/functions). null clears the old status so
                    # nothing reads a stale "enabled" off this heartbeat.
                    "irrigation": None,
                    "relay": self.relay.status(),
                    # What the app gates the irrigation Run/Stop buttons on.
                    "irrigationControl": self.irrigation_control.enabled,
                    "irrigationControlStatus": self.irrigation_control.status(),
                    # Start-a-program gate: true only with both options on.
                    "programStart": self.irrigation_control.program_start_enabled,
                    # Running / latest add-on version; may admins update it?
                    **self.updater.heartbeat(),
                })
            except Exception:
                _LOGGER.exception("Heartbeat write failed")
            await asyncio.sleep(self.cfg.heartbeat_seconds)

    async def _registry_loop(self) -> None:
        while True:
            await self._registry_reload.wait()
            self._registry_reload.clear()
            await asyncio.sleep(2)  # let a burst of registry edits settle
            try:
                if self.ha is None:
                    continue
                areas, devices, entities = await self.ha.get_registries()
                self.registry.load(areas, devices, entities)
                states = await self.ha.get_states()
                await self.resync(states)
            except Exception:
                _LOGGER.exception("Registry reload failed")

    # ---- main loop --------------------------------------------------------

    async def run(self) -> None:
        delay = 1.0
        while True:
            self.ha = HAClient(self.cfg.ha_ws_url, self.cfg.ha_token, self.session)
            listen_task: asyncio.Task | None = None
            try:
                await self.ha.connect()
                self.connected = True
                self.ha_version = self.ha.ha_version
                delay = 1.0

                # The message pump has to be running before the first command:
                # _command() awaits a future that only listen() ever resolves,
                # so issuing commands first deadlocks until the 30s timeout.
                listen_task = asyncio.create_task(self.ha.listen(self.on_event))

                areas, devices, entities = await self.ha.get_registries()
                self.registry.load(areas, devices, entities)
                states = await self.ha.get_states()
                count = await self.publish_snapshot(states)
                await self.publish_meta(count)

                await self.ha.subscribe("state_changed")
                for event in REGISTRY_EVENTS:
                    await self.ha.subscribe(event)
                _LOGGER.info("Streaming live state changes")

                await listen_task
                _LOGGER.warning("Home Assistant closed the connection")
            except asyncio.CancelledError:
                raise
            except Exception as err:
                # TimeoutError stringifies to '', which says nothing in a log.
                _LOGGER.error("Bridge connection error: %s", err or type(err).__name__)
            finally:
                self.connected = False
                if listen_task is not None:
                    listen_task.cancel()
                try:
                    await self.ha.close()
                except Exception:
                    pass

            _LOGGER.info("Reconnecting in %.0fs", delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 60.0)


async def start_health_server(bridge: Bridge) -> web.AppRunner:
    """Backs the add-on watchdog: unhealthy once HA has dropped."""
    async def handler(_request: web.Request) -> web.Response:
        healthy = bridge.connected
        return web.json_response(
            {
                "status": "ok" if healthy else "disconnected",
                "connected": bridge.connected,
                "pending": bridge.rtdb.pending_count(),
                "writes": bridge.rtdb.writes,
                "entitiesSent": bridge.rtdb.entities_sent,
            },
            status=200 if healthy else 503,
        )

    app = web.Application()
    app.router.add_get("/", handler)
    app.router.add_get("/health", handler)
    runner = web.AppRunner(app)
    await runner.setup()
    await web.TCPSite(runner, "0.0.0.0", HEALTH_PORT).start()
    return runner


async def amain() -> None:
    cfg = config.load()
    logging.basicConfig(
        level=cfg.log_level,
        format="%(asctime)s %(levelname)-7s %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )
    _LOGGER.info("SNOF bridge starting - farm=%s db=%s", cfg.farm_slug, cfg.firebase_db_url)

    async with aiohttp.ClientSession() as session:
        bridge = Bridge(cfg, session)
        runner = await start_health_server(bridge)

        tasks = [
            asyncio.create_task(bridge.run(), name="ha"),
            asyncio.create_task(bridge._flush_loop(), name="flush"),
            asyncio.create_task(bridge._heartbeat_loop(), name="heartbeat"),
            asyncio.create_task(bridge._registry_loop(), name="registry"),
            asyncio.create_task(bridge.commands.run(), name="commands"),
            asyncio.create_task(bridge.relay.run(), name="relay"),
            asyncio.create_task(bridge.irrigation_control.run(), name="irrigation_control"),
            asyncio.create_task(bridge.updater.run_info(), name="update_info"),
            asyncio.create_task(bridge.updater.run(), name="update_requests"),
        ]

        stop = asyncio.Event()
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGTERM, signal.SIGINT):
            try:
                loop.add_signal_handler(sig, stop.set)
            except NotImplementedError:
                pass

        await stop.wait()
        _LOGGER.info("Shutting down")
        for task in tasks:
            task.cancel()
        await asyncio.gather(*tasks, return_exceptions=True)
        try:
            await bridge.rtdb.patch(f"{cfg.root}/meta/bridge",
                                    {"status": "offline", "lastSeen": SERVER_TIMESTAMP})
        except Exception:
            pass
        await runner.cleanup()


def main() -> None:
    try:
        asyncio.run(amain())
    except KeyboardInterrupt:
        sys.exit(0)


if __name__ == "__main__":
    main()
