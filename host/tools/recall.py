"""Normal local recall commands; reads only the explicitly selected app instance."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys


ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "host"))
sys.path.insert(0, str(ROOT))
from hajisaki.artifacts import Artifacts
from hajisaki.config import Config
from hajisaki.recall import Recall
from hajisaki.store import Store


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-dir", type=Path, default=ROOT / "runtime")
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("status")
    checkpoint = commands.add_parser("checkpoint")
    checkpoint.add_argument("conversation_id", nargs="?")
    index = commands.add_parser("index")
    index.add_argument("--job-id")
    search = commands.add_parser("search")
    search.add_argument("query")
    search.add_argument("--conversation")
    search.add_argument("--limit", type=int, default=8)
    journal = commands.add_parser("journal")
    journal.add_argument("period", choices=["daily", "weekly"])
    journal.add_argument("--date")
    journal.add_argument("--timezone")
    args = parser.parse_args()
    directory = args.data_dir.expanduser().resolve()
    if not (directory / "hajisaki.sqlite3").is_file():
        raise SystemExit("Select an existing HajiSaki data directory; no new corpus is created.")
    os.environ["HAJI_DATA_DIR"] = str(directory)
    config = Config.load()
    store = Store(directory / "hajisaki.sqlite3")
    recall = Recall(store, directory, Artifacts(config, store))
    if args.command == "status":
        result = recall.status()
    elif args.command == "checkpoint":
        ids = [args.conversation_id] if args.conversation_id else [row["id"] for row in store.all("SELECT id FROM conversations WHERE group_name!='私密保险箱'")]
        result = {"summaries": [record for ident in ids for record in recall.checkpoint(ident)]}
    elif args.command == "index":
        result = recall.index(args.job_id)
    elif args.command == "search":
        result = recall.search(args.query, conversation_id=args.conversation, limit=args.limit)
    else:
        result = recall.journal(args.period, args.date, args.timezone)
    sys.stdout.reconfigure(encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
