"""Entity -> area (room) resolution.

Home Assistant stores the room in one of two places: directly on the entity, or
on the device the entity belongs to. Entity wins when both are set, which is how
HA itself resolves it.

Visibility is stricter than placement: an entity exists for users only if it
belongs to a device that is in a room (is_assigned). A room set on the entity
alone does not make it visible - the owner's rule is "only devices with
assigned rooms". Once visible, it is placed the way HA places it, entity area
first. Anything else means "does not exist" as far as Firebase is concerned:
the mapper never publishes it and the command consumer never operates it.
UNASSIGNED is not an area and never appears in areas_payload().
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
        self._device_name: dict[str, str] = {}

    def load(self, areas: list[dict], devices: list[dict], entities: list[dict]) -> None:
        self.areas = {
            a["area_id"]: {
                "name": a.get("name") or a["area_id"],
                "icon": a.get("icon"),
                "floor": a.get("floor_id"),
            }
            for a in areas
        }

        self._device_area = {
            d["id"]: d["area_id"] for d in devices if d.get("area_id")
        }
        # What the owner named it, else what the integration called it.
        self._device_name = {
            d["id"]: (d.get("name_by_user") or d.get("name") or d["id"])[:128]
            for d in devices if d.get("area_id")
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
            len(self.areas), len(self._device_area), len(entities),
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

    def is_assigned(self, entity_id: str) -> bool:
        """True only for an entity on a device that sits in a real, current
        room, and whose own resolved room is real too."""
        device_area = self._device_area.get(self._entity_device.get(entity_id, ""))
        return device_area in self.areas and self.area_for(entity_id) in self.areas

    def device_for(self, entity_id: str) -> str | None:
        """The entity's device id, if that device is in a room."""
        device_id = self._entity_device.get(entity_id)
        return device_id if device_id in self._device_area else None

    def devices_payload(self) -> dict:
        """Name of every device in a real room, keyed by HA device id, so the
        app can count and name devices instead of entities. Devices in no
        room are absent, like their entities."""
        return {
            device_id: {"name": self._device_name[device_id]}
            for device_id, area in self._device_area.items()
            if area in self.areas
        }

    def areas_payload(self) -> dict:
        return {
            area_id: {k: v for k, v in meta.items() if v is not None}
            for area_id, meta in self.areas.items()
        }
