"""Authenticated speech routes, with model work isolated from gateway memory."""

from __future__ import annotations

import asyncio
from pathlib import Path
import sys

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field


PROJECT_ROOT = Path(__file__).resolve().parents[2]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))
from speech import clean_fillers
from speech.host_worker import SpeechProcessManager


class RequestBody(BaseModel):
    model_config = ConfigDict(extra="forbid")


class Transcription(RequestBody):
    artifact_id: str = Field(min_length=1, max_length=128)
    language: str | None = Field(default=None, pattern=r"^[a-z]{2,3}$")
    cleanup: bool = False


class Hotword(RequestBody):
    term: str = Field(min_length=1, max_length=80)
    aliases: list[str] = Field(default_factory=list, max_length=10)


class Dictionary(RequestBody):
    hotwords: list[Hotword] = Field(max_length=100)


class Cleanup(RequestBody):
    text: str = Field(max_length=100000)


def build_speech_router(config, artifacts, authenticate):
    manager = SpeechProcessManager(config.data_dir, PROJECT_ROOT)
    router = APIRouter(prefix="/api/speech", dependencies=[Depends(authenticate)])

    def failure(error: Exception):
        if isinstance(error, FileNotFoundError):
            raise HTTPException(404, "还没有找到这段转写。") from error
        if isinstance(error, RuntimeError):
            raise HTTPException(409, str(error)) from error
        if isinstance(error, ValueError):
            raise HTTPException(400, "语音参数尚不完整，请检查录音与热词。") from error
        raise error

    @router.get("/status")
    async def status():
        try:
            return manager.status()
        except (ValueError, OSError) as error:
            raise HTTPException(503, "本地语音设置需要整理，请查看主机配置。") from error

    @router.get("/hotwords")
    async def get_hotwords():
        try:
            return {"hotwords": manager.service().hotwords()}
        except (ValueError, OSError) as error:
            failure(error)

    @router.put("/hotwords")
    async def set_hotwords(body: Dictionary):
        try:
            entries = await asyncio.to_thread(manager.service().set_hotwords, [entry.model_dump() for entry in body.hotwords])
            return {"hotwords": entries}
        except (ValueError, OSError) as error:
            failure(error)

    @router.post("/transcriptions", status_code=202)
    async def transcribe(body: Transcription):
        artifact = artifacts.get(body.artifact_id)
        if artifact is None:
            raise HTTPException(404, "文件柜里还没有这份录音，请先上传。")
        try:
            source = artifacts.object_path(artifact["sha256"])
            if not source.is_file():
                raise HTTPException(404, "这份录音的原件暂时没有找到。")
            return await manager.submit(artifact, source, language=body.language, cleanup=body.cleanup)
        except (ValueError, RuntimeError, FileNotFoundError) as error:
            failure(error)

    @router.get("/transcriptions/{job_id}")
    async def read(job_id: str):
        try:
            return await asyncio.to_thread(manager.read, job_id)
        except (ValueError, FileNotFoundError) as error:
            failure(error)

    @router.post("/transcriptions/{job_id}/stop")
    async def stop(job_id: str):
        try:
            return await manager.stop(job_id)
        except (ValueError, RuntimeError, FileNotFoundError) as error:
            failure(error)

    @router.post("/clean")
    async def clean(body: Cleanup):
        return clean_fillers(body.text)

    return router, manager
