"""Durable one-process ASR queue plus its hidden Python worker entry point."""

from __future__ import annotations

import asyncio
from dataclasses import asdict
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import threading
import time
import uuid
from typing import Any

from .service import AUDIO_EXTENSIONS, SpeechConfig, SpeechService, _write_json


TERMINAL = {"completed", "cancelled", "failed", "interrupted", "unconfigured", "dependency_missing"}


def _pid_alive(pid: int | None) -> bool:
    if not pid:
        return False
    if os.name != "nt":
        try:
            os.kill(pid, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
    import ctypes
    from ctypes import wintypes
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
    kernel.OpenProcess.restype = wintypes.HANDLE
    kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
    kernel.CloseHandle.argtypes = [wintypes.HANDLE]
    handle = kernel.OpenProcess(0x100000, False, pid)  # SYNCHRONIZE
    if not handle:
        return False
    try:
        return kernel.WaitForSingleObject(handle, 0) == 0x102
    finally:
        kernel.CloseHandle(handle)


def _watch_parent(parent_pid: int) -> None:
    """Stop only this worker when its owning gateway has actually exited."""
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes
        kernel = ctypes.WinDLL("kernel32", use_last_error=True)
        kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        kernel.OpenProcess.restype = wintypes.HANDLE
        kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        handle = kernel.OpenProcess(0x100000, False, parent_pid)
        if handle:
            kernel.WaitForSingleObject(handle, 0xFFFFFFFF)
        os._exit(70)
    else:
        while os.getppid() == parent_pid:
            time.sleep(1)
        os._exit(70)


class SpeechProcessManager:
    def __init__(self, host_data_dir: Path, project_root: Path):
        self.project_root = Path(project_root).resolve()
        self.data_dir = Path(host_data_dir).resolve() / "speech"
        self.settings_file = self.project_root / "runtime" / "speech-settings.json"
        self._slot = asyncio.Lock()
        self._tasks: dict[str, asyncio.Task] = {}
        self._processes: dict[str, subprocess.Popen] = {}
        self._closed = False
        self._state_lock = threading.RLock()
        self._bad_state_files: set[str] = set()

    def configuration(self) -> SpeechConfig:
        values = asdict(SpeechConfig.from_env())
        if self.settings_file.exists():
            settings = json.loads(self.settings_file.read_text(encoding="utf-8"))
            allowed = set(values)
            if not isinstance(settings, dict) or set(settings) - allowed:
                raise ValueError("Unknown local speech setting")
            values.update(settings)
        for field, variable in (("model_path", "HAJISAKI_SPEECH_MODEL"), ("device", "HAJISAKI_SPEECH_DEVICE"),
                                ("compute_type", "HAJISAKI_SPEECH_COMPUTE")):
            if os.environ.get(variable):
                values[field] = os.environ[variable]
        return SpeechConfig(**values)

    def service(self) -> SpeechService:
        return SpeechService(self.data_dir, self.configuration())

    def status(self) -> dict[str, Any]:
        status = self.service().status()
        status.update({"worker_limit": 1, "active_jobs": list(self._processes),
                       "queued_jobs": [key for key in self._tasks if key not in self._processes]})
        return status

    def _directory(self, job_id: str) -> Path:
        if not re.fullmatch(r"[0-9a-f]{32}", job_id):
            raise ValueError("Invalid speech job ID")
        return self.data_dir / "jobs" / job_id

    def _state(self, job_id: str) -> dict[str, Any]:
        return json.loads((self._directory(job_id) / "state.json").read_text(encoding="utf-8"))

    def _states(self):
        for path in (self.data_dir / "jobs").glob("*/state.json"):
            try:
                state = json.loads(path.read_text(encoding="utf-8"))
                if not isinstance(state, dict) or state.get("status") not in TERMINAL | {"queued", "running"}:
                    raise ValueError("Invalid persisted speech state")
                if not re.fullmatch(r"[0-9a-f]{32}", path.parent.name):
                    raise ValueError("Invalid persisted speech ID")
                yield path, state
            except (ValueError, OSError) as error:
                if str(path) not in self._bad_state_files:
                    self._bad_state_files.add(str(path))
                    self.data_dir.mkdir(parents=True, exist_ok=True)
                    with (self.data_dir / "manager-diagnostics.jsonl").open("a", encoding="utf-8") as log:
                        log.write(json.dumps({"job": path.parent.name, "error": type(error).__name__,
                                              "message": str(error), "at": time.time()}) + "\n")

    def export_entries(self) -> list[tuple[str, Path]]:
        entries = []
        dictionary = self.data_dir / "hotwords.json"
        if dictionary.is_file() and dictionary.resolve().is_relative_to(self.data_dir):
            entries.append(("speech/hotwords.json", dictionary))
        for directory in (self.data_dir / "jobs").glob("*"):
            if not re.fullmatch(r"[0-9a-f]{32}", directory.name) or not directory.is_dir():
                continue
            for path in directory.iterdir():
                allowed = path.name in {"metadata.json", "segments.jsonl", "result.json"} or (
                    path.stem == "original" and path.suffix.lower() in AUDIO_EXTENSIONS)
                if allowed and path.is_file() and path.resolve().is_relative_to(self.data_dir):
                    entries.append(("speech/" + path.relative_to(self.data_dir).as_posix(), path))
        return entries

    def _change_state(self, job_id: str, *, expected_status: str | None = None, **changes: Any) -> None:
        with self._state_lock:
            state = self._state(job_id)
            if expected_status is not None and state["status"] != expected_status:
                return
            state.update(changes)
            _write_json(self._directory(job_id) / "state.json", state)

    async def start(self) -> None:
        self.data_dir.mkdir(parents=True, exist_ok=True)
        for path, state in self._states():
            job_id = path.parent.name
            if state["status"] == "queued":
                if (path.parent / "metadata.json").exists():
                    self._change_state(job_id, status="interrupted", detail="上次转写已经开始，已完成片段仍保留，请重新发起剩余转写。")
                else:
                    self._schedule(job_id)
            elif state["status"] == "running" and not _pid_alive(state.get("worker_pid")):
                self._change_state(job_id, expected_status="running", status="interrupted", detail="上次转写已中断，原音与已完成片段都还在。")

    def _schedule(self, job_id: str) -> None:
        task = asyncio.create_task(self._run(job_id))
        self._tasks[job_id] = task
        task.add_done_callback(lambda _: self._tasks.pop(job_id, None))

    async def submit(self, artifact: dict[str, Any], source: Path, *, language: str | None, cleanup: bool) -> dict[str, Any]:
        if self._closed:
            raise RuntimeError("语音工坊正在收尾，请稍后再试。")
        if len(self._tasks) >= 16:
            raise RuntimeError("待转写的录音有些多，先等前面的听完吧。")
        config = self.configuration()
        if artifact["size"] > config.max_audio_bytes:
            raise ValueError("这份录音超过本地语音处理的容量限制。")
        if Path(artifact["name"]).suffix.lower() not in AUDIO_EXTENSIONS:
            raise ValueError("请先选择一份支持的录音文件。")
        status = self.service().status()
        if not status["available"]:
            raise RuntimeError(status["detail"])
        # A prior gateway's worker is never duplicated while it is still alive.
        for path, state in self._states():
            if state["status"] == "running" and path.parent.name not in self._processes and _pid_alive(state.get("worker_pid")):
                raise RuntimeError("上次转写仍在进行，等它收尾后再接下一段。")
        job_id = uuid.uuid4().hex
        directory = self._directory(job_id)
        directory.mkdir(parents=True)
        request = {"id": job_id, "source": str(source.resolve()), "source_name": artifact["name"],
                   "artifact": artifact, "language": language, "cleanup": cleanup,
                   "data_dir": str(self.data_dir), "configuration": asdict(config),
                   "hotwords": self.service().hotwords()}
        _write_json(directory / "request.json", request)
        _write_json(directory / "state.json", {"id": job_id, "status": "queued", "artifact": artifact,
                                               "created_at": time.time(), "worker_pid": None})
        self._schedule(job_id)
        return self.read(job_id)

    async def _run(self, job_id: str) -> None:
        async with self._slot:
            # A worker from the preceding owning process gets time to finish or
            # observe its parent's exit. Waiting never starts a duplicate worker.
            while not self._closed:
                alive = False
                for path, state in self._states():
                    if path.parent.name != job_id and state["status"] == "running" and _pid_alive(state.get("worker_pid")):
                        alive = True
                        break
                if not alive:
                    break
                await asyncio.sleep(1)
            if self._closed or self._state(job_id)["status"] != "queued":
                return
            directory = self._directory(job_id)
            process = None
            try:
                with (directory / "worker.log").open("ab") as log:
                    process = subprocess.Popen(
                        [sys.executable, "-m", "speech.host_worker", str(directory / "request.json"), str(os.getpid())],
                        cwd=self.project_root, shell=False,
                        creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
                        stdout=log, stderr=subprocess.STDOUT,
                        env={**os.environ, "PYTHONUTF8": "1", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1"},
                    )
                    self._processes[job_id] = process
                    self._change_state(job_id, status="running", worker_pid=process.pid)
                    # No inference deadline: healthy local work may take as long as needed.
                    code = await asyncio.to_thread(process.wait)
                    state = self._state(job_id)
                    if state["status"] == "running":
                        result_path = directory / "result.json"
                        if result_path.exists():
                            result = json.loads(result_path.read_text(encoding="utf-8"))
                            self._change_state(job_id, expected_status="running", status=result["status"], exit_code=code)
                        else:
                            self._change_state(job_id, expected_status="running", status="failed", exit_code=code,
                                               detail="这次转写没有完成，原音和落盘片段仍然保留。")
            except Exception as error:
                self._change_state(job_id, status="failed", detail="本地语音工坊没能启动，原音仍在文件柜。")
                _write_json(directory / "launch-diagnostic.json", {"type": type(error).__name__, "message": str(error)})
            finally:
                if process is not None and process.poll() is None:
                    process.terminate()
                    await asyncio.to_thread(process.wait)
                self._processes.pop(job_id, None)

    def read(self, job_id: str) -> dict[str, Any]:
        state = self._state(job_id)
        directory = self._directory(job_id)
        if state["status"] == "running" and job_id not in self._processes and not _pid_alive(state.get("worker_pid")):
            self._change_state(job_id, expected_status="running", status="interrupted", detail="上次转写已中断，原音与已完成片段都还在。")
            state = self._state(job_id)
        if (directory / "metadata.json").exists():
            result = SpeechService(self.data_dir).read_job(job_id)
        else:
            result = {"id": job_id, "original_text": "", "text": "", "segments": [], "uncertain_spans": [],
                      "dictionary_suggestions": [], "cleanup": None}
        result["status"] = state["status"]
        artifact = state["artifact"]
        result["artifact_id"] = artifact["id"]
        result["original_audio"] = {key: artifact[key] for key in ("name", "size", "sha256", "url")}
        result["progress"] = {"segments": len(result["segments"]),
                              "through_seconds": result["segments"][-1]["end"] if result["segments"] else 0}
        if state.get("detail"):
            result["detail"] = state["detail"]
        elif state["status"] in {"queued", "running", "completed"}:
            result.pop("detail", None)
        return result

    async def stop(self, job_id: str, reason: str = "cancelled") -> dict[str, Any]:
        state = self._state(job_id)
        if state["status"] in TERMINAL:
            return self.read(job_id)
        process = self._processes.get(job_id)
        if state["status"] == "running" and process is None and _pid_alive(state.get("worker_pid")):
            raise RuntimeError("这段转写仍由上一个主机进程持有，请在它的窗口中停止。")
        self._change_state(job_id, expected_status=state["status"], status=reason, detail="先停在这里，原音和已经转好的部分都已留存。")
        if process is not None and process.poll() is None:
            process.terminate()
            await asyncio.to_thread(process.wait)
        return self.read(job_id)

    async def close(self) -> None:
        self._closed = True
        for job_id in list(self._processes):
            await self.stop(job_id, "interrupted")
        # Queued request files survive shutdown for the next lifecycle.
        await asyncio.gather(*list(self._tasks.values()), return_exceptions=True)


def run_worker(request_path: str, parent_pid: int) -> int:
    threading.Thread(target=_watch_parent, args=(parent_pid,), daemon=True).start()
    request = json.loads(Path(request_path).read_text(encoding="utf-8"))
    service = SpeechService(request["data_dir"], SpeechConfig(**request["configuration"]))
    result = service.transcribe_file(
        request["source"], source_name=request["source_name"], _job_id=request["id"],
        language=request["language"], cleanup=request["cleanup"], hotwords=request["hotwords"],
    )
    print(json.dumps({"id": result["id"], "status": result["status"]}))
    return 0 if result["status"] == "completed" else 2


if __name__ == "__main__":
    raise SystemExit(run_worker(sys.argv[1], int(sys.argv[2])))
