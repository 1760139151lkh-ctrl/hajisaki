"""Install small isolated conversion tools, fetch pinned BGE sources, export ONNX.

Run with an existing Python that already has PyTorch installed:
  python recall/setup_embedding.py prepare

Production inference uses only requirements-embedding.txt and the exported files.
This utility never installs Torch or changes the base/project Python environments.
"""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import importlib.metadata
import json
import os
from pathlib import Path
import subprocess
import sys
import urllib.request
import uuid


PROJECT_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT_ROOT))
from recall.embedding import DEFAULT_MODEL_DIR, DIMENSION, MODEL_ID, QUERY_PREFIX, REVISION, TOKEN_LIMIT, fingerprint

FILES = ("config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json",
         "special_tokens_map.json", "vocab.txt", "README.md", "sentence_bert_config.json",
         "1_Pooling/config.json", "modules.json", "config_sentence_transformers.json")
EXPECTED_WEIGHT_BYTES = 95827648
DEFAULT_CONVERSION_DEPS = Path(__file__).resolve().parent / "models" / ".conversion-deps"


def hidden_run(arguments: list[str], *, env: dict | None = None) -> None:
    child_env = {**os.environ, **(env or {}), "PYTHONUTF8": "1", "PYTHONIOENCODING": "utf-8",
                 "PIP_PROGRESS_BAR": "off"}
    subprocess.run(arguments, shell=False, check=True, cwd=PROJECT_ROOT, env=child_env,
                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
                   stdout=sys.stderr, stderr=sys.stderr)


def write_json(path: Path, value: dict) -> None:
    if path.exists():
        existing = json.loads(path.read_text(encoding="utf-8"))
        if existing == value:
            return
        raise ValueError("Existing model metadata differs; use a separate model directory: " + str(path))
    with path.open("x", encoding="utf-8") as handle:
        json.dump(value, handle, ensure_ascii=False, indent=2, allow_nan=False)
        handle.write("\n")
        handle.flush()
        os.fsync(handle.fileno())


def fetch(url: str):
    request = urllib.request.Request(url, headers={"User-Agent": "HajiSaki-Local-Model-Setup/1"})
    return urllib.request.urlopen(request, timeout=60)


def sha256(path: Path) -> str:
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def download(model_dir: Path) -> dict:
    model_dir.mkdir(parents=True, exist_ok=True)
    api = f"https://huggingface.co/api/models/{MODEL_ID}/tree/{REVISION}?recursive=true"
    with fetch(api) as response:
        listing = json.load(response)
    metadata = {item["path"]: item for item in listing if item["type"] == "file"}
    if metadata["model.safetensors"]["size"] != EXPECTED_WEIGHT_BYTES:
        raise ValueError("Pinned model weight size differs from the verified official model.")
    files = {}
    for name in FILES:
        entry = metadata[name]
        destination = model_dir.joinpath(*name.split("/"))
        destination.parent.mkdir(parents=True, exist_ok=True)
        url = f"https://huggingface.co/{MODEL_ID}/resolve/{REVISION}/{name}"
        expected_size = entry["size"]
        expected_lfs = entry.get("lfs", {}).get("oid")
        candidate = destination
        if not destination.exists():
            candidate = destination.with_name(destination.name + "." + uuid.uuid4().hex + ".partial")
            print("Downloading official source: " + name, file=sys.stderr, flush=True)
            with fetch(url) as response, candidate.open("xb") as handle:
                while block := response.read(1024 * 1024):
                    handle.write(block)
                handle.flush()
                os.fsync(handle.fileno())
        actual_sha = sha256(candidate)
        if candidate.stat().st_size != expected_size:
            raise ValueError("Official source length mismatch: " + name)
        if expected_lfs:
            if actual_sha != expected_lfs:
                raise ValueError("Official source SHA-256 mismatch: " + name)
        else:
            git_hash = hashlib.sha1(f"blob {expected_size}\0".encode())
            with candidate.open("rb") as handle:
                while block := handle.read(1024 * 1024):
                    git_hash.update(block)
            if git_hash.hexdigest() != entry["oid"]:
                raise ValueError("Pinned source Git object mismatch: " + name)
        if candidate != destination:
            candidate.rename(destination)
        files[name] = {"source": url, "bytes": expected_size, "sha256": actual_sha,
                       "git_oid": entry["oid"], "lfs_sha256": expected_lfs}
    source = {"model_id": MODEL_ID, "revision": REVISION, "license": "MIT",
              "model_card": f"https://huggingface.co/{MODEL_ID}/blob/{REVISION}/README.md", "files": files}
    write_json(model_dir / "source-provenance.json", source)
    return source


def install_conversion(dependencies: Path) -> None:
    # --no-deps prevents dependency resolution from fetching another Torch build.
    # Standard support packages (numpy, requests, regex, fsspec, packaging,
    # filelock, typing_extensions) are supplied by the chosen existing Python.
    required = ("torch", "numpy", "requests", "regex", "fsspec", "packaging", "filelock", "typing_extensions")
    absent = []
    for name in required:
        try:
            importlib.metadata.version(name)
        except importlib.metadata.PackageNotFoundError:
            absent.append(name)
    if absent:
        raise RuntimeError("The selected conversion Python lacks existing dependencies: " + ", ".join(absent))
    dependencies.mkdir(parents=True, exist_ok=True)
    hidden_run([sys.executable, "-m", "pip", "install", "--disable-pip-version-check", "--no-deps",
                "--only-binary=:all:", "--target", str(dependencies), "-r",
                str(Path(__file__).with_name("requirements-embedding-conversion.txt"))])


