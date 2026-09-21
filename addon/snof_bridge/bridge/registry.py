"""Entity -> area (room) resolution.

Home Assistant stores the room in one of two places: directly on the entity, or
on the device the entity belongs to. Entity wins when both are set, which is how
HA itself resolves it.
"""
from __future__ import annotations

import logging

_LOGGER = logging.getLogger(__name__)

UNASSIGNED = "unassigned"


class Registry:
    def __init__(self) -> None:
        self.areas: dict[str, dict] = {}
        self._entity_area: dict[str, str] = {}
        self._device_area: dict[str, str] = {}
        self._entity_device: dict[str, str] = {}

    def load(self, areas: list[dict], devices: list[dict], entities: list[dict]) -> None:
        self.areas = {
            a["area_id"]: {
                "name": a.get("name") or a["area_id"],
                "icon": a.get("icon"),
                "floor": a.get("floor_id"),
            }
            for a in areas
        }
        self.areas[UNASSIGNED] = {"name": "Unassigned", "icon": "mdi:help-circle-outline", "floor": None}

        self._device_area = {
            d["id"]: d["area_id"] for d in devices if d.get("area_id")
        }
        self._entity_area = {}
        self._entity_device = {}
        for e in entities:
            eid = e.get("entity_id")
            if not eid:
                continue
            if e.get("area_id"):
                self._entity_area[eid] = e["area_id"]
            if e.get("device_id"):
                self._entity_device[eid] = e["device_id"]

        _LOGGER.info(
            "Registry loaded: %d areas, %d devices, %d entities",
            len(self.areas) - 1, len(self._device_area), len(entities),
        )

    def area_for(self, entity_id: str) -> str:
        area = self._entity_area.get(entity_id)
        if area:
            return area
        device_id = self._entity_device.get(entity_id)
        if device_id:
            area = self._device_area.get(device_id)
            if area:
                return area
        return UNASSIGNED

    def areas_payload(self) -> dict:
        return {
            area_id: {k: v for k, v in meta.items() if v is not None}
            for area_id, meta in self.areas.items()
        }
