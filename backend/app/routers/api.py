"""Versioned route namespaces. Endpoints remain intentionally unwired."""
from fastapi import APIRouter, HTTPException, status

router = APIRouter(prefix="/v1")


@router.get("/health", include_in_schema=False)
async def health() -> dict[str, str]:
    return {"status": "scaffold-only"}

def _unwired() -> None:
    raise HTTPException(status_code=status.HTTP_501_NOT_IMPLEMENTED, detail={"code": "scaffold_only", "message": "Backend code has not been wired or run."})


auth_router = APIRouter(prefix="/auth", tags=["auth"])
member_router = APIRouter(prefix="/members", tags=["members"])
chat_router = APIRouter(prefix="/chats", tags=["chat"])
agenda_router = APIRouter(prefix="/agendas", tags=["agenda"])
semester_router = APIRouter(prefix="/semesters", tags=["semester"])
schedule_router = APIRouter(prefix="/schedules", tags=["schedule"])
memo_router = APIRouter(prefix="/memos", tags=["memo"])
notice_router = APIRouter(prefix="/notices", tags=["notice"])
location_router = APIRouter(prefix="/locations", tags=["location"])


@auth_router.post("/login")
async def login_placeholder() -> None: _unwired()

@chat_router.get("/{chat_id}/messages")
async def list_messages_placeholder(chat_id: str, cursor: str | None = None, limit: int = 50) -> None: _unwired()

@agenda_router.get("")
async def list_agendas_placeholder(cursor: str | None = None, limit: int = 50) -> None: _unwired()

@semester_router.get("")
async def list_semesters_placeholder() -> None: _unwired()

@schedule_router.get("")
async def list_schedules_placeholder(semester_id: str, cursor: str | None = None, limit: int = 50) -> None: _unwired()

@memo_router.get("")
async def list_memos_placeholder(cursor: str | None = None, limit: int = 50) -> None: _unwired()

@notice_router.get("")
async def list_notices_placeholder(cursor: str | None = None, limit: int = 50) -> None: _unwired()

@location_router.get("/history")
async def list_locations_placeholder(member_id: str, cursor: str | None = None, limit: int = 50) -> None: _unwired()

for group in (auth_router, member_router, chat_router, agenda_router, semester_router,
              schedule_router, memo_router, notice_router, location_router):
    router.include_router(group)
