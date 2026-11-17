"""A file-based, offline-only ASR service; importing it does not load a model."""

from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import threading
import uuid
from typing import Any, Callable


AUDIO_EXTENSIONS = {".wav", ".mp3", ".ogg", ".opus", ".m4a", ".mp4", ".aac", ".flac", ".webm"}
MODEL_FILES = ("model.bin", "config.json", "tokenizer.json", "preprocessor_config.json", "vocabulary.json")
FILLER = re.compile(r"(?<!\w)(?:um+|uh+|erm+)(?!\w)[ ,，]*|(?:(?<=^)|(?<=[，。！？、\s]))(?:嗯+|呃+)(?=[，。！？、\s]|$)[，、\s]*", re.IGNORECASE)


def clean_fillers(text: str) -> dict[str, Any]:
    """Conservative opt-in cleanup. Never removes semantic words such as 那个."""
    edits = [{"start": m.start(), "end": m.end(), "original": m.group(), "replacement": ""}
             for m in FILLER.finditer(text)]
    cleaned = text
    for edit in reversed(edits):
        cleaned = cleaned[:edit["start"]] + cleaned[edit["end"]:]
    return {"original": text, "text": cleaned, "edits": edits, "method": "conservative_filler_removal"}


def _write_json(path: Path, value: Any) -> None:
    temporary = path.with_name(path.name + "." + uuid.uuid4().hex + ".writing")
    with temporary.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())
    temporary.replace(path)


def _number(value: Any) -> float | None:
    if value is None:
        return None
    number = float(value)
    return number if math.isfinite(number) else None


@dataclass(frozen=True)
class SpeechConfig:
    model_path: str | None = None
    device: str = "cpu"
    compute_type: str = "int8"
    cpu_threads: int = 4
    max_audio_bytes: int = 512 * 1024 * 1024
    max_audio_seconds: int = 1800
    uncertain_probability: float = 0.70

    @classmethod
    def from_env(cls) -> "SpeechConfig":
        return cls(
            model_path=os.environ.get("HAJISAKI_SPEECH_MODEL") or None,
            device=os.environ.get("HAJISAKI_SPEECH_DEVICE", "cpu"),
            compute_type=os.environ.get("HAJISAKI_SPEECH_COMPUTE", "int8"),
        )


