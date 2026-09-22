# Irrigation mirror (vendor motors & valves)

The farm's pumps and valves are driven by vendor controllers, not Home
Assistant: a Livesky GSM unit on the river motor, Niagara controllers on the
well motors, and a Mobitech DCON unit for
the irrigation valves and timers, plus OpenWeather for field conditions.
The Postman collection that captured these APIs ("Mobitech Hack") lives
outside the repo; nothing from it is quoted here.

## Architecture

```
Vendor APIs (bearer tokens, device ids)
  │  polled server-side every irrigation_poll_seconds (default 5 min)
  ▼
Add-on: bridge/irrigation.py  →  bridge/vendors.py (normalize + scrub)
  │  one sanitized PUT, read-only
  ▼
RTDB  /farms/<slug>/irrigation   ← viewers can read, nobody can write
  ▼
Dashboard  #/irrigation          ← renders the mirror, no credentials
```

The dashboard never talks to a vendor API (CORS and secrets both forbid
it) and never sees a credential. The mirror carries presentation fields
only — names, on/off/unknown, runtimes, timer summaries, latest readings,
weather — capped the way HA attributes are (strings 255, lists 16).

## Setup

Off by default. In the add-on Configuration tab:

1. `irrigation_enabled: true`.
2. Fill in only the vendors on the farm. Each is optional and degrades
   independently — an unconfigured vendor shows its feed as
   `unconfigured`, a failing one as `error`, and the rest of the page
   still renders:
   - Livesky: `livesky_bearer` (JWT — expires, renew it when the feed
     reports `error`), `livesky_imei`.
   - Niagara: `niagara_base`, `niagara_user`, `niagara_clusters` as
     `"id:label"` entries, e.g. `"6039:Well Motor 7.5HP"`.
   - DCON: `dcon_token_id`, `dcon_serial` (`dcon_device_id`,
     `dcon_product`, `dcon_log_days` if they differ from defaults).
   - Weather: `owm_appid`, `owm_place` (e.g. `638673,in`).
3. Bump already handled: this shipped as add-on 0.4.0 — update it on the
   NUC via the usual Supervisor flow and check the bridge log for
   `Irrigation mirror updated`.

RTDB rules need no change: `/irrigation` inherits the farm's viewer-only
read and write-deny. There is deliberately no command path for it.

## What is deliberately not built

**Operating pumps or valves.** The collection captures command endpoints
(DCON `/v1/command/`, valve ON/OFF) and the poller never calls them.
Turning a pump on from a browser tab is the same class of decision as
`cover`/`lock` — excluded at every layer until it is designed as one:
it would arrive through the `/commands` queue with its own domain
allow-list and validator cases, never as a direct vendor call. The
dashboard says so on the page ("this page cannot operate pumps").

## Response shapes

The collection was exported without saved responses, so `vendors.py`
parsers accept a list, a dict holding a list, or a single object, pick
from several likely key spellings, and degrade unknown states to
`unknown`. When live responses are seen, tighten the key lists against
real payloads — the parsers' tests in `tests/test_logic.py` pin the
current behaviour, including the credential scrub.
