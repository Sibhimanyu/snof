"""Turn a Home Assistant state object into the node we store in RTDB.

Two jobs, both about not shipping the whole farm's internals to the cloud:
  * keep the payload small enough that a chatty farm does not burn RTDB quota
  * never let credentials or GPS coordinates leave the NUC
"""
from __future__ import annotations

from typing import Any

# Attributes worth showing on a dashboard. Anything not listed is dropped, so a
# new integration cannot silently start exporting fields we have not considered.
ALLOWED_ATTRS = frozenset({
    "friendly_name", "device_class", "state_class", "unit_of_measurement", "icon",
    # light / switch
    "brightness", "color_temp_kelvin", "rgb_color", "hs_color", "effect",
    # climate
    "current_temperature", "temperature", "target_temp_high", "target_temp_low",
    "hvac_action", "preset_mode", "fan_mode", "swing_mode",
    # sensors / environment
    "humidity", "pressure", "battery_level", "illuminance", "moisture",
    # cover / fan / valve
    "current_position", "current_tilt_position", "percentage", "direction",
    "oscillating", "preset_modes",
    # media
    "media_title", "media_artist", "source", "volume_level", "is_volume_muted",
    # misc
    "last_triggered", "next_dawn", "next_dusk",
})

# Second gate: even if an attribute somehow matches above, refuse anything whose
# name smells like a secret or a location. Substring match, case-insensitive.
DENY_SUBSTRINGS = ("token", "password", "secret", "credential", "api_key", "auth",
                   "picture", "url", "signature", "cookie", "ssid", "mac")

LOCATION_ATTRS = frozenset({"latitude", "longitude", "gps_accuracy", "altitude"})

# Entire domains that are inherently location-bearing.
LOCATION_DOMAINS = frozenset({"device_tracker", "person", "geo_location"})

MAX_STRING_LEN = 255


def split_entity_id(entity_id: str) -> tuple[str, str]:
    domain, _, object_id = entity_id.partition(".")
    return domain, object_id


def _clean_value(value: Any) -> Any:
    """Coerce to something RTDB accepts, and cap runaway strings."""
    if value is None or isinstance(value, (bool, int, float)):
        return value
    if isinstance(value, str):
        return value[:MAX_STRING_LEN]
    if isinstance(value, (list, tuple)):
        # Lists of scalars only; nested structures are more trouble than they are worth.
        items = [v for v in value if isinstance(v, (str, int, float, bool))]
        return [_clean_value(v) for v in items[:16]] or None
    return None


def filter_attributes(attrs: dict, *, domain: str, expose_location: bool) -> dict:
    out: dict[str, Any] = {}
    for key, value in attrs.items():
        lowered = key.lower()
        if key in LOCATION_ATTRS and not expose_location:
            continue
        if any(bad in lowered for bad in DENY_SUBSTRINGS):
            continue
        if key not in ALLOWED_ATTRS:
            continue
        cleaned = _clean_value(value)
        if cleaned is not None:
            out[key] = cleaned
    return out


class StateMapper:
    def __init__(self, cfg, registry):
        self.cfg = cfg
        self.registry = registry

    def should_publish(self, entity_id: str) -> bool:
        domain, _ = split_entity_id(entity_id)
        if entity_id in self.cfg.exclude_entities:
            return False
        if domain in self.cfg.exclude_domains:
            return False
        if domain in LOCATION_DOMAINS and not self.cfg.expose_location:
            return False
        if self.cfg.include_domains and domain not in self.cfg.include_domains:
            return False
        # Users see rooms and what is in them, nothing else. An entity with no
        # area in Home Assistant is never mirrored, so to every client it simply
        # does not exist - and the command consumer uses this same check.
        if not self.registry.is_assigned(entity_id):
            return False
        return True

    def to_node(self, state: dict) -> tuple[str, str, dict]:
        """Return (domain, object_id, node) for a HA state object."""
        entity_id = state["entity_id"]
        domain, object_id = split_entity_id(entity_id)
        attrs = state.get("attributes") or {}

        node = {
            "entity_id": entity_id,
            "domain": domain,
            "name": (attrs.get("friendly_name") or object_id.replace("_", " ").title())[:MAX_STRING_LEN],
            "state": _clean_value(state.get("state")),
            "area": self.registry.area_for(entity_id),
            "device": self.registry.device_for(entity_id),
            # Deliberately no lastUpdated: Home Assistant bumps it on every
            # update including attribute-only ones, so including it would make
            # every node differ every time and force a redundant write.
            "lastChanged": state.get("last_changed"),
        }
        filtered = filter_attributes(attrs, domain=domain, expose_location=self.cfg.expose_location)
        filtered.pop("friendly_name", None)  # already promoted to `name`
        if filtered:
            node["attrs"] = filtered
        return domain, object_id, node