class SpeechService:
    """Synchronous worker API. Host callers should run ASR outside the event loop.

    The optional ``on_segment`` callback receives provider-derived segments as
    they become available. This is file transcription, not microphone streaming.
    Original audio and unedited transcript are retained in each job directory.
    """

    def __init__(self, data_dir: str | Path, config: SpeechConfig | None = None):
        self.data_dir = Path(data_dir).expanduser().resolve()
        self.config = config or SpeechConfig.from_env()
        if self.config.model_path is not None and not isinstance(self.config.model_path, str):
            raise ValueError("model_path must be a local path string")
        if not isinstance(self.config.device, str) or not isinstance(self.config.compute_type, str):
            raise ValueError("device and compute_type must be strings")
        if any(type(value) is not int for value in (
            self.config.cpu_threads, self.config.max_audio_bytes, self.config.max_audio_seconds
        )) or self.config.cpu_threads < 1:
            raise ValueError("Thread count and audio limits must be positive integers")
        if not isinstance(self.config.uncertain_probability, (int, float)):
            raise ValueError("uncertain_probability must be numeric")
        if self.config.device not in {"cpu", "cuda", "auto"}:
            raise ValueError("device must be cpu, cuda or auto")
        if self.config.max_audio_bytes <= 0 or self.config.max_audio_seconds <= 0:
            raise ValueError("Audio limits must be positive")
        if not 0 <= self.config.uncertain_probability <= 1:
            raise ValueError("uncertain_probability must be between 0 and 1")
        self._model = None
        self._lock = threading.RLock()
        self._last_failure: str | None = None

    def status(self) -> dict[str, Any]:
        dependencies = all(importlib.util.find_spec(name) is not None for name in ("faster_whisper", "av"))
        model = Path(self.config.model_path).expanduser().resolve() if self.config.model_path else None
        model_complete = bool(model and model.is_dir() and all((model / name).is_file() for name in MODEL_FILES))
        if not model_complete:
            state, detail = "unconfigured", "还没有找到完整的本地语音模型。原音可以先留在这里。"
        elif not dependencies:
            state, detail = "dependency_missing", "语音转写需要的本地组件还没有装齐。"
        elif self._model is None:
            state, detail = "configured", "本地语音模型已找到，收到录音后开始加载。"
        else:
            state, detail = "ready", "本地语音模型已备好，录音会留在电脑上处理。"
        return {
            "provider": "faster-whisper", "state": state,
            "available": state in {"configured", "ready"}, "loaded": self._model is not None,
            "last_failure_type": self._last_failure,
            "model_name": model.name if model_complete else None,
            "device": self.config.device, "compute_type": self.config.compute_type,
            "detail": detail,
            "capabilities": {"offline_file_transcription": state in {"configured", "ready"}, "word_timestamps": True,
                             "provider_word_probability": True, "acoustic_nbest_candidates": False,
                             "speaker_diarization": False, "live_microphone": False,
                             "audio_understanding_by_chat_model": False},
            "limits": {"max_bytes": self.config.max_audio_bytes, "max_seconds": self.config.max_audio_seconds},
        }

    def hotwords(self) -> list[dict[str, Any]]:
        path = self.data_dir / "hotwords.json"
        if not path.exists():
            return []
        return self._validate_hotwords(json.loads(path.read_text(encoding="utf-8")))

    @staticmethod
    def _validate_hotwords(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
        if not isinstance(entries, list) or len(entries) > 100:
            raise ValueError("Hotword dictionary must contain at most 100 entries")
        normalized, seen = [], set()
        for entry in entries:
            if not isinstance(entry, dict):
                raise ValueError("Each hotword must be an object")
            term = entry.get("term", "")
            aliases = entry.get("aliases", [])
            if not isinstance(term, str) or not term.strip() or len(term) > 80:
                raise ValueError("Hotword term must contain 1 to 80 characters")
            if not isinstance(aliases, list) or len(aliases) > 10 or any(
                not isinstance(alias, str) or not alias.strip() or len(alias) > 80 for alias in aliases
            ):
                raise ValueError("Hotword aliases must be at most 10 short nonempty strings")
            term = term.strip()
            if term.casefold() in seen:
                raise ValueError("Duplicate hotword term")
            seen.add(term.casefold())
            normalized.append({"term": term, "aliases": list(dict.fromkeys(a.strip() for a in aliases))})
        if sum(len(item["term"]) for item in normalized) > 1000:
            raise ValueError("Total hotword text must not exceed 1000 characters")
        return normalized

    def set_hotwords(self, entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
        normalized = self._validate_hotwords(entries)
        with self._lock:
            self.data_dir.mkdir(parents=True, exist_ok=True)
            _write_json(self.data_dir / "hotwords.json", normalized)
        return normalized

    def _load_model(self):
        if self._model is None:
            from faster_whisper import WhisperModel
            self._model = WhisperModel(
                str(Path(self.config.model_path).expanduser().resolve()),
                device=self.config.device, compute_type=self.config.compute_type,
                cpu_threads=self.config.cpu_threads, num_workers=1, local_files_only=True,
            )
        return self._model

    def unload(self) -> None:
        with self._lock:
            if self._model is not None:
                self._model.model.unload_model()
                self._model = None
            self._last_failure = None

    def _decode_audio(self, path: Path):
        import av
        import numpy as np
        sample_rate = 16000
        limit = self.config.max_audio_seconds * sample_rate
        resampler = av.AudioResampler(format="fltp", layout="mono", rate=sample_rate)
        pieces, count = [], 0
        with path.open("rb") as source, av.open(source, mode="r", options={"protocol_whitelist": "file,pipe"}) as container:
            allowed = {"wav", "mp3", "ogg", "flac", "aac", "mov", "mp4", "m4a", "3gp", "3g2", "mj2", "matroska", "webm"}
            if not set(container.format.name.split(",")).intersection(allowed):
                raise ValueError("Unsupported audio container")
            if not container.streams.audio:
                raise ValueError("The file has no audio stream")
            for frame in container.decode(audio=0):
                for converted in resampler.resample(frame):
                    samples = converted.to_ndarray().reshape(-1).astype(np.float32, copy=False)
                    count += samples.size
                    if count > limit:
                        raise ValueError("Audio duration exceeds the configured limit")
                    pieces.append(samples.copy())
            for converted in resampler.resample(None):
                samples = converted.to_ndarray().reshape(-1).astype(np.float32, copy=False)
                count += samples.size
                if count > limit:
                    raise ValueError("Audio duration exceeds the configured limit")
                pieces.append(samples.copy())
        if not count:
            raise ValueError("The file contains no audio samples")
        return np.concatenate(pieces), count / sample_rate

    def _retain(self, path: Path, job_dir: Path, source_name: str) -> dict[str, Any]:
        digest = hashlib.sha256()
        target = job_dir / ("original" + Path(source_name).suffix.lower())
        size = 0
        with path.open("rb") as source, target.open("xb") as destination:
            while block := source.read(1024 * 1024):
                size += len(block)
                if size > self.config.max_audio_bytes:
                    raise ValueError("Audio file exceeds the configured limit")
                destination.write(block)
                digest.update(block)
            destination.flush()
            os.fsync(destination.fileno())
        return {"name": source_name, "sha256": digest.hexdigest(), "size": size,
                "retained_path": target.relative_to(self.data_dir).as_posix()}

    @staticmethod
    def _suggestions(text: str, entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
        suggestions = []
        for entry in entries:
            for alias in entry["aliases"]:
                if alias.casefold() == entry["term"].casefold():
                    continue
                pattern = re.escape(alias)
                if alias.isascii() and any(c.isalnum() for c in alias):
                    pattern = r"(?<!\w)" + pattern + r"(?!\w)"
                for match in re.finditer(pattern, text, flags=re.IGNORECASE):
                    suggestions.append({"start": match.start(), "end": match.end(), "text": match.group(),
                                        "replacement": entry["term"], "source": "user_dictionary",
                                        "offset_basis": "original_text_unicode_codepoints",
                                        "acoustic_probability": None})
        return sorted(suggestions, key=lambda item: (item["start"], item["end"]))

    def transcribe_file(
        self, path: str | Path, *, language: str | None = None,
        hotwords: list[dict[str, Any]] | None = None, cleanup: bool = False,
        on_segment: Callable[[dict[str, Any]], None] | None = None,
        cancel: threading.Event | None = None,
        source_name: str | None = None, _job_id: str | None = None,
    ) -> dict[str, Any]:
        source = Path(path).expanduser().resolve(strict=True)
        source_name = Path((source_name or source.name).replace("\\", "/")).name
        if not source.is_file() or Path(source_name).suffix.lower() not in AUDIO_EXTENSIONS:
            raise ValueError("Select a supported local audio file")
        if source.stat().st_size > self.config.max_audio_bytes:
            raise ValueError("Audio file exceeds the configured limit")
        entries = self.hotwords() if hotwords is None else self._validate_hotwords(hotwords)
        job_id = _job_id or uuid.uuid4().hex
        if not re.fullmatch(r"[0-9a-f]{32}", job_id):
            raise ValueError("Invalid speech job ID")
        job_dir = self.data_dir / "jobs" / job_id
        job_dir.mkdir(parents=True, exist_ok=True)
        if (job_dir / "metadata.json").exists():
            raise ValueError("This speech job has already started")
        original = self._retain(source, job_dir, source_name)
        result = {"id": job_id, "status": "queued", "created_at": datetime.now(timezone.utc).isoformat(),
                  "provider": "faster-whisper", "original_audio": original, "language": language,
                  "language_probability": None, "duration_seconds": None,
                  "original_text": "", "text": "", "segments": [], "uncertain_spans": [],
                  "dictionary_suggestions": [], "cleanup": None,
                  "capabilities": {"acoustic_nbest_candidates": False, "speaker_diarization": False},
                  "confidence_note": "Provider probabilities are model scores, not calibrated accuracy guarantees."}
        _write_json(job_dir / "metadata.json", result)
        status = self.status()
        if not status["available"]:
            result.update(status=status["state"], detail=status["detail"])
            _write_json(job_dir / "result.json", result)
            return result
        with self._lock:
            try:
                if cancel is not None and cancel.is_set():
                    result["status"] = "cancelled"
                else:
                    audio, duration = self._decode_audio(job_dir / Path(original["retained_path"]).name)
                    result["duration_seconds"] = duration
                    model = self._load_model()
                    segments, info = model.transcribe(
                        audio, language=language, task="transcribe", word_timestamps=True,
                        hotwords=", ".join(item["term"] for item in entries) or None,
                        vad_filter=True, beam_size=5, condition_on_previous_text=True,
                    )
                    result["language"] = info.language
                    result["language_probability"] = _number(info.language_probability) if language is None else None
                    result["status"] = "transcribing"
                    with (job_dir / "segments.jsonl").open("a", encoding="utf-8") as journal:
                        for segment in segments:
                            if cancel is not None and cancel.is_set():
                                result["status"] = "cancelled"
                                break
                            item = {"index": len(result["segments"]), "start": _number(segment.start),
                                    "end": _number(segment.end), "text": segment.text,
                                    "avg_logprob": _number(segment.avg_logprob),
                                    "no_speech_probability": _number(segment.no_speech_prob), "words": []}
                            for word in segment.words or []:
                                item["words"].append({"start": _number(word.start), "end": _number(word.end),
                                                      "text": word.word, "probability": _number(word.probability)})
                            result["segments"].append(item)
                            journal.write(json.dumps(item, ensure_ascii=False, allow_nan=False) + "\n")
                            journal.flush()
                            os.fsync(journal.fileno())
                            if on_segment is not None:
                                on_segment(item)
                        else:
                            result["status"] = "completed"
                    del audio
                    self._last_failure = None
            except Exception as error:
                self._last_failure = type(error).__name__
                explanations = {
                    "Audio duration exceeds the configured limit": "这段录音超过当前时长上限，请分段后再交给我。原音仍然保留。",
                    "Unsupported audio container": "这份录音的封装还不能读取，请换成 WAV、FLAC 或常见录音格式。",
                    "The file has no audio stream": "这份文件里没有可读取的音轨，原件仍然留着。",
                    "The file contains no audio samples": "这份录音没有读到声音样本，原件仍然留着。",
                }
                result.update(status="failed", detail=explanations.get(str(error), "这段录音暂时没能转好，原音和已经听清的部分都留着。"))
                _write_json(job_dir / "diagnostic.json", {"error_type": type(error).__name__, "message": str(error)})
            self._finalize_text(result, entries, cleanup)
            _write_json(job_dir / "result.json", result)
        return result

    def _finalize_text(self, result: dict[str, Any], entries: list[dict[str, Any]], cleanup: bool) -> None:
        result["original_text"] = "".join(item["text"] for item in result["segments"])
        result["text"] = result["original_text"]
        if cleanup:
            result["cleanup"] = clean_fillers(result["original_text"])
            result["text"] = result["cleanup"]["text"]
        base = 0
        for segment in result["segments"]:
            cursor = 0
            for word in segment["words"]:
                offset = segment["text"].find(word["text"], cursor)
                if offset >= 0:
                    cursor = offset + len(word["text"])
                probability = word["probability"]
                if probability is not None and probability < self.config.uncertain_probability:
                    result["uncertain_spans"].append({
                        "segment_index": segment["index"], "start_seconds": word["start"], "end_seconds": word["end"],
                        "text": word["text"], "probability": probability,
                        "char_start": base + offset if offset >= 0 else None,
                        "char_end": base + cursor if offset >= 0 else None,
                        "offset_basis": "original_text_unicode_codepoints", "candidates": [],
                    })
            base += len(segment["text"])
        result["dictionary_suggestions"] = self._suggestions(result["original_text"], entries)

    def read_job(self, job_id: str) -> dict[str, Any]:
        if not re.fullmatch(r"[0-9a-f]{32}", job_id):
            raise ValueError("Invalid speech job ID")
        directory = self.data_dir / "jobs" / job_id
        if (directory / "result.json").exists():
            return json.loads((directory / "result.json").read_text(encoding="utf-8"))
        result = json.loads((directory / "metadata.json").read_text(encoding="utf-8"))
        journal = directory / "segments.jsonl"
        if journal.exists():
            with journal.open(encoding="utf-8") as handle:
                for line in handle:
                    try:
                        result["segments"].append(json.loads(line))
                    except json.JSONDecodeError:
                        break
        result["status"] = "incomplete"
        result["detail"] = "已读回落盘的部分转写，尚未发现最终结果。"
        self._finalize_text(result, [], False)
        return result
