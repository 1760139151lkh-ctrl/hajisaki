"""Authenticated, bounded photo/scratchpad editing; inputs are data, never code."""
from __future__ import annotations

import asyncio
import hashlib
import json
import os
import re
from pathlib import Path
import subprocess
import sys
import threading
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel, ConfigDict, Field, model_validator

from .artifacts import Artifacts
from .store import now, uid


class Point(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)
    x: float = Field(ge=0, le=1)
    y: float = Field(ge=0, le=1)


class ImageOperation(BaseModel):
    model_config = ConfigDict(extra='forbid', allow_inf_nan=False)
    kind: Literal['pen', 'number', 'mosaic', 'rotate', 'perspective', 'paper']
    points: list[Point] = Field(default_factory=list, max_length=2048)
    color: str = Field(default='#385B92FF', pattern=r'^#[0-9A-Fa-f]{6}[Ff]{2}$')
    width: float = Field(default=0.008, ge=0.001, le=0.08)
    number: int = Field(default=1, ge=1, le=999)

    @model_validator(mode='after')
    def geometry(self):
        count = len(self.points)
        if ((self.kind == 'pen' and count < 1)
                or (self.kind == 'number' and count != 1)
                or (self.kind == 'mosaic' and count != 2)
                or (self.kind == 'perspective' and count != 4)
                or (self.kind in {'rotate', 'paper'} and count != 0)):
            raise ValueError('The selected tool has incomplete geometry')
        if self.kind == 'perspective':
            points = self.points
            crosses = [(points[(i+1)%4].x-points[i].x)*(points[(i+2)%4].y-points[(i+1)%4].y)
                       - (points[(i+1)%4].y-points[i].y)*(points[(i+2)%4].x-points[(i+1)%4].x)
                       for i in range(4)]
            area = sum(points[i].x*points[(i+1)%4].y-points[(i+1)%4].x*points[i].y for i in range(4))/2
            if min(crosses) < 0.001 or area < 0.01:
                raise ValueError('The four corners must enclose a clockwise, convex page')
        return self


class ImageEdit(BaseModel):
    model_config = ConfigDict(extra='forbid')
    source_id: str = Field(default='', max_length=80, pattern=r'^[A-Za-z0-9_-]*$')
    operations: list[ImageOperation] = Field(default_factory=list, max_length=400)

    @model_validator(mode='after')
    def budget(self):
        if sum(len(op.points) for op in self.operations) > 32000:
            raise ValueError('The drawing has too many points')
        if sum(op.kind in {'rotate', 'perspective', 'paper'} for op in self.operations) > 12:
            raise ValueError('The drawing has too many image transforms')
        return self


class ImageExport(ImageEdit):
    operation_id: str = Field(min_length=1, max_length=100, pattern=r'^[A-Za-z0-9_-]+$')


