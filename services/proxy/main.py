from fastapi import FastAPI

from firestore_bridge import router as firestore_router
from proxy import configure_proxy_app, router

app = FastAPI(title="Voice Translation Proxy")
configure_proxy_app(app)
app.include_router(router)
app.include_router(firestore_router)


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}
