from uuid import UUID
from ..errors import ForbiddenError


def require_owner(actor_id: UUID, owner_id: UUID) -> None:
    if actor_id != owner_id:
        raise ForbiddenError("owner permission required")


def require_publisher(actor_id: UUID, publisher_id: UUID) -> None:
    if actor_id != publisher_id:
        raise ForbiddenError("publisher permission required")


def require_creator(actor_id: UUID, creator_id: UUID) -> None:
    if actor_id != creator_id:
        raise ForbiddenError("creator permission required")


def require_memo_delete(actor_id: UUID, creator_id: UUID) -> None:
    require_creator(actor_id, creator_id)


def require_member_place_owner(actor_id: UUID, member_id: UUID) -> None:
    require_owner(actor_id, member_id)


def require_member_status_owner(actor_id: UUID, member_id: UUID) -> None:
    require_owner(actor_id, member_id)