class ImageStudio:
    def __init__(self, artifacts: Artifacts):
        self.artifacts = artifacts
        self.slots = threading.BoundedSemaphore(2)
        self.export_lock = threading.Lock()
        self.output = artifacts.config.data_dir / 'image-studio'
        self.output.mkdir(exist_ok=True)
        with artifacts.store.connect() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS image_studio_exports (
                device TEXT NOT NULL, operation_id TEXT NOT NULL, payload_hash TEXT NOT NULL,
                artifact_id TEXT NOT NULL, created_at TEXT NOT NULL,
                PRIMARY KEY(device,operation_id))''')
            db.execute('''CREATE TABLE IF NOT EXISTS image_previews (
                sha256 TEXT NOT NULL, width INTEGER NOT NULL, body TEXT NOT NULL,
                PRIMARY KEY(sha256,width))''')

    def _payload(self, body: ImageEdit) -> dict:
        payload = {'operations': [op.model_dump() for op in body.operations]}
        if body.source_id:
            source = self.artifacts.get(body.source_id)
            if source is None:
                raise HTTPException(404, '原图还没有找到，请从档案重新选择。')
            if source['size'] > 64*1024**2:
                raise HTTPException(413, '这张原图较大，请先缩小尺寸再展开。')
            payload['path'] = str(self.artifacts.object_path(source['sha256']))
            payload['source_sha256'] = source['sha256']
        return payload

    def _render(self, payload: dict) -> dict:
        if not self.slots.acquire(timeout=2):
            raise HTTPException(429, '还有画页正在展开，稍等一下再试。')
        try:
            try:
                result = subprocess.run([sys.executable, str(Path(__file__).with_name('image_studio_worker.py'))],
                    input=json.dumps(payload, allow_nan=False).encode('utf-8'),
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, shell=False, timeout=25,
                    creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
            except subprocess.TimeoutExpired:
                raise HTTPException(422, '这张画页处理得太久，原稿仍在，可以撤销一步再试。') from None
            if result.returncode:
                raise HTTPException(422, '这张原图暂时不能安全展开，请保留原件，换一张较小的图片。')
            try:
                rendered = json.loads(result.stdout)
            except (ValueError, UnicodeError):
                raise HTTPException(422, '画页还没有完整收齐，原稿仍在。') from None
            if not rendered.get('supported'):
                raise HTTPException(422, rendered.get('reason', '这张画页暂时没能展开。'))
            return rendered
        finally:
            self.slots.release()

    def preview(self, body: ImageEdit) -> dict:
        return self._render(self._payload(body))

    def thumbnail(self, artifact_id: str, width: int = 480) -> dict:
        if not re.fullmatch(r'[0-9a-f]{32}',artifact_id):
            raise HTTPException(404,'这份画面暂时没有找到。')
        variant = 480 if width <= 480 else 960
        payload = self._payload(ImageEdit(source_id=artifact_id))
        digest = payload['source_sha256']
        cached = self.artifacts.store.one('SELECT body FROM image_previews WHERE sha256=? AND width=?', (digest,variant))
        if cached:
            try:
                data = json.loads(cached['body'])
                if isinstance(data,dict) and data.get('supported') and data.get('source_sha256') == digest:
                    return data
            except (ValueError, TypeError):
                pass
        payload['thumbnail_width'] = variant
        rendered = {**self._render(payload), 'source_sha256':digest}
        with self.artifacts.store.connect() as db:
            db.execute('INSERT INTO image_previews VALUES(?,?,?) ON CONFLICT(sha256,width) DO UPDATE SET body=excluded.body',
                       (digest,variant,json.dumps(rendered,separators=(',',':'))))
        return rendered

    def image_info(self, artifact_id: str) -> dict:
        preview = self.thumbnail(artifact_id,480)
        return {key:preview[key] for key in ('supported','width','height','thumbhash','source_sha256','animated')}

    def export(self, body: ImageExport, device: str) -> dict:
        # Serializing the small import transaction also prevents duplicate export
        # requests from producing two artifacts after an uncertain response.
        digest = hashlib.sha256(body.model_dump_json(exclude={'operation_id'}).encode('utf-8')).hexdigest()
        if not self.export_lock.acquire(timeout=2):
            raise HTTPException(429, '还有画页正在收好，稍等一下再试。')
        try:
            saved = self.artifacts.store.one('SELECT * FROM image_studio_exports WHERE device=? AND operation_id=?',
                                            (device, body.operation_id))
            if saved:
                if saved['payload_hash'] != digest:
                    raise HTTPException(409, '这份导出已收好；修改后的画页需要重新导出。')
                return self.artifacts.get(saved['artifact_id'])
            payload = self._payload(body)
            name = '画页-' + uid() + '.png'
            path = self.output / name
            payload['output'] = str(path)
            self._render(payload)
            # The renderer owns this new file. Move its verified PNG into CAS;
            # an already-present duplicate goes directly to the Recycle Bin.
            with path.open('rb') as stream:
                image_hash = hashlib.file_digest(stream, 'sha256').hexdigest()
            size = path.stat().st_size
            target = self.artifacts.object_path(image_hash)
            artifact_id = uid()
            with self.artifacts.lock, self.artifacts.store.connect() as db:
                target.parent.mkdir(exist_ok=True)
                if target.exists():
                    from send2trash import send2trash
                    send2trash(str(path))
                else:
                    path.rename(target)
                db.execute('INSERT INTO artifacts VALUES(?,?,?,?,?,?)',
                           (artifact_id, '祥子画页.png', size, 'image/png', image_hash, now()))
                db.execute('INSERT INTO image_studio_exports VALUES(?,?,?,?,?)',
                           (device, body.operation_id, digest, artifact_id, now()))
            return self.artifacts.get(artifact_id)
        finally:
            self.export_lock.release()

    def router(self, authenticate) -> APIRouter:
        router = APIRouter(prefix='/api', dependencies=[Depends(authenticate)])

        @router.post('/image-studio/preview')
        async def preview(body: ImageEdit):
            return await asyncio.to_thread(self.preview, body)

        @router.post('/image-studio/export')
        async def export(body: ImageExport, principal=Depends(authenticate)):
            return await asyncio.to_thread(self.export, body, principal.device_id)

        @router.get('/artifacts/{artifact_id}/thumbnail')
        async def image_thumbnail(artifact_id: str, width: int = Query(default=480, ge=160, le=960)):
            return await asyncio.to_thread(self.thumbnail, artifact_id, width)

        @router.get('/artifacts/{artifact_id}/image-info')
        async def image_info(artifact_id: str):
            return await asyncio.to_thread(self.image_info, artifact_id)

        return router
