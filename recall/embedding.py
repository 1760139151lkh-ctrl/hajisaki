"""Offline BGE Chinese embeddings: CPU ONNX inference, never a model download.

The JSON worker reads one request from stdin and writes one response to stdout.
Use the project Python environment; conversion dependencies are not needed here.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import threading


MODEL_ID = "BAAI/bge-small-zh-v1.5"
REVISION = "7999e1d3359715c523056ef9478215996d62a620"
DIMENSION = 512
TOKEN_LIMIT = 512
QUERY_PREFIX = "为这个句子生成表示以用于检索相关文章："
DEFAULT_MODEL_DIR = Path(__file__).resolve().parent / "models" / "bge-small-zh-v1.5"


class EmbeddingUnavailable(RuntimeError):
    pass


def fingerprint(onnx_sha256: str, tokenizer_sha256: str) -> str:
    description = {"model_id": MODEL_ID, "revision": REVISION, "onnx_sha256": onnx_sha256,
                   "tokenizer_sha256": tokenizer_sha256, "pooling": "CLS_L2",
                   "token_limit": TOKEN_LIMIT, "query_prefix": QUERY_PREFIX}
    return hashlib.sha256(json.dumps(description, sort_keys=True, ensure_ascii=False,
                                    separators=(",", ":")).encode("utf-8")).hexdigest()


class LocalEmbedder:
    def __init__(self, model_dir: str | Path | None = None):
        self.model_dir = Path(model_dir or os.environ.get("HAJI_EMBEDDING_MODEL_DIR", DEFAULT_MODEL_DIR)).expanduser().resolve()
        self._session = None
        self._tokenizer = None
        self._lock = threading.RLock()
        self._failure: str | None = None

    def _provenance(self) -> dict:
        path = self.model_dir / "provenance.json"
        value = json.loads(path.read_text(encoding="utf-8"))
        if value.get("model_id") != MODEL_ID or value.get("revision") != REVISION:
            raise EmbeddingUnavailable("The local embedding model identity does not match the supported BGE revision.")
        expected = fingerprint(value["onnx"]["sha256"], value["files"]["tokenizer.json"]["sha256"])
        if value.get("fingerprint") != expected or value.get("dimension") != DIMENSION or value.get("token_limit") != TOKEN_LIMIT:
            raise EmbeddingUnavailable("The local embedding model metadata is inconsistent.")
        return value

    def status(self) -> dict:
        result = {"state": "unconfigured", "available": False, "model_id": MODEL_ID, "revision": REVISION,
                  "dimension": DIMENSION, "token_limit": TOKEN_LIMIT, "query_prefix": QUERY_PREFIX,
                  "pooling": "CLS_L2", "provider": "CPUExecutionProvider", "model_dir": str(self.model_dir),
                  "fingerprint": None}
        missing = [name for name in ("model.onnx", "tokenizer.json", "provenance.json") if not (self.model_dir / name).is_file()]
        if missing:
            result["reason"] = "Local model setup is incomplete: " + ", ".join(missing)
            return result
        try:
            metadata = self._provenance()
            result["fingerprint"] = metadata["fingerprint"]
            absent = [name for name in ("numpy", "tokenizers", "onnxruntime") if importlib.util.find_spec(name) is None]
            if absent:
                result.update(state="unavailable", reason="Missing local inference dependencies: " + ", ".join(absent))
            elif self._failure:
                result.update(state="unavailable", reason=self._failure)
            else:
                result.update(state="ready" if self._session is not None else "configured", available=True)
        except (OSError, ValueError, KeyError, TypeError, EmbeddingUnavailable) as error:
            result.update(state="unavailable", reason=str(error))
        return result

    def _load(self) -> None:
        if self._session is not None:
            return
        current = self.status()
        if not current["available"]:
            raise EmbeddingUnavailable(current.get("reason", "Local embedding model is unavailable."))
        try:
            import onnxruntime as ort
            from tokenizers import Tokenizer

            metadata = self._provenance()
            for name, expected in (("model.onnx", metadata["onnx"]["sha256"]),
                                   ("tokenizer.json", metadata["files"]["tokenizer.json"]["sha256"])):
                with (self.model_dir / name).open("rb") as handle:
                    actual = hashlib.file_digest(handle, "sha256").hexdigest()
                if actual != expected:
                    raise EmbeddingUnavailable("Local embedding model integrity check failed: " + name)
            tokenizer = Tokenizer.from_file(str(self.model_dir / "tokenizer.json"))
            tokenizer.enable_truncation(max_length=TOKEN_LIMIT)
            tokenizer.enable_padding(pad_id=0, pad_token="[PAD]", direction="right")
            options = ort.SessionOptions()
            options.intra_op_num_threads = min(4, os.cpu_count() or 1)
            options.inter_op_num_threads = 1
            options.log_severity_level = 3
            session = ort.InferenceSession(str(self.model_dir / "model.onnx"), sess_options=options,
                                           providers=["CPUExecutionProvider"])
            if {item.name for item in session.get_inputs()} != {"input_ids", "attention_mask", "token_type_ids"}:
                raise EmbeddingUnavailable("The ONNX input contract is incompatible.")
            self._tokenizer, self._session = tokenizer, session
        except Exception as error:
            self._failure = "Local embedding model could not be loaded: " + str(error)
            raise EmbeddingUnavailable(self._failure) from error

    def encode(self, texts: list[str], query: bool = False) -> list[list[float]]:
        if not isinstance(texts, list) or any(not isinstance(text, str) for text in texts):
            raise ValueError("texts must be a list of strings")
        if type(query) is not bool:
            raise ValueError("query must be boolean")
        if not texts:
            return []
        with self._lock:
            self._load()
            import numpy as np

            vectors = []
            for offset in range(0, len(texts), 16):
                batch = texts[offset:offset + 16]
                if query:
                    batch = [QUERY_PREFIX + text for text in batch]
                encoded = self._tokenizer.encode_batch(batch, add_special_tokens=True)
                inputs = {"input_ids": np.asarray([item.ids for item in encoded], dtype=np.int64),
                          "attention_mask": np.asarray([item.attention_mask for item in encoded], dtype=np.int64),
                          "token_type_ids": np.asarray([item.type_ids for item in encoded], dtype=np.int64)}
                try:
                    output = self._session.run(["embeddings"], inputs)[0]
                except Exception as error:
                    self._failure = "Local embedding inference failed: " + str(error)
                    raise EmbeddingUnavailable(self._failure) from error
                if output.shape != (len(batch), DIMENSION) or not np.isfinite(output).all():
                    raise EmbeddingUnavailable("The embedding model returned invalid vectors.")
                norms = np.linalg.norm(output, axis=1, keepdims=True)
                if np.any(norms <= 0):
                    raise EmbeddingUnavailable("The embedding model returned a zero vector.")
                vectors.extend((output / norms).astype(np.float32).tolist())
            return vectors


def main() -> int:
    sys.stdout.reconfigure(encoding="utf-8")
    try:
        payload = sys.stdin.buffer.read(8 * 1024 * 1024 + 1)
        if len(payload) > 8 * 1024 * 1024:
            raise ValueError("Embedding request exceeds 8 MiB")
        request = json.loads(payload.decode("utf-8"))
        if not isinstance(request, dict) or set(request) - {"texts", "query", "model_dir"}:
            raise ValueError("Invalid embedding request fields")
        texts = request.get("texts")
        if not isinstance(texts, list) or len(texts) > 16:
            raise ValueError("The one-shot worker accepts at most 16 texts")
        embedder = LocalEmbedder(request.get("model_dir"))
        vectors = embedder.encode(texts, query=request.get("query", False))
        metadata = embedder.status()
        result = {"vectors": vectors, **{key: metadata[key] for key in
                  ("model_id", "revision", "dimension", "token_limit", "fingerprint")}}
        print(json.dumps(result, ensure_ascii=False, separators=(",", ":"), allow_nan=False))
        return 0
    except Exception as error:
        print(json.dumps({"error": {"code": "embedding_unavailable" if isinstance(error, EmbeddingUnavailable) else "invalid_request",
                                     "message": str(error)}}, ensure_ascii=False, separators=(",", ":")))
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
