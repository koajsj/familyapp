from typing import Generic, Protocol, TypeVar
from uuid import UUID

T = TypeVar("T")


class Repository(Protocol[T]):
    """Future SQLAlchemy repository contract; no database is opened here."""
    async def get(self, identifier: object) -> T | None: ...
    async def save(self, entity: T) -> T: ...


class CursorPage(Generic[T]):
    """Repository-level pagination result; routers convert it to schemas."""
    def __init__(self, items: list[T], next_cursor: str | None = None) -> None:
        self.items = items
        self.next_cursor = next_cursor


class OwnedRepository(Repository[T], Protocol[T]):
    async def list_for_member(self, member_id: UUID, cursor: str | None, limit: int) -> CursorPage[T]: ...
