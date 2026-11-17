"""Source-backed checkpoints, private historical retrieval and extractive journals."""

from __future__ import annotations

import asyncio
from datetime import date, datetime, time as local_time, timedelta
import hashlib
import heapq
import json
import os
from pathlib import Path
import re
import struct
import subprocess
import sys
import threading
from typing import Literal
from zoneinfo import ZoneInfo

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from .config import PROJECT_ROOT
from .store import Store, encoded, now, uid


if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

DEFAULTS = {"enabled": True, "semantic_enabled": True, "auto_checkpoint": True,
            "auto_journal": True, "cross_conversation": False,
            "timezone": "America/Los_Angeles", "journal_hour": 4}
ELIGIBLE = ("completed", "stopped", "interrupted", "failed")


def _hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _chunks(text: str, width: int = 420, overlap: int = 60):
    start = 0
    while start < len(text):
        end = min(start + width, len(text))
        if end < len(text):
            boundary = max(text.rfind("\n", start + width // 2, end), text.rfind("。", start + width // 2, end))
            if boundary >= 0:
                end = boundary + 1
        yield start, end, text[start:end]
        if end == len(text):
            break
        start = end - overlap


def _lexemes(text: str) -> set[str]:
    terms = set(re.findall(r"[a-z0-9_]+", text.casefold()))
    for part in re.findall(r"[\u3400-\u9fff]+", text):
        terms.update(part[i:i + 2] for i in range(max(1, len(part) - 1)))
    return terms


class Body(BaseModel):
    model_config = ConfigDict(extra="forbid")


class RecallOptions(Body):
    enabled: bool | None = None
    semantic_enabled: bool | None = None
    auto_checkpoint: bool | None = None
    auto_journal: bool | None = None
    cross_conversation: bool | None = None
    timezone: str | None = Field(default=None, max_length=100)
    journal_hour: int | None = Field(default=None, ge=0, le=23)


class RecordUpdate(Body):
    title: str | None = Field(default=None, min_length=1, max_length=200)
    content: str | None = Field(default=None, min_length=1, max_length=12000)
    enabled: bool | None = None


class MemoryUpdate(Body):
    content: str | None = Field(default=None, min_length=1, max_length=20000)
    enabled: bool | None = None


class Enabled(Body):
    enabled: bool


class CheckpointInput(Body):
    conversation_id: str = Field(min_length=1, max_length=80)


class JournalInput(Body):
    period: Literal["daily", "weekly"] = "daily"
    date: str | None = Field(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$")
    timezone: str | None = Field(default=None, max_length=100)


class Recall:
    def __init__(self, store: Store, data_dir: Path, artifacts=None):
        self.store = store
        self.data_dir = Path(data_dir).resolve()
        self.directory = self.data_dir / "recall"
        self.directory.mkdir(parents=True, exist_ok=True)
        self.artifacts = artifacts
        self._process = None
        self._schedule = None
        self._stop = asyncio.Event()
        self._embedding_lock = threading.Lock()
        self._journal_lock = threading.RLock()
        with store.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS recall_options (id INTEGER PRIMARY KEY CHECK(id=1), value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS recall_records (
                  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
                  method TEXT NOT NULL, title TEXT NOT NULL, content TEXT NOT NULL,
                  source_json TEXT NOT NULL, coverage_json TEXT NOT NULL, source_fingerprint TEXT NOT NULL,
                  block_key TEXT NOT NULL UNIQUE, enabled INTEGER NOT NULL DEFAULT 1,
                  user_edited INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL, updated_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS recall_memory_controls (
                  memory_id TEXT PRIMARY KEY REFERENCES memories(id) ON DELETE CASCADE,
                  enabled INTEGER NOT NULL, updated_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS recall_source_controls (
                  message_id TEXT PRIMARY KEY REFERENCES messages(id) ON DELETE CASCADE,
                  enabled INTEGER NOT NULL, updated_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS recall_vectors (
                  message_id TEXT NOT NULL REFERENCES messages(id), part INTEGER NOT NULL,
                  fingerprint TEXT NOT NULL, source_hash TEXT NOT NULL, start_char INTEGER NOT NULL,
                  end_char INTEGER NOT NULL, excerpt TEXT NOT NULL, dimension INTEGER NOT NULL, vector BLOB NOT NULL,
                  updated_at TEXT NOT NULL, PRIMARY KEY(message_id,part,fingerprint));
                CREATE INDEX IF NOT EXISTS recall_vectors_model ON recall_vectors(fingerprint);
                CREATE TABLE IF NOT EXISTS recall_index_runs (
                  id TEXT PRIMARY KEY, status TEXT NOT NULL, processed INTEGER NOT NULL DEFAULT 0,
                  message_count INTEGER NOT NULL DEFAULT 0, fingerprint TEXT,
                  created_at TEXT NOT NULL, finished_at TEXT, detail TEXT);
                CREATE TABLE IF NOT EXISTS recall_journals (
                  id TEXT PRIMARY KEY, period TEXT NOT NULL, period_date TEXT NOT NULL, timezone TEXT NOT NULL,
                  method TEXT NOT NULL, source_count INTEGER NOT NULL, source_fingerprint TEXT NOT NULL,
                  markdown_path TEXT NOT NULL, json_path TEXT NOT NULL, artifacts_json TEXT NOT NULL,
                  created_at TEXT NOT NULL, UNIQUE(period,period_date,timezone,source_fingerprint));
            ''')
            db.execute("INSERT OR IGNORE INTO recall_options VALUES(1,?)", (encoded(DEFAULTS),))

    def settings(self) -> dict:
        row = self.store.one("SELECT value FROM recall_options WHERE id=1")
        return {**DEFAULTS, **json.loads(row["value"])}

    def update_settings(self, changes: dict) -> dict:
        values = {**self.settings(), **changes}
        ZoneInfo(values["timezone"])
        with self.store.connect() as db:
            db.execute("UPDATE recall_options SET value=? WHERE id=1", (encoded(values),))
        return values

    def embedding_status(self) -> dict:
        try:
            from recall.embedding import LocalEmbedder
            status = LocalEmbedder().status()
            # Host paths are local diagnostics, not phone content.
            status.pop("model_dir", None)
            return status
        except (ImportError, OSError, ValueError) as error:
            return {"available": False, "state": "unconfigured", "reason": type(error).__name__}

    def status(self) -> dict:
        stats = self.store.one("SELECT count(*) AS vectors,count(DISTINCT message_id) AS messages FROM recall_vectors")
        return {"settings": self.settings(), "embedding": self.embedding_status(), "index": stats,
                "summary_count": self.store.one("SELECT count(*) AS n FROM recall_records")["n"],
                "journal_count": self.store.one("SELECT count(*) AS n FROM recall_journals")["n"],
                "last_index": self.store.one("SELECT * FROM recall_index_runs ORDER BY created_at DESC LIMIT 1"),
                "summary_method": "extractive", "llm_synthesis": False,
                "private_vault_included": False}

    def _source_rows(self, conversation_id: str | None = None, before_id: str | None = None):
        conditions = ["m.role IN ('user','assistant')", "length(m.content)>0", "m.status IN ('completed','stopped','interrupted','failed')",
                      "c.group_name != '私密保险箱'"]
        parameters = []
        if conversation_id:
            conditions.append("m.conversation_id=?")
            parameters.append(conversation_id)
        if before_id:
            conditions.append("m.rowid < (SELECT rowid FROM messages WHERE id=?)")
            parameters.append(before_id)
        query = '''SELECT m.*,m.rowid AS ordinal,c.title AS conversation_title,c.archived,
          EXISTS(SELECT 1 FROM runs r JOIN events e ON e.run_id=r.id
            WHERE r.assistant_message_id=m.id AND e.kind='run_started'
            AND CASE WHEN json_valid(e.payload) THEN json_extract(e.payload,'$.simulated') ELSE 0 END=1) AS simulated
          FROM messages m JOIN conversations c ON c.id=m.conversation_id WHERE ''' + " AND ".join(conditions) + " ORDER BY m.rowid"
        with self.store.connect() as db:
            cursor = db.execute(query, tuple(parameters))
            while rows := cursor.fetchmany(100):
                for raw in rows:
                    item = dict(raw)
                    item["content"] = self.store.public_content(item["id"], item["content"])
                    # Forks copy public message content but do not copy the source
                    # run/event row, so retain the development provider marker.
                    if item["role"] == "assistant" and item["content"].lstrip().startswith("**本地演练 · 非模型回答**"):
                        item["simulated"] = True
                    if not item["content"].strip() or (item["role"] == "assistant" and item["simulated"]):
                        continue
                    item["source_hash"] = _hash(item["content"])
                    item["partial"] = item["status"] != "completed"
                    item["simulated"] = bool(item["simulated"])
                    yield item

    @staticmethod
    def _source(message: dict, quote: str | None = None) -> dict:
        result = {key: message[key] for key in ("id", "conversation_id", "conversation_title", "role", "created_at", "source_hash", "partial", "simulated")}
        result["message_id"] = result.pop("id")
        result["representation"] = "public_message"
        result["source_url"] = f"/api/messages/{message['id']}/raw"
        if quote is not None:
            result.update(quote=quote, excerpt=len(quote) < len(message["content"]), start_char=0, end_char=len(quote))
        return result

    def _excluded(self) -> set[str]:
        excluded = {row["message_id"] for row in self.store.all("SELECT message_id FROM recall_source_controls WHERE enabled=0")}
        for row in self.store.all("SELECT coverage_json FROM recall_records WHERE enabled=0"):
            excluded.update(item["message_id"] for item in json.loads(row["coverage_json"]))
        return excluded

    def checkpoint(self, conversation_id: str) -> list[dict]:
        if not self.store.one("SELECT id FROM conversations WHERE id=?", (conversation_id,)):
            raise ValueError("Conversation not found")
        block, records = [], []
        for message in self._source_rows(conversation_id):
            block.append(message)
            if len(block) == 20:
                records.append(self._checkpoint_block(block))
                block = []
        if block:
            records.append(self._checkpoint_block(block))
        return records

    def _checkpoint_block(self, messages: list[dict]) -> dict:
        key = messages[0]["conversation_id"] + ":" + messages[0]["id"]
        coverage = [self._source(item) for item in messages]
        fingerprint = _hash(encoded([(item["id"], item["source_hash"]) for item in messages]))
        existing = self.store.one("SELECT * FROM recall_records WHERE block_key=?", (key,))
        if existing and (existing["user_edited"] or not existing["enabled"] or existing["source_fingerprint"] == fingerprint):
            return self._record(existing)
        # Evenly cover the block, retaining exact words instead of inventing a synthesis.
        indices = sorted({round(i * (len(messages) - 1) / max(1, min(8, len(messages)) - 1)) for i in range(min(8, len(messages)))})
        sources = [self._source(messages[index], messages[index]["content"][:320]) for index in indices]
        content = "\n\n".join(f"{i + 1}. {'你' if item['role'] == 'user' else '哈基祥'}：{item['quote']}" + ("…（节选）" if item["excerpt"] else "") for i, item in enumerate(sources))
        title = messages[0]["conversation_title"][:160]
        ident = existing["id"] if existing else uid()
        with self.store.connect() as db:
            if existing:
                db.execute("UPDATE recall_records SET content=?,source_json=?,coverage_json=?,source_fingerprint=?,updated_at=? WHERE id=?",
                           (content, encoded(sources), encoded(coverage), fingerprint, now(), ident))
            else:
                db.execute("INSERT INTO recall_records VALUES(?,?,?,?,?,?,?,?,?,1,0,?,?)",
                           (ident, messages[0]["conversation_id"], "extractive", title, content, encoded(sources), encoded(coverage), fingerprint, key, now(), now()))
        return self._record(self.store.one("SELECT * FROM recall_records WHERE id=?", (ident,)))

    @staticmethod
    def _record(row: dict) -> dict:
        result = dict(row)
        result["sources"] = json.loads(result.pop("source_json"))
        result["coverage"] = json.loads(result.pop("coverage_json"))
        result["enabled"] = bool(result["enabled"])
        result["user_edited"] = bool(result["user_edited"])
        result.pop("block_key", None)
        return result

    def records(self, conversation_id: str | None = None) -> list[dict]:
        rows = self.store.all("SELECT * FROM recall_records" + (" WHERE conversation_id=?" if conversation_id else "") + " ORDER BY updated_at DESC",
                              (conversation_id,) if conversation_id else ())
        return [self._record(row) for row in rows]

    def update_record(self, ident: str, changes: dict) -> dict:
        with self.store.connect() as db:
            row = db.execute("SELECT * FROM recall_records WHERE id=?", (ident,)).fetchone()
            if row is None:
                raise KeyError(ident)
            edited = "content" in changes or "title" in changes
            db.execute("UPDATE recall_records SET title=?,content=?,enabled=?,user_edited=?,method=?,updated_at=? WHERE id=?",
                       (changes.get("title", row["title"]), changes.get("content", row["content"]), int(changes.get("enabled", bool(row["enabled"]))),
                        int(edited or row["user_edited"]), "user_edited" if edited else row["method"], now(), ident))
        return self._record(self.store.one("SELECT * FROM recall_records WHERE id=?", (ident,)))

    def memories(self, enabled_only: bool = False) -> list[dict]:
        rows = self.store.all("SELECT m.*,COALESCE(c.enabled,1) AS enabled FROM memories m LEFT JOIN recall_memory_controls c ON c.memory_id=m.id ORDER BY m.updated_at DESC")
        return [{**row, "enabled": bool(row["enabled"]), "origin": "user_authored"} for row in rows if not enabled_only or row["enabled"]]

    def memories_for_context(self) -> list[dict]:
        if not self.settings()["enabled"]:
            return []
        return [{"id": item["id"], "content": item["content"], "origin": "user_authored"} for item in self.memories(True)]

    def update_memory(self, ident: str, changes: dict) -> dict:
        with self.store.connect() as db:
            if not db.execute("SELECT id FROM memories WHERE id=?", (ident,)).fetchone():
                raise KeyError(ident)
            if "content" in changes:
                db.execute("UPDATE memories SET content=?,updated_at=? WHERE id=?", (changes["content"], now(), ident))
            if "enabled" in changes:
                db.execute("INSERT INTO recall_memory_controls VALUES(?,?,?) ON CONFLICT(memory_id) DO UPDATE SET enabled=excluded.enabled,updated_at=excluded.updated_at",
                           (ident, int(changes["enabled"]), now()))
        return next(item for item in self.memories() if item["id"] == ident)

    def set_source_enabled(self, message_id: str, enabled: bool) -> dict:
        with self.store.connect() as db:
            if not db.execute("SELECT id FROM messages WHERE id=?", (message_id,)).fetchone():
                raise KeyError(message_id)
            db.execute("INSERT INTO recall_source_controls VALUES(?,?,?) ON CONFLICT(message_id) DO UPDATE SET enabled=excluded.enabled,updated_at=excluded.updated_at",
                       (message_id, int(enabled), now()))
        return {"message_id": message_id, "enabled": enabled}

    def index(self, job_id: str | None = None) -> dict:
        from recall.embedding import LocalEmbedder
        model = LocalEmbedder()
        info = model.status()
        if not info.get("available"):
            raise ValueError("The local neural embedding model is not configured")
        fingerprint = info["fingerprint"]
        job_id = job_id or uid()
        with self.store.connect() as db:
            db.execute("INSERT OR IGNORE INTO recall_index_runs VALUES(?,'running',0,0,?,?,NULL,NULL)", (job_id, fingerprint, now()))
            db.execute("UPDATE recall_index_runs SET status='running',fingerprint=? WHERE id=?", (fingerprint, job_id))
        processed, message_count = 0, 0
        try:
            excluded = self._excluded()
            for message in self._source_rows():
                if message["id"] in excluded:
                    continue
                message_count += 1
                parts = list(_chunks(message["content"]))
                saved = self.store.all("SELECT part,source_hash FROM recall_vectors WHERE message_id=? AND fingerprint=?", (message["id"], fingerprint))
                if len(saved) == len(parts) and all(row["source_hash"] == message["source_hash"] for row in saved):
                    continue
                for offset in range(0, len(parts), 8):
                    batch = parts[offset:offset + 8]
                    vectors = model.encode([part[2] for part in batch])
                    with self.store.connect() as db:
                        for index, (part, vector) in enumerate(zip(batch, vectors)):
                            blob = struct.pack("<" + "f" * len(vector), *vector)
                            db.execute("INSERT INTO recall_vectors VALUES(?,?,?,?,?,?,?,?,?,?) ON CONFLICT(message_id,part,fingerprint) DO UPDATE SET source_hash=excluded.source_hash,start_char=excluded.start_char,end_char=excluded.end_char,excerpt=excluded.excerpt,dimension=excluded.dimension,vector=excluded.vector,updated_at=excluded.updated_at",
                                       (message["id"], offset + index, fingerprint, message["source_hash"], part[0], part[1], part[2], len(vector), blob, now()))
                        processed += len(batch)
                        db.execute("UPDATE recall_index_runs SET processed=?,message_count=? WHERE id=?", (processed, message_count, job_id))
            with self.store.connect() as db:
                db.execute("UPDATE recall_index_runs SET status='completed',processed=?,message_count=?,finished_at=? WHERE id=?", (processed, message_count, now(), job_id))
        except Exception as error:
            with self.store.connect() as db:
                db.execute("UPDATE recall_index_runs SET status='failed',finished_at=?,detail=? WHERE id=?", (now(), "本地回忆索引暂时停住，原文仍在。", job_id))
            (self.directory / f"index-{job_id}-diagnostic.txt").write_text(f"{type(error).__name__}: {error}", encoding="utf-8")
            raise
        return self.store.one("SELECT * FROM recall_index_runs WHERE id=?", (job_id,))

    def start_index(self) -> dict:
        if self._process is not None and self._process.poll() is None:
            return self.store.one("SELECT * FROM recall_index_runs ORDER BY created_at DESC LIMIT 1")
        if not self.embedding_status().get("available"):
            raise ValueError("本地语义模型还没有接好，可以先按原文查找。")
        ident = uid()
        with self.store.connect() as db:
            db.execute("INSERT INTO recall_index_runs VALUES(?,'queued',0,0,NULL,?,NULL,NULL)", (ident, now()))
        with (self.directory / f"index-{ident}.log").open("ab") as log:
            self._process = subprocess.Popen([sys.executable, str(PROJECT_ROOT / "host/tools/recall.py"), "--data-dir", str(self.data_dir), "index", "--job-id", ident],
                                             cwd=PROJECT_ROOT, shell=False, stdout=log, stderr=subprocess.STDOUT,
                                             creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
                                             env={**os.environ, "PYTHONUTF8": "1", "HF_HUB_OFFLINE": "1"})
        return self.store.one("SELECT * FROM recall_index_runs WHERE id=?", (ident,))

    def _query_vector(self, query: str) -> list[float]:
        with self._embedding_lock:
            process = subprocess.run([sys.executable, str(PROJECT_ROOT / "recall/embedding.py")],
                                     input=json.dumps({"texts": [query[:420]], "query": True}).encode("utf-8"),
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=PROJECT_ROOT, shell=False,
                                     creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0,
                                     env={**os.environ, "PYTHONUTF8": "1", "HF_HUB_OFFLINE": "1"})
        if process.returncode:
            raise RuntimeError("Local embedding worker failed")
        return json.loads(process.stdout)["vectors"][0]

    def search(self, query: str, *, conversation_id: str | None = None, limit: int = 8,
               before_id: str | None = None, exclude_ids: set[str] | None = None, include_disabled: bool = False) -> dict:
        if not query.strip() or len(query) > 2000 or not 1 <= limit <= 20:
            raise ValueError("Use a query of 1 to 2000 characters and a limit from 1 to 20")
        excluded = set(exclude_ids or ()) | (set() if include_disabled else self._excluded())
        sources = {row["id"]: row for row in self._source_rows(conversation_id, before_id) if row["id"] not in excluded}
        status = self.embedding_status()
        hits, mode = [], "lexical"
        warning = None
        if self.settings()["semantic_enabled"] and status.get("available"):
            try:
                import numpy as np
                query_vector = np.asarray(self._query_vector(query), dtype=np.float32)
                heap, sequence = [], 0
                with self.store.connect() as db:
                    cursor = db.execute("SELECT * FROM recall_vectors WHERE fingerprint=?", (status["fingerprint"],))
                    while batch := cursor.fetchmany(128):
                        valid = [dict(row) for row in batch if row["message_id"] in sources and sources[row["message_id"]]["source_hash"] == row["source_hash"]]
                        if not valid:
                            continue
                        vectors = np.stack([np.frombuffer(row["vector"], dtype="<f4") for row in valid])
                        scores = vectors @ query_vector
                        for row, score in zip(valid, scores.tolist()):
                            sequence += 1
                            item = (float(score), sequence, row)
                            if len(heap) < limit * 4:
                                heapq.heappush(heap, item)
                            elif score > heap[0][0]:
                                heapq.heapreplace(heap, item)
                seen = set()
                for score, _, row in sorted(heap, reverse=True):
                    if row["message_id"] in seen:
                        continue
                    seen.add(row["message_id"])
                    hits.append(self._hit(sources[row["message_id"]], row["excerpt"], row["start_char"], row["end_char"], score))
                    if len(hits) == limit:
                        break
                mode = "neural" if heap else "lexical"
            except (ImportError, OSError, ValueError, RuntimeError):
                warning = "语义索引暂时没有展开，这次先按原文找。"
        if mode == "lexical":
            terms = _lexemes(query)
            candidates = []
            for source in sources.values():
                best = None
                for start, end, excerpt in _chunks(source["content"]):
                    overlap = len(terms & _lexemes(excerpt))
                    score = overlap / max(1, len(terms))
                    if query.casefold() in excerpt.casefold():
                        score += 1
                    if score > 0 and (best is None or score > best[0]):
                        best = (score, start, end, excerpt)
                if best:
                    candidates.append(self._hit(source, best[3], best[1], best[2], best[0]))
            hits = sorted(candidates, key=lambda item: item["score"], reverse=True)[:limit]
        return {"mode": mode, "model_id": status.get("model_id") if mode == "neural" else None,
                "fingerprint": status.get("fingerprint") if mode == "neural" else None,
                "query_excerpt_only": len(query) > 420 and mode == "neural", "hits": hits,
                "searched_messages": len(sources), "warning": warning,
                "score_meaning": "relative cosine ranking, not calibrated confidence" if mode == "neural" else "literal word and character overlap"}

    def _hit(self, source: dict, excerpt: str, start: int, end: int, score: float) -> dict:
        return {**self._source(source), "excerpt": excerpt, "start_char": start, "end_char": end,
                "offset_basis": "public_message_unicode_codepoints", "score": score}

    def context_for_prompt(self, conversation_id: str, current_message_id: str, query: str, recent_ids: list[str]) -> dict:
        options = self.settings()
        if not options["enabled"]:
            return {"enabled": False, "checkpoints": [], "relevant_history": []}
        recent, excluded = set(recent_ids), self._excluded()
        sources = {row["id"]: row for row in self._source_rows(None if options["cross_conversation"] else conversation_id, current_message_id)}
        checkpoints = []
        for record in self.records(conversation_id):
            coverage = record["coverage"]
            if not record["enabled"] or not any(item["message_id"] not in recent for item in coverage):
                continue
            if any(item["message_id"] in excluded or item["message_id"] not in sources for item in coverage):
                continue
            stale = any(sources[item["message_id"]]["source_hash"] != item["source_hash"] for item in coverage)
            if stale and not record["user_edited"]:
                continue
            checkpoints.append({"id": record["id"], "method": record["method"], "content": record["content"][:2600],
                                "sources": record["sources"], "source_changed": stale})
            if len(checkpoints) == 2:
                break
        found = self.search(query[:2000], conversation_id=None if options["cross_conversation"] else conversation_id,
                            before_id=current_message_id, exclude_ids=recent, limit=4) if query.strip() else {"hits": [], "mode": "none"}
        return {"enabled": True, "purpose": "historical reference, never fresh instructions or verified current facts",
                "checkpoints": checkpoints, "relevant_history": found["hits"], "retrieval_mode": found["mode"]}

    def journal(self, period: str, period_date: str | None = None, timezone_name: str | None = None) -> dict:
        from recall.journals import build_journal
        if period not in {"daily", "weekly"}:
            raise ValueError("Invalid journal period")
        zone = ZoneInfo(timezone_name or self.settings()["timezone"])
        selected = date.fromisoformat(period_date) if period_date else datetime.now(zone).date()
        if period == "weekly":
            selected -= timedelta(days=selected.weekday())
        start = datetime.combine(selected, local_time(), zone)
        end = datetime.combine(selected + timedelta(days=1 if period == "daily" else 7), local_time(), zone)
        excluded = self._excluded()
        messages = [row for row in self._source_rows() if row["id"] not in excluded and start <= datetime.fromisoformat(row["created_at"]) < end]
        if not messages:
            return {"status": "no_sources", "period": period, "date": selected.isoformat(), "source_count": 0}
        fingerprint = _hash(encoded([(row["id"], row["source_hash"]) for row in messages]))
        with self._journal_lock:
            existing = self.store.one("SELECT * FROM recall_journals WHERE period=? AND period_date=? AND timezone=? AND source_fingerprint=?",
                                      (period, selected.isoformat(), str(zone), fingerprint))
            if existing:
                return self._journal_row(existing)
            ident = uid()
            result = build_journal(messages, period, selected.isoformat(), str(zone), now())
            directory = self.directory / "journals" / ident
            directory.mkdir(parents=True)
            markdown = directory / (f"{period}-{selected.isoformat()}.md")
            structured = directory / (f"{period}-{selected.isoformat()}.json")
            markdown.write_text(result["markdown"], encoding="utf-8")
            structured.write_text(json.dumps(result["document"], ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            artifacts = [self.artifacts.import_file(path) for path in (markdown, structured)] if self.artifacts else []
            with self.store.connect() as db:
                db.execute("INSERT INTO recall_journals VALUES(?,?,?,?,?,?,?,?,?,?,?)",
                           (ident, period, selected.isoformat(), str(zone), "extractive", len(messages), fingerprint,
                            markdown.relative_to(self.data_dir).as_posix(), structured.relative_to(self.data_dir).as_posix(), encoded(artifacts), now()))
            return self._journal_row(self.store.one("SELECT * FROM recall_journals WHERE id=?", (ident,)))

    @staticmethod
    def _journal_row(row: dict) -> dict:
        result = dict(row)
        result["artifacts"] = json.loads(result.pop("artifacts_json"))
        result.pop("markdown_path", None)
        result.pop("json_path", None)
        result["status"] = "completed"
        return result

    def export_entries(self) -> list[tuple[str, Path]]:
        return [("recall/" + path.relative_to(self.directory).as_posix(), path) for path in (self.directory / "journals").rglob("*")
                if path.is_file() and path.suffix in {".md", ".json"} and path.resolve().is_relative_to(self.directory)]

    async def start(self) -> None:
        if self._schedule is None:
            self._schedule = asyncio.create_task(self._background())

    async def _background(self) -> None:
        checked = set()
        while not self._stop.is_set():
            try:
                options = self.settings()
                if options["enabled"] and options["auto_checkpoint"]:
                    for row in self.store.all("SELECT id FROM conversations WHERE group_name!='私密保险箱'"):
                        await asyncio.to_thread(self.checkpoint, row["id"])
                if options["enabled"] and options["semantic_enabled"] and self.embedding_status().get("available"):
                    self.start_index()
                current = datetime.now(ZoneInfo(options["timezone"]))
                if options["enabled"] and options["auto_journal"] and current.hour >= options["journal_hour"]:
                    previous = current.date() - timedelta(days=1)
                    for period, target in [("daily", previous)] + ([("weekly", current.date() - timedelta(days=7))] if current.weekday() == 0 else []):
                        key = (period, target.isoformat(), options["timezone"])
                        if key not in checked:
                            await asyncio.to_thread(self.journal, period, target.isoformat(), options["timezone"])
                            checked.add(key)
            except Exception as error:
                (self.directory / "scheduler-diagnostic.txt").write_text(f"{type(error).__name__}: {error}", encoding="utf-8")
            try:
                await asyncio.wait_for(self._stop.wait(), timeout=600)
            except asyncio.TimeoutError:
                pass

    async def close(self) -> None:
        self._stop.set()
        if self._schedule is not None:
            await self._schedule

    def router(self, authenticate) -> APIRouter:
        router = APIRouter(prefix="/api/recall", dependencies=[Depends(authenticate)])

        @router.get("/status")
        async def status():
            return self.status()

        @router.get("/settings")
        async def settings():
            return self.settings()

        @router.patch("/settings")
        async def update_settings(body: RecallOptions):
            try:
                return self.update_settings(body.model_dump(exclude_none=True))
            except (ValueError, KeyError):
                raise HTTPException(422, "这个时区暂时没有找到，请换一个明确的时区名称。")

        @router.get("/summaries")
        async def summaries(conversation_id: str | None = None):
            return {"summaries": self.records(conversation_id)}

        @router.post("/summaries")
        async def checkpoint(body: CheckpointInput):
            try:
                return {"summaries": await asyncio.to_thread(self.checkpoint, body.conversation_id)}
            except ValueError:
                raise HTTPException(404, "这一页乐章暂时没有找到。")

        @router.patch("/summaries/{ident}")
        async def update_record(ident: str, body: RecordUpdate):
            try:
                return self.update_record(ident, body.model_dump(exclude_none=True))
            except KeyError:
                raise HTTPException(404, "这页回忆暂时没有找到。")

        @router.get("/memories")
        async def memories():
            return {"memories": self.memories()}

        @router.patch("/memories/{ident}")
        async def update_memory(ident: str, body: MemoryUpdate):
            try:
                return self.update_memory(ident, body.model_dump(exclude_none=True))
            except KeyError:
                raise HTTPException(404, "这条记忆暂时没有找到。")

        @router.patch("/sources/{message_id}")
        async def source_enabled(message_id: str, body: Enabled):
            try:
                return self.set_source_enabled(message_id, body.enabled)
            except KeyError:
                raise HTTPException(404, "这段原话暂时没有找到。")

        @router.get("/search")
        async def search(q: str, conversation_id: str | None = None, limit: int = 8, include_disabled: bool = False):
            try:
                return await asyncio.to_thread(self.search, q, conversation_id=conversation_id, limit=limit, include_disabled=include_disabled)
            except ValueError:
                raise HTTPException(422, "先用一小段话说说想找的回忆。")

        @router.post("/index", status_code=202)
        async def index():
            try:
                return self.start_index()
            except ValueError as error:
                raise HTTPException(409, str(error))

        @router.get("/index/{ident}")
        async def index_status(ident: str):
            result = self.store.one("SELECT * FROM recall_index_runs WHERE id=?", (ident,))
            if not result:
                raise HTTPException(404, "这次索引记录暂时没有找到。")
            return result

        @router.get("/journals")
        async def journals():
            return {"journals": [self._journal_row(row) for row in self.store.all("SELECT * FROM recall_journals ORDER BY created_at DESC")]}

        @router.post("/journals")
        async def journal(body: JournalInput):
            try:
                return await asyncio.to_thread(self.journal, body.period, body.date, body.timezone)
            except (ValueError, KeyError):
                raise HTTPException(422, "这段日期或时区还没写完整。")

        return router
