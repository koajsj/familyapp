"""Best-effort cursor notifications; REST pull remains the source of truth."""
from __future__ import annotations

import asyncio
from collections import defaultdict
from typing import DefaultDict
from uuid import UUID

from fastapi import WebSocket


class CursorNotificationHub:
    def __init__(self) -> None:
        self._connections: DefaultDict[tuple[UUID, UUID], set[WebSocket]] = defaultdict(set)
        self._send_locks: dict[WebSocket, asyncio.Lock] = {}

    async def connect(self, member_id: UUID, device_id: UUID, socket: WebSocket) -> None:
        await socket.accept()
        self._connections[(member_id, device_id)].add(socket)
        self._send_locks[socket] = asyncio.Lock()

    def disconnect(self, member_id: UUID, device_id: UUID, socket: WebSocket) -> None:
        key = (member_id, device_id)
        sockets = self._connections.get(key)
        if sockets is not None:
            sockets.discard(socket)
        if not sockets:
            self._connections.pop(key, None)
        self._send_locks.pop(socket, None)

    async def send_cursor(self, socket: WebSocket, latest_cursor: int, *, requires_bootstrap: bool = False) -> None:
        lock = self._send_locks.get(socket)
        if lock is None:
            return
        async with lock:
            await socket.send_json({
                "type": "latestCursor", "latestCursor": latest_cursor,
                "requiresBootstrap": requires_bootstrap, "status": "ready",
            })

    async def disconnect_device(self, member_id: UUID, device_id: UUID) -> None:
        await self._close_connections([(member_id, device_id)])

    async def disconnect_member(self, member_id: UUID, *, except_device_id: UUID | None = None) -> None:
        keys = [key for key in self._connections if key[0] == member_id and key[1] != except_device_id]
        await self._close_connections(keys)

    async def _close_connections(self, keys: list[tuple[UUID, UUID]]) -> None:
        for key in keys:
            sockets = list(self._connections.pop(key, set()))
            for socket in sockets:
                lock = self._send_locks.pop(socket, None)
                try:
                    if lock is not None:
                        async with lock:
                            await socket.close(code=1008)
                    else:
                        await socket.close(code=1008)
                except Exception:
                    pass

    async def notify_latest_cursor(self, latest_cursor: int) -> None:
        stale: list[tuple[UUID, UUID, WebSocket]] = []
        for (member_id, device_id), sockets in list(self._connections.items()):
            for socket in sockets:
                try:
                    await asyncio.wait_for(self.send_cursor(socket, latest_cursor), timeout=2)
                except Exception:
                    stale.append((member_id, device_id, socket))
        for member_id, device_id, socket in stale:
            self.disconnect(member_id, device_id, socket)
            try:
                await asyncio.wait_for(socket.close(code=1011), timeout=2)
            except Exception:
                pass
