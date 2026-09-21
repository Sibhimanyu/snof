"""Realtime Database writer.

Talks to RTDB over its REST API with a service-account bearer token rather than
pulling in firebase-admin, which would drag Firestore and GCS clients into a
container that needs neither.

Two properties matter for a farm with chatty sensors:
  * coalescing - many state_changed events inside one flush window collapse into
    a single multi-path PATCH, so N entity updates cost one request, not N
  * rate limiting - a power meter emitting every 200ms is clamped to at most one
    write per `min_interval_seconds`, always carrying its newest value
"""
from __future__ import annotations

import asyncio
import logging
import time
from typing import Any

import aiohttp
from google.auth.transport.requests import Request as GoogleRequest
from google.oauth2 import service_account

_LOGGER = logging.getLogger(__name__)

SCOPES = [
    "https://www.googleapis.com/auth/userinfo.email",
    "https://www.googleapis.com/auth/firebase.database",
]

# Refresh a little before expiry so a write never races the token going stale.
TOKEN_SKEW_SECONDS = 300


class RTDBWriter:
    def __init__(self, cfg, session: aiohttp.ClientSession) -> None:
        self._cfg = cfg
        self._session = session
        self._creds = service_account.Credentials.from_service_account_file(
            cfg.service_account_path, scopes=SCOPES
        )
        self._pending: dict[str, tuple[str, Any]] = {}   # key -> (path, value)
        self._last_sent: dict[str, float] = {}
        self._lock = asyncio.Lock()
        self.writes = 0
        self.entities_sent = 0

    # ---- auth -------------------------------------------------------------

    async def _token(self) -> str:
        creds = self._creds
        expired = (
            not creds.valid
            or creds.expiry is None
            or (creds.expiry.timestamp() - time.time()) < TOKEN_SKEW_SECONDS
        )
        if expired:
            # google-auth is synchronous; keep it off the event loop.
            await asyncio.get_running_loop().run_in_executor(
                None, creds.refresh, GoogleRequest()
            )
            _LOGGER.debug("Refreshed Firebase access token")
        return creds.token

    # ---- low level --------------------------------------------------------

    async def _request(self, method: str, path: str, payload: Any) -> None:
        # print=silent makes RTDB answer 204 with an empty body instead of
        # echoing back everything just written. Every byte of that echo counts
        # against the 10 GB/month download quota and we never read it, so this
        # is pure waste on a farm writing ~7k times a day. Errors still come
        # back with a 4xx/5xx body, so nothing diagnostic is lost.
        url = f"{self._cfg.firebase_db_url}/{path.strip('/')}.json?print=silent"
        token = await self._token()
        async with self._session.request(
            method, url, json=payload,
            headers={"Authorization": f"Bearer {token}"},
            timeout=aiohttp.ClientTimeout(total=30),
        ) as resp:
            if resp.status >= 400:
                body = (await resp.text())[:400]
                raise RuntimeError(f"RTDB {method} {path} -> {resp.status}: {body}")
            # 200 (echo) and 204 (print=silent) are both success.
        self.writes += 1

    async def put(self, path: str, value: Any) -> None:
        await self._request("PUT", path, value)

    async def patch(self, path: str, value: dict) -> None:
        if value:
            await self._request("PATCH", path, value)

    # ---- batching ---------------------------------------------------------

    def queue(self, key: str, path: str, value: Any) -> None:
        """Stage a write. Later calls for the same key replace earlier ones, so a
        burst of changes to one entity only ever sends the newest state."""
        self._pending[key] = (path, value)

    async def flush(self) -> int:
        """Send everything that is past its rate limit as one multi-path PATCH."""
        async with self._lock:
            if not self._pending:
                return 0
            now = time.monotonic()
            batch: dict[str, Any] = {}
            sent_keys: list[str] = []
            for key, (path, value) in self._pending.items():
                last = self._last_sent.get(key)
                if last is not None and (now - last) < self._cfg.min_interval_seconds:
                    continue  # too soon; newest value stays staged for next tick
                batch[path] = value
                sent_keys.append(key)

            if not batch:
                return 0
            # RTDB treats slash-bearing keys in a root PATCH as a multi-location
            # update, applied atomically.
            await self._request("PATCH", "/", batch)
            for key in sent_keys:
                self._last_sent[key] = now
                self._pending.pop(key, None)
            self.entities_sent += len(sent_keys)
            _LOGGER.debug("Flushed %d entity updates", len(sent_keys))
            return len(sent_keys)

    def pending_count(self) -> int:
        return len(self._pending)
