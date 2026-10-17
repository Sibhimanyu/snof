"""How a value becomes an RTDB REST body.

One function, in its own module for one reason: rtdb.py imports aiohttp and
google-auth at module scope, so tests/test_logic.py — which runs with nothing
installed — cannot import it. The encoding rule below is exactly the sort of
thing that breaks silently and must stay pinned by a test, so it lives where a
bare Python can reach it.
"""
from __future__ import annotations

import json
from typing import Any

# RTDB's event stream sends a keep-alive about every 30 s even when idle. A
# stream that has been silent for this long is dead, not quiet: a connection
# lost without a clean close never raises on its own, and with no read timeout
# the relay sat "open" and deaf for nine days (2026-10-08 to 2026-10-17).
STREAM_READ_TIMEOUT_SECONDS = 75.0


def encode_body(payload: Any) -> str:
    """Serialise a write body by hand, because `json=None` is not the same as a
    JSON null.

    aiohttp treats `json=None` as "no payload" and sends no body at all, and
    RTDB answers `400 No data supplied.` But a PUT of literal null IS the
    delete: it is how every executed command and every fulfilled report clears
    its queue node. Passed as `json=`, those deletes failed silently and the
    node stayed on a client-writable path — found on 2026-09-23 with four
    orphaned report requests sitting in production.
    """
    return json.dumps(payload)