def convert(model_dir: Path) -> dict:
    import torch
    import onnx
    from tokenizers import Tokenizer
    from transformers import AutoModel

    provenance = json.loads((model_dir / "source-provenance.json").read_text(encoding="utf-8"))
    if provenance.get("model_id") != MODEL_ID or provenance.get("revision") != REVISION:
        raise ValueError("Conversion requires the pinned official source files.")
    for name, entry in provenance["files"].items():
        if sha256(model_dir.joinpath(*name.split("/"))) != entry["sha256"]:
            raise ValueError("Source integrity changed before conversion: " + name)
    target = model_dir / "model.onnx"
    if target.exists():
        current = json.loads((model_dir / "provenance.json").read_text(encoding="utf-8"))
        if sha256(target) != current["onnx"]["sha256"]:
            raise ValueError("An existing ONNX model has changed; use a separate model directory.")
        return current
    torch.set_num_threads(min(4, os.cpu_count() or 1))
    model = AutoModel.from_pretrained(str(model_dir), local_files_only=True, trust_remote_code=False,
                                     use_safetensors=True, attn_implementation="eager").cpu().eval()

    class SentenceEmbedding(torch.nn.Module):
        def __init__(self, encoder):
            super().__init__()
            self.encoder = encoder

        def forward(self, input_ids, attention_mask, token_type_ids):
            output = self.encoder(input_ids=input_ids, attention_mask=attention_mask,
                                  token_type_ids=token_type_ids, return_dict=False)
            return torch.nn.functional.normalize(output[0][:, 0], p=2, dim=1)

    wrapper = SentenceEmbedding(model).eval()
    tokenizer = Tokenizer.from_file(str(model_dir / "tokenizer.json"))
    tokenizer.enable_padding(pad_id=0, pad_token="[PAD]")
    # These are export trace inputs, not a synthetic evaluation corpus.
    encoded = tokenizer.encode_batch(["记忆与学习计划", "琴房里的钢琴"])
    inputs = tuple(torch.tensor([getattr(item, key) for item in encoded], dtype=torch.int64)
                   for key in ("ids", "attention_mask", "type_ids"))
    temporary = target.with_name("model." + uuid.uuid4().hex + ".partial.onnx")
    with torch.inference_mode():
        torch.onnx.export(wrapper, inputs, str(temporary), input_names=["input_ids", "attention_mask", "token_type_ids"],
                          output_names=["embeddings"], opset_version=17, dynamo=False, external_data=False,
                          dynamic_axes={"input_ids": {0: "batch", 1: "sequence"}, "attention_mask": {0: "batch", 1: "sequence"},
                                        "token_type_ids": {0: "batch", 1: "sequence"}, "embeddings": {0: "batch"}},
                          do_constant_folding=True)
    onnx.checker.check_model(str(temporary), full_check=True)
    with temporary.open("rb+") as handle:
        os.fsync(handle.fileno())
    temporary.rename(target)
    model_sha = sha256(target)
    result = {**provenance, "dimension": DIMENSION, "token_limit": TOKEN_LIMIT,
              "query_prefix": QUERY_PREFIX, "pooling": "CLS_L2", "dtype": "float32",
              "onnx": {"path": "model.onnx", "sha256": model_sha, "bytes": target.stat().st_size,
                       "opset": 17, "inputs": ["input_ids", "attention_mask", "token_type_ids"], "output": "embeddings"},
              "fingerprint": fingerprint(model_sha, provenance["files"]["tokenizer.json"]["sha256"]),
              "converted_at": datetime.now(timezone.utc).isoformat(),
              "conversion_versions": {name: importlib.metadata.version(name) for name in
                                      ("torch", "transformers", "onnx", "safetensors", "tokenizers")}}
    write_json(model_dir / "provenance.json", result)
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("prepare", "download", "install-conversion-deps", "convert"))
    parser.add_argument("--model-dir", type=Path, default=DEFAULT_MODEL_DIR)
    parser.add_argument("--conversion-deps", type=Path, default=DEFAULT_CONVERSION_DEPS)
    parser.add_argument("--conversion-child", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    sys.stdout.reconfigure(encoding="utf-8")
    sys.stderr.reconfigure(encoding="utf-8")
    model_dir, dependencies = args.model_dir.resolve(), args.conversion_deps.resolve()
    if args.command in {"prepare", "download"}:
        download(model_dir)
    if args.command in {"prepare", "install-conversion-deps"}:
        install_conversion(dependencies)
    if args.command in {"prepare", "convert"}:
        if args.conversion_child:
            result = convert(model_dir)
        else:
            env = {**os.environ, "PYTHONPATH": str(dependencies), "PYTHONUTF8": "1",
                   "USE_TF": "0", "USE_FLAX": "0", "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
                   "TOKENIZERS_PARALLELISM": "false"}
            hidden_run([sys.executable, str(Path(__file__).resolve()), "convert", "--conversion-child",
                        "--model-dir", str(model_dir), "--conversion-deps", str(dependencies)], env=env)
            result = json.loads((model_dir / "provenance.json").read_text(encoding="utf-8"))
        print(json.dumps({key: result[key] for key in ("model_id", "revision", "fingerprint", "dimension", "token_limit", "onnx")}, indent=2))
    else:
        print(json.dumps({"status": "complete", "command": args.command, "model_dir": str(model_dir),
                          "conversion_dependencies": str(dependencies)}, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
