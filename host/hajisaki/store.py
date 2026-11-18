from __future__ import annotations

import json
import sqlite3
import threading
import uuid
from contextlib import contextmanager
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable, Iterator


def now() -> str:
    return datetime.now(timezone.utc).isoformat()


def uid() -> str:
    return uuid.uuid4().hex


def encoded(value: Any) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


DEFAULT_SETTINGS = {
    "theme": "auto", "transparency": "balanced", "sound": False,
    "personality": {"formality": 65, "detail": 50, "teasing": 25}, "nickname": "",
}


class Store:
    def __init__(self, path: Path):
        self.path = path
        self.lock = threading.RLock()
        self.on_commit: Callable[[], None] | None = None
        with self.connect() as db:
            db.executescript("""
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=FULL;
                CREATE TABLE IF NOT EXISTS conversations (
                    id TEXT PRIMARY KEY, title TEXT NOT NULL, group_name TEXT NOT NULL,
                    pinned INTEGER NOT NULL DEFAULT 0, archived INTEGER NOT NULL DEFAULT 0,
                    created_at TEXT NOT NULL, updated_at TEXT NOT NULL, provider_id TEXT
                );
                CREATE TABLE IF NOT EXISTS messages (
                    id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
                    role TEXT NOT NULL, content TEXT NOT NULL DEFAULT '', status TEXT NOT NULL,
                    created_at TEXT NOT NULL, attachments TEXT NOT NULL DEFAULT '[]',
                    client_id TEXT, UNIQUE(conversation_id, client_id)
                );
                CREATE INDEX IF NOT EXISTS messages_conversation ON messages(conversation_id, created_at);
                CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(content, content='messages', content_rowid='rowid');
                CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
                    INSERT INTO message_search(rowid,content) VALUES(new.rowid,new.content);
                END;
                CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE OF content ON messages BEGIN
                    INSERT INTO message_search(message_search,rowid,content) VALUES('delete',old.rowid,old.content);
                    INSERT INTO message_search(rowid,content) VALUES(new.rowid,new.content);
                END;
                CREATE TABLE IF NOT EXISTS runs (
                    id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
                    user_message_id TEXT NOT NULL REFERENCES messages(id),
                    assistant_message_id TEXT NOT NULL REFERENCES messages(id),
                    status TEXT NOT NULL, model TEXT NOT NULL, effort TEXT NOT NULL,
                    created_at TEXT NOT NULL, finished_at TEXT, failure TEXT
                );
                CREATE UNIQUE INDEX IF NOT EXISTS runs_active_conversation ON runs(conversation_id)
                    WHERE status IN ('queued','running','stopping');
                CREATE TABLE IF NOT EXISTS events (
                    seq INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT NOT NULL REFERENCES conversations(id),
                    run_id TEXT, layer TEXT NOT NULL, kind TEXT NOT NULL, payload TEXT NOT NULL,
                    created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS events_replay ON events(conversation_id,seq);
                CREATE TABLE IF NOT EXISTS provider_diagnostics (
                    id TEXT PRIMARY KEY, run_id TEXT NOT NULL, message_id TEXT NOT NULL,
                    source_seq INTEGER UNIQUE, raw_text TEXT NOT NULL, created_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS memories (
                    id TEXT PRIMARY KEY, content TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL
                );
                CREATE TABLE IF NOT EXISTS settings (key TEXT PRIMARY KEY, value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS artifacts (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, size INTEGER NOT NULL, mime TEXT NOT NULL,
                    sha256 TEXT NOT NULL, created_at TEXT NOT NULL
                );
                CREATE INDEX IF NOT EXISTS artifacts_hash ON artifacts(sha256);
                CREATE TABLE IF NOT EXISTS uploads (
                    id TEXT PRIMARY KEY, name TEXT NOT NULL, size INTEGER NOT NULL,
                    sha256 TEXT NOT NULL, mime TEXT NOT NULL, offset INTEGER NOT NULL DEFAULT 0,
                    artifact_id TEXT, created_at TEXT NOT NULL
                );
            """)
            for key, value in DEFAULT_SETTINGS.items():
                db.execute("INSERT OR IGNORE INTO settings VALUES(?,?)", (key, encoded(value)))
        diagnostics = self.all("SELECT * FROM provider_diagnostics WHERE source_seq IS NOT NULL ORDER BY source_seq")
        self._diagnostic_events = {row["source_seq"]: row["id"] for row in diagnostics}
        self._message_diagnostics: dict[str, list[str]] = {}
        for row in diagnostics:
            self._message_diagnostics.setdefault(row["message_id"], []).append(row["raw_text"])

    @contextmanager
    def connect(self) -> Iterator[sqlite3.Connection]:
        with self.lock:
            db = sqlite3.connect(self.path, timeout=30)
            db.row_factory = sqlite3.Row
            db.execute("PRAGMA foreign_keys=ON")
            db.execute("PRAGMA busy_timeout=30000")
            try:
                with db:
                    yield db
                if db.total_changes and self.on_commit:
                    self.on_commit()
            finally:
                db.close()

    def one(self, query: str, parameters: tuple = ()) -> dict | None:
        with self.connect() as db:
            row = db.execute(query, parameters).fetchone()
        return dict(row) if row else None

    def all(self, query: str, parameters: tuple = ()) -> list[dict]:
        with self.connect() as db:
            return [dict(row) for row in db.execute(query, parameters).fetchall()]

    @staticmethod
    def message(row: dict | sqlite3.Row) -> dict:
        result = dict(row)
        result["attachments"] = json.loads(result["attachments"])
        result.pop("client_id", None)
        return result

    @staticmethod
    def conversation(row: dict) -> dict:
        result = dict(row)
        result["group"] = result.pop("group_name")
        result["pinned"] = bool(result["pinned"])
        result["archived"] = bool(result["archived"])
        result.pop("provider_id", None)
        return result

    @staticmethod
    def event(db: sqlite3.Connection, conversation_id: str, run_id: str | None,
              layer: str, kind: str, payload: dict) -> int:
        return db.execute(
            "INSERT INTO events(conversation_id,run_id,layer,kind,payload,created_at) VALUES(?,?,?,?,?,?)",
            (conversation_id, run_id, layer, kind, encoded(payload), now()),
        ).lastrowid

    def emit(self, run: dict, layer: str, kind: str, payload: dict) -> None:
        with self.connect() as db:
            self.event(db, run["conversation_id"], run["id"], layer, kind, payload)

    def delta(self, run: dict, text: str) -> bool:
        if not text:
            return True
        with self.connect() as db:
            state = db.execute("SELECT status FROM runs WHERE id=?", (run["id"],)).fetchone()
            if not state or state["status"] not in ("running", "queued"):
                return False
            db.execute("UPDATE messages SET content=content||? WHERE id=?", (text, run["assistant_message_id"]))
            db.execute("UPDATE conversations SET updated_at=? WHERE id=?", (now(), run["conversation_id"]))
            self.event(db, run["conversation_id"], run["id"], "L3", "reply_delta",
                       {"message_id": run["assistant_message_id"], "text": text})
        return True

    def finish(self, run: dict, status: str, failure: str | None = None) -> None:
        with self.connect() as db:
            existing = db.execute("SELECT status FROM runs WHERE id=?", (run["id"],)).fetchone()
            if not existing or existing["status"] in ("completed", "failed", "stopped", "interrupted"):
                return
            db.execute("UPDATE runs SET status=?,finished_at=?,failure=? WHERE id=?",
                       (status, now(), failure, run["id"]))
            db.execute("UPDATE messages SET status=? WHERE id=?", (status, run["assistant_message_id"]))
            kind = {"completed": "run_finished", "stopped": "run_stopped"}.get(status, "run_failed")
            payload = {"message_id": run["assistant_message_id"], "status": status}
            if failure:
                payload["message"] = failure
            self.event(db, run["conversation_id"], run["id"], "system", kind, payload)

    def recover(self) -> int:
        runs = self.all("SELECT * FROM runs WHERE status IN ('queued','running','stopping')")
        for run in runs:
            self.finish(run, "interrupted", "琴房刚刚重新亮灯，先前的文字都在。请从这里继续。")
        return len(runs)

    def settings(self) -> dict:
        return {row["key"]: json.loads(row["value"]) for row in self.all("SELECT * FROM settings")}

    def public_content(self, message_id: str | None, content: str) -> str:
        for raw_text in self._message_diagnostics.get(message_id, []):
            if content.startswith(raw_text):
                content = content[len(raw_text):]
        return content

    def public_message(self, row: dict | sqlite3.Row) -> dict:
        message = self.message(row)
        visible = self.public_content(message["id"], message["content"])
        if visible != message["content"]:
            message["content"] = visible
            message["provider_diagnostics_available"] = True
        return message

    def public_event(self, row: dict) -> dict:
        from .diagnostics import FRIENDLY_RETRY
        event = dict(row)
        if isinstance(event["payload"], str):
            event["payload"] = json.loads(event["payload"])
        diagnostic = self._diagnostic_events.get(event["seq"])
        if diagnostic:
            event.update(layer="L2", kind="provider_notice", payload={"summary": FRIENDLY_RETRY, "diagnostic_id": diagnostic})
        return event

    def provider_diagnostic(self, run: dict, raw_text: str, source_seq: int | None = None) -> str:
        from .diagnostics import FRIENDLY_RETRY
        ident = uid()
        with self.connect() as db:
            if source_seq is not None:
                source = db.execute("SELECT payload,kind FROM events WHERE seq=? AND run_id=?", (source_seq, run["id"])).fetchone()
                if not source or source["kind"] != "reply_delta" or json.loads(source["payload"]).get("text") != raw_text:
                    raise ValueError("The historical event does not match the independently confirmed provider diagnostic.")
                existing = db.execute("SELECT id FROM provider_diagnostics WHERE source_seq=?", (source_seq,)).fetchone()
                if existing:
                    return existing[0]
            db.execute("INSERT INTO provider_diagnostics VALUES(?,?,?,?,?,?)", (ident, run["id"], run["assistant_message_id"], source_seq, raw_text, now()))
            if source_seq is None:
                self.event(db, run["conversation_id"], run["id"], "L2", "provider_notice", {"summary": FRIENDLY_RETRY, "diagnostic_id": ident})
        if source_seq is not None:
            self._diagnostic_events[source_seq] = ident
            self._message_diagnostics.setdefault(run["assistant_message_id"], []).append(raw_text)
        return ident
