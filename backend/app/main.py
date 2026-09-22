"""Future application composition. Do not run as part of the local Demo."""
from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse
from starlette.middleware.cors import CORSMiddleware
from starlette.middleware.trustedhost import TrustedHostMiddleware

from .config import Settings
from .db import make_session_factory
from .errors import ConflictError, DomainError, ForbiddenError, MediaUnavailableError, NotFoundError, ValidationError
from .routers.api import router
from .services.media_service import build_media_storage
from .services.websocket_service import CursorNotificationHub


def create_app(settings: Settings | None = None) -> FastAPI:
    configured = settings or Settings.from_environment()
    docs_url = "/docs" if configured.openapi_enabled else None
    app = FastAPI(title="FamilyApp API", version="1.0.0", debug=configured.debug, docs_url=docs_url, redoc_url=None, openapi_url="/openapi.json" if configured.openapi_enabled else None)
    # Engine/session construction is lazy: no connection is made until a route
    # receives a request. The current iOS localOnly mode never does so.
    app.state.settings = configured
    app.state.session_factory = make_session_factory(configured)
    app.state.cursor_hub = CursorNotificationHub()
    # This does not make a network request. In the default unconfigured mode
    # it is a small sentinel; the S3 SDK is imported only when explicitly set.
    app.state.media_storage = build_media_storage(configured)

    if configured.allowed_hosts:
        app.add_middleware(TrustedHostMiddleware, allowed_hosts=list(configured.allowed_hosts))
    if configured.cors_origins:
        app.add_middleware(CORSMiddleware, allow_origins=list(configured.cors_origins), allow_credentials=False, allow_methods=["GET", "POST", "PUT", "DELETE"], allow_headers=["Authorization", "Content-Type"])

    @app.middleware("http")
    async def limit_request_size(request: Request, call_next):
        length = request.headers.get("content-length")
        if length is not None and (not length.isdigit() or int(length) > configured.max_request_bytes):
            return JSONResponse(status_code=413, content={"code": "request_too_large", "message": "Request body exceeds the configured limit."})
        return await call_next(request)

    @app.exception_handler(DomainError)
    async def domain_error(_: Request, error: DomainError) -> JSONResponse:
        if isinstance(error, ForbiddenError):
            code, http = "forbidden", 403
        elif isinstance(error, NotFoundError):
            code, http = "not_found", 404
        elif isinstance(error, ConflictError):
            code, http = str(error.args[0]) if error.args else "conflict", 409
        elif isinstance(error, MediaUnavailableError):
            code, http = "media_storage_unavailable", 503
        elif isinstance(error, ValidationError):
            code, http = "validation_error", 422
        else:
            code, http = "domain_error", 400
        return JSONResponse(status_code=http, content={"code": code, "message": "The requested operation cannot be completed."})

    app.include_router(router)
    return app


app = create_app()
