from fastapi import FastAPI

from firestore_bridge import router as firestore_router
from proxy import configure_proxy_app, router
from translate_api import router as translate_router

app = FastAPI(title="Voice Translation Proxy")
configure_proxy_app(app)
app.include_router(router)
app.include_router(translate_router)
app.include_router(firestore_router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}
