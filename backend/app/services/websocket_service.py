"""Best-effort cursor notifications; REST pull remains the source of truth."""
from __future__ import annotations

from collections import defaultdict
from typing import DefaultDict
from uuid import UUID

from fastapi import WebSocket


class CursorNotificationHub:
    def __init__(self) -> None:
        self._connections: DefaultDict[UUID, set[WebSocket]] = defaultdict(set)

    async def connect(self, member_id: UUID, socket: WebSocket) -> None:
        await socket.accept()
        self._connections[member_id].add(socket)

    def disconnect(self, member_id: UUID, socket: WebSocket) -> None:
        self._connections[member_id].discard(socket)
        if not self._connections[member_id]:
            self._connections.pop(member_id, None)

    async def notify_latest_cursor(self, latest_cursor: int) -> None:
        stale: list[tuple[UUID, WebSocket]] = []
        for member_id, sockets in self._connections.items():
            for socket in sockets:
                try:
                    await socket.send_json({"type": "latestCursor", "latestCursor": latest_cursor})
                except Exception:
                    stale.append((member_id, socket))
        for member_id, socket in stale:
            self.disconnect(member_id, socket)
