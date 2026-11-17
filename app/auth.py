"""Autentikasi token per node."""

from __future__ import annotations

import hashlib
import hmac
import time
import uuid
from dataclasses import dataclass

import asyncpg

from . import db

CACHE_TTL_S = 60.0
TOUCH_INTERVAL_S = 60.0


class AuthError(Exception):
    pass


@dataclass
class NodeInfo:
    node_id: uuid.UUID
    plot_id: object
    token_hash: str
    expires: float


def hash_token(token: str) -> str:
    return hashlib.sha256(token.encode("utf-8")).hexdigest()


class NodeAuth:
    def __init__(self) -> None:
        self._cache: dict[uuid.UUID, NodeInfo] = {}
        self._last_touch: dict[uuid.UUID, float] = {}

    @staticmethod
    def parse_headers(authorization: str | None, node_header: str | None) -> tuple[uuid.UUID, str]:
        if not authorization or not node_header:
            raise AuthError("missing Authorization or X-Node-Id")
        scheme, _, token = authorization.partition(" ")
        if scheme.lower() != "bearer" or not token.strip():
            raise AuthError("Authorization must be Bearer")
        try:
            node_id = uuid.UUID(node_header.strip())
        except ValueError:
            raise AuthError("X-Node-Id is not a UUID") from None
        return node_id, token.strip()

    async def authenticate(self, conn: asyncpg.Connection, node_id: uuid.UUID, token: str) -> NodeInfo:
        """Lempar AuthError (-> 401). Error DB dibiarkan naik (-> 503)."""
        presented = hash_token(token)
        now = time.monotonic()
        cached = self._cache.get(node_id)
        if cached and cached.expires > now and hmac.compare_digest(cached.token_hash, presented):
            return cached
        # Cache kosong, kedaluwarsa, atau tidak cocok: selalu cek ulang ke DB,
        # supaya token yang baru dibuat/dirotasi langsung berlaku.
        row = await db.fetch_node(conn, node_id)
        if row is None or not row["api_token_hash"]:
            raise AuthError("unknown node or no token")
        if not hmac.compare_digest(row["api_token_hash"], presented):
            self._cache.pop(node_id, None)
            raise AuthError("token mismatch")
        info = NodeInfo(node_id, row["plot_id"], row["api_token_hash"], now + CACHE_TTL_S)
        self._cache[node_id] = info
        return info

    def should_touch(self, node_id: uuid.UUID) -> bool:
        now = time.monotonic()
        last = self._last_touch.get(node_id)
        if last is not None and now - last < TOUCH_INTERVAL_S:
            return False
        self._last_touch[node_id] = now
        return True
