"""Bounded document exports using trusted workers, never model-supplied code."""
from __future__ import annotations

import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid
from typing import Annotated, Callable

from pydantic import BaseModel, ConfigDict, Field, model_validator

MAX_EXPORT_INPUT = 1024 * 1024
MAX_PACKAGE_BYTES = 64 * 1024**2
MAX_EXPORT_BYTES = 80 * 1024**2


class ExportInput(BaseModel):
    model_config = ConfigDict(extra="forbid", strict=True, allow_inf_nan=False)


class PdfInput(ExportInput):
    name: str = Field(min_length=1, max_length=180)
    title: str = Field(min_length=1, max_length=200)
    markdown: str = Field(max_length=MAX_EXPORT_INPUT)


Cell = (Annotated[str, Field(max_length=1000)] |
        Annotated[int, Field(ge=-10**15, le=10**15)] |
        Annotated[float, Field(ge=-10**15, le=10**15)] | bool | None)


class WorksheetInput(ExportInput):
    name: str = Field(min_length=1, max_length=31, pattern=r"^[^\[\]:*?/\\]+$")
    columns: list[Annotated[str, Field(min_length=1, max_length=100)]] = Field(min_length=1, max_length=32)
    rows: list[list[Cell]] = Field(default_factory=list, max_length=1000)

    @model_validator(mode="after")
    def shape(self):
        if self.name != self.name.strip() or self.name.startswith("'") or self.name.endswith("'"):
            raise ValueError("The worksheet name has unsupported edge characters.")
        if any(len(row) > len(self.columns) for row in self.rows):
            raise ValueError("Worksheet rows cannot exceed their declared columns.")
        return self


class SpreadsheetInput(ExportInput):
    name: str = Field(min_length=1, max_length=180)
    sheets: list[WorksheetInput] = Field(min_length=1, max_length=12)

    @model_validator(mode="after")
    def workbook_shape(self):
        if len({sheet.name.casefold() for sheet in self.sheets}) != len(self.sheets):
            raise ValueError("Worksheet names must be unique.")
        if sum((len(sheet.rows) + 1) * len(sheet.columns) for sheet in self.sheets) > 10000:
            raise ValueError("The workbook exceeds the 10000-cell export budget.")
        return self


class ZipInput(ExportInput):
    name: str = Field(min_length=1, max_length=180)
    artifact_ids: list[Annotated[str, Field(pattern=r"^[0-9a-f]{32}$")]] = Field(min_length=1, max_length=64)

    @model_validator(mode="after")
    def unique_sources(self):
        if len(set(self.artifact_ids)) != len(self.artifact_ids):
            raise ValueError("Choose each original once.")
        return self


class ExportError(ValueError):
    pass


class ExportJobs:
    def __init__(self, data_dir: Path):
        self.data_dir = data_dir
        self.slots = threading.BoundedSemaphore(2)

    @staticmethod
    def capabilities() -> dict:
        font = Path(os.environ.get("WINDIR", "C:/Windows")) / "Fonts/msyh.ttc"
        return {"pdf_export": bool(importlib.util.find_spec("reportlab") and font.is_file()),
                "xlsx_export": bool(importlib.util.find_spec("openpyxl")), "zip_export": True}

    def run(self, kind: str, payload: dict, output_root: Path, check_active: Callable[[], object]) -> dict:
        encoded = json.dumps(payload, ensure_ascii=False, allow_nan=False).encode("utf-8")
        if len(encoded) > MAX_EXPORT_INPUT:
            raise ExportError("这一份成品的输入超过1MiB，请分成几份。")
        while not self.slots.acquire(timeout=0.25):
            check_active()
        try:
            check_active()
            job = self.data_dir / "agent-jobs" / uuid.uuid4().hex
            job.mkdir(parents=True)
            request_path = job / "request.json"
            request_path.write_text(json.dumps({"kind": kind, "payload": payload,
                "output_root": str(output_root)}, ensure_ascii=False, allow_nan=False), encoding="utf-8")
            environment = dict(os.environ)
            for name in ("HAJI_AGENT_TOKEN", "HAJI_AGENT_GRANT_FILE", "GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_APPLICATION_CREDENTIALS"):
                environment.pop(name, None)
            environment["PYTHONUTF8"] = "1"
            started = time.monotonic()
            with (job / "worker.log").open("wb") as log:
                process = subprocess.Popen([sys.executable, str(Path(__file__).with_name("export_worker.py")), str(request_path)],
                    shell=False, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                    env=environment, creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
                try:
                    while True:
                        check_active()
                        try:
                            code = process.wait(timeout=0.25)
                            break
                        except subprocess.TimeoutExpired:
                            if time.monotonic() - started > 45:
                                raise ExportError("这一份成品展开得太久，已停下生成；原有资料都在。")
                    if code:
                        result_path = job / 'result.json'
                        if result_path.is_file() and result_path.stat().st_size <= 8192:
                            detail = json.loads(result_path.read_text(encoding='utf-8')).get('error')
                            if isinstance(detail,str) and len(detail)<=1000:
                                raise ExportError(detail)
                        raise ExportError("这一份成品暂时没能写完，原有资料仍在。")
                    result = json.loads((job / "result.json").read_text(encoding="utf-8"))
                    check_active()
                    path = output_root / payload["name"]
                    if not path.is_file() or not 0 < path.stat().st_size <= MAX_EXPORT_BYTES:
                        raise ExportError("这份原件还没有完整写好，请分段后重试。")
                    return {**result, "duration_seconds": round(time.monotonic() - started, 3)}
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=3)
        finally:
            self.slots.release()
