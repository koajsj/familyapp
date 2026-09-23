"""Best-effort cursor notifications; REST pull remains the source of truth."""
from __future__ import annotations

from collections import defaultdict
from typing import DefaultDict
from uuid import UUID

from fastapi import WebSocket


class CursorNotificationHub:
    def __init__(self) -> None:
        self._connections: DefaultDict[tuple[UUID, UUID], set[WebSocket]] = defaultdict(set)

    async def connect(self, member_id: UUID, device_id: UUID, socket: WebSocket) -> None:
        await socket.accept()
        self._connections[(member_id, device_id)].add(socket)

    def disconnect(self, member_id: UUID, device_id: UUID, socket: WebSocket) -> None:
        key = (member_id, device_id)
        self._connections[key].discard(socket)
        if not self._connections[key]:
            self._connections.pop(key, None)

    async def disconnect_device(self, member_id: UUID, device_id: UUID) -> None:
        await self._close_connections([(member_id, device_id)])

    async def disconnect_member(self, member_id: UUID, *, except_device_id: UUID | None = None) -> None:
        keys = [key for key in self._connections if key[0] == member_id and key[1] != except_device_id]
        await self._close_connections(keys)

    async def _close_connections(self, keys: list[tuple[UUID, UUID]]) -> None:
        for key in keys:
            sockets = list(self._connections.pop(key, set()))
            for socket in sockets:
                try:
                    await socket.close(code=1008)
                except Exception:
                    pass

    async def notify_latest_cursor(self, latest_cursor: int) -> None:
        stale: list[tuple[UUID, UUID, WebSocket]] = []
        for (member_id, device_id), sockets in list(self._connections.items()):
            for socket in sockets:
                try:
                    await socket.send_json({"type": "latestCursor", "latestCursor": latest_cursor})
                except Exception:
                    stale.append((member_id, device_id, socket))
        for member_id, device_id, socket in stale:
            self.disconnect(member_id, device_id, socket)
