"""Normal command-line entry point: python -m speech --help."""

import argparse
from dataclasses import replace
import json
from pathlib import Path
import sys

from .service import SpeechConfig, SpeechService, clean_fillers


def main() -> int:
    parser = argparse.ArgumentParser(description="HajiSaki offline audio preprocessing")
    parser.add_argument("--data-dir", type=Path, default=Path("runtime/speech"))
    parser.add_argument("--model", help="Existing local CTranslate2 Whisper model directory; never downloaded")
    parser.add_argument("--device", choices=["cpu", "cuda", "auto"])
    parser.add_argument("--compute", help="CTranslate2 compute type, such as int8 or float16")
    subcommands = parser.add_subparsers(dest="command", required=True)
    subcommands.add_parser("status")
    transcribe = subcommands.add_parser("transcribe")
    transcribe.add_argument("file", type=Path)
    transcribe.add_argument("--language")
    transcribe.add_argument("--cleanup", action="store_true")
    transcribe.add_argument("--hotwords", type=Path, help="JSON dictionary; omitted uses saved dictionary")
    read = subcommands.add_parser("read")
    read.add_argument("job_id")
    words = subcommands.add_parser("hotwords")
    words.add_argument("--import-file", type=Path)
    clean = subcommands.add_parser("clean")
    clean.add_argument("text", nargs="?", help="Omitted reads stdin")
    arguments = parser.parse_args()
    config = SpeechConfig.from_env()
    if arguments.model:
        config = replace(config, model_path=arguments.model)
    if arguments.device:
        config = replace(config, device=arguments.device)
    if arguments.compute:
        config = replace(config, compute_type=arguments.compute)
    service = SpeechService(arguments.data_dir, config)
    if arguments.command == "status":
        result = service.status()
    elif arguments.command == "transcribe":
        entries = json.loads(arguments.hotwords.read_text(encoding="utf-8")) if arguments.hotwords else None
        result = service.transcribe_file(arguments.file, language=arguments.language,
                                         hotwords=entries, cleanup=arguments.cleanup)
    elif arguments.command == "read":
        result = service.read_job(arguments.job_id)
    elif arguments.command == "hotwords":
        result = service.set_hotwords(json.loads(arguments.import_file.read_text(encoding="utf-8"))) if arguments.import_file else service.hotwords()
    else:
        result = clean_fillers(arguments.text if arguments.text is not None else sys.stdin.read())
    sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))
    if isinstance(result, dict) and result.get("status") in {"failed", "unconfigured", "dependency_missing", "cancelled"}:
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
