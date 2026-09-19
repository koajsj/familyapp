"""Future application composition. Do not run as part of the local Demo."""
from fastapi import FastAPI
from .routers.api import router

app = FastAPI(title="FamilyApp API", version="0.0.1", docs_url=None, redoc_url=None)
app.include_router(router)
