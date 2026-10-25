"""Bounded, authenticated LAN API. All job images stay in memory and expire."""
from __future__ import annotations
import asyncio
import contextlib
import secrets
import threading
import time
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from fastapi import FastAPI, HTTPException, Request, Depends
from fastapi.responses import Response
from PIL import Image, UnidentifiedImageError
from .engine import FluxEngine, Cancelled, decode, binary_png
from .download_model import MODEL_ID, REVISION

MAX_UPLOAD = 20 * 1024 * 1024
TTL = 30 * 60

@dataclass
class Job:
    id: str
    status: str = "queued"
    progress: float = 0
    message: str = "Venter på PC"
    seconds: float = 0
    width: int = 0
    height: int = 0
    image: object = None
    output: bytes | None = None
    updated: float = field(default_factory=time.monotonic)
    cancelled: threading.Event = field(default_factory=threading.Event)

    def public(self):
        return {key:getattr(self,key) for key in
                ("id","status","progress","message","seconds","width","height")}

def create_app(token: str, engine=None):
    if len(token) < 32:
        raise ValueError("Use a random pairing token of at least 32 characters")
    engine = engine or FluxEngine()
    jobs: dict[str,Job] = {}
    queue = asyncio.Queue(maxsize=2)
    active = None
    executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="stencil-gpu")

    def expire():
        now = time.monotonic()
        for key in list(jobs):
            if jobs[key].status in {"done","error","cancelled"} and now-jobs[key].updated > TTL:
                del jobs[key]

    async def worker():
        nonlocal active
        loop = asyncio.get_running_loop()
        while True:
            job = await queue.get()
            active = job
            try:
                if job.cancelled.is_set():
                    raise Cancelled()
                job.status, job.message = "running", "Starter lokal model"
                def update(fraction, message):
                    job.progress, job.message = fraction, message
                def generate():
                    output, seconds = engine.generate(job.image, job.cancelled,
                        lambda value, message: loop.call_soon_threadsafe(update,value,message))
                    return binary_png(output), seconds, output.size
                data, seconds, size = await loop.run_in_executor(executor, generate)
                if job.cancelled.is_set():
                    raise Cancelled()
                job.output, job.seconds = data, seconds
                job.width, job.height = size
                job.status, job.progress, job.message = "done", 1, "Stencil klar · kontrollér motivet"
            except Cancelled:
                job.status, job.message = "cancelled", "Afbrudt"
            except asyncio.CancelledError:
                job.cancelled.set()
                raise
            except Exception as error:
                # Do not return file paths, requests, tokens or image data.
                print("Stencil generation failed:", type(error).__name__, flush=True)
                job.status, job.message = "error", "PC-modellen kunne ikke danne stencilen. Se PC-konsollen."
            finally:
                job.image = None
                job.updated = time.monotonic()
                active = None
                queue.task_done()

    @contextlib.asynccontextmanager
    async def lifespan(app):
        task = asyncio.create_task(worker())
        async def janitor():
            while True:
                await asyncio.sleep(15)
                expire()
        cleanup = asyncio.create_task(janitor())
        yield
        for job in jobs.values():
            job.cancelled.set()
        task.cancel()
        cleanup.cancel()
        with contextlib.suppress(asyncio.CancelledError):
            await task
        with contextlib.suppress(asyncio.CancelledError):
            await cleanup
        executor.shutdown(wait=True, cancel_futures=True)

    async def authorize(request: Request):
        supplied = request.headers.get("Authorization", "")
        if not secrets.compare_digest(supplied.encode(), ("Bearer " + token).encode()):
            raise HTTPException(401, "Par appen med PC'en igen.")

    app = FastAPI(lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None,
                  dependencies=[Depends(authorize)])

    @app.middleware("http")
    async def no_cache(request, call_next):
        response = await call_next(request)
        response.headers["Cache-Control"] = "no-store"
        response.headers["X-Content-Type-Options"] = "nosniff"
        return response

    @app.get("/v1/health")
    async def health():
        expire()
        return {"model":MODEL_ID,"revision":REVISION,"state":"busy" if active else "idle",
                "queueDepth":queue.qsize()}

    @app.post("/v1/jobs", status_code=202)
    async def submit(request: Request):
        expire()
        if queue.full() or len(jobs) >= 16:
            raise HTTPException(429, "PC-køen er fuld. Prøv igen senere.")
        data = bytearray()
        async for chunk in request.stream():
            if len(data)+len(chunk) > MAX_UPLOAD:
                raise HTTPException(413,"Billedet er for stort.")
            data.extend(chunk)
        try:
            image = decode(bytes(data))
        except (ValueError, OSError, UnidentifiedImageError, Image.DecompressionBombError):
            raise HTTPException(422,"Billedet kunne ikke åbnes. Brug PNG eller JPEG.") from None
        if queue.full() or len(jobs) >= 16:
            raise HTTPException(429,"PC-køen er fuld. Prøv igen senere.")
        # Uploads are resized before queueing to bound RAM across multiple clients.
        image.thumbnail((1600,1600))
        job = Job(id=uuid.uuid4().hex, image=image)
        jobs[job.id] = job
        queue.put_nowait(job)
        return job.public()

    def find(identifier):
        expire()
        if identifier not in jobs:
            raise HTTPException(404,"Jobbet findes ikke længere. Dan stencilen igen.")
        return jobs[identifier]

    @app.get("/v1/jobs/{identifier}")
    async def status(identifier: str):
        return find(identifier).public()

    @app.get("/v1/jobs/{identifier}/image")
    async def result(identifier: str):
        job = find(identifier)
        if job.status != "done" or job.output is None:
            raise HTTPException(409,"Stencilen er ikke klar.")
        return Response(job.output, media_type="image/png")

    @app.delete("/v1/jobs/{identifier}")
    async def cancel(identifier: str):
        job = find(identifier)
        job.cancelled.set()
        job.output = None
        if job.status != "running":
            job.image = None
            job.status, job.message = "cancelled", "Afbrudt"
        return job.public()

    return app
