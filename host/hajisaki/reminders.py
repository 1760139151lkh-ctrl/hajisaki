"""Durable, opt-in reminders. Delivery means saved in the local inbox, not a push receipt."""
from __future__ import annotations

import asyncio
from datetime import datetime, timedelta, timezone
from typing import Literal
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from .store import Store, now, uid


class ReminderInput(BaseModel):
    model_config = ConfigDict(extra='forbid')
    content: str = Field(min_length=1, max_length=2000)
    due_at: datetime
    timezone: str = Field(default='America/Los_Angeles', max_length=100)
    repeat: Literal['once', 'daily', 'weekly'] = 'once'
    conversation_id: str | None = None


class ReminderUpdate(BaseModel):
    model_config = ConfigDict(extra='forbid')
    content: str | None = Field(default=None, min_length=1, max_length=2000)
    enabled: bool | None = None
    due_at: datetime | None = None
    timezone: str | None = Field(default=None, max_length=100)
    repeat: Literal['once', 'daily', 'weekly'] | None = None


def utc(value: datetime) -> str:
    if value.tzinfo is None or value.utcoffset() is None:
        raise HTTPException(422, '约定的时间需要带上时区，请重新选择。')
    return value.astimezone(timezone.utc).isoformat()


def zone(name: str) -> ZoneInfo:
    try:
        return ZoneInfo(name)
    except (ZoneInfoNotFoundError, ValueError):
        raise HTTPException(422, '还没有认出这个时区，请选择有效的城市时区。')


def next_occurrence(due: datetime, current: datetime, repeat: str, name: str) -> str | None:
    if repeat == 'once':
        return None
    tz = zone(name)
    local, today = due.astimezone(tz), current.astimezone(tz)
    step = 1 if repeat == 'daily' else 7
    days = max(step, ((today.date() - local.date()).days // step) * step)
    candidate = local + timedelta(days=days)
    if candidate <= today:
        candidate += timedelta(days=step)
    # A nonexistent DST wall time moves forward to its valid UTC round trip.
    return candidate.astimezone(timezone.utc).isoformat()


class Reminders:
    def __init__(self, store: Store):
        self.store = store
        self.task: asyncio.Task | None = None
        self.last_tick: str | None = None
        self.last_error = False
        with store.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS reminders (
                  id TEXT PRIMARY KEY, content TEXT NOT NULL, due_at TEXT NOT NULL,
                  timezone TEXT NOT NULL, repeat TEXT NOT NULL, enabled INTEGER NOT NULL,
                  conversation_id TEXT REFERENCES conversations(id), created_at TEXT NOT NULL,
                  updated_at TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS reminders_due ON reminders(enabled,due_at);
                CREATE TABLE IF NOT EXISTS reminder_deliveries (
                  id TEXT PRIMARY KEY, reminder_id TEXT NOT NULL REFERENCES reminders(id),
                  due_at TEXT NOT NULL, delivered_at TEXT NOT NULL, content TEXT NOT NULL,
                  read_at TEXT, conversation_id TEXT REFERENCES conversations(id),
                  UNIQUE(reminder_id,due_at));
            ''')

    def status(self) -> dict:
        return {'running': bool(self.task and not self.task.done()), 'last_tick': self.last_tick,
                'attention_needed': self.last_error, 'delivery': 'durable_local_inbox',
                'remote_push_verified': False}

    @staticmethod
    def public(row: dict) -> dict:
        return {**row, 'enabled': bool(row['enabled'])}

    def deliver_due(self) -> int:
        current, count = datetime.now(timezone.utc), 0
        stamp = current.isoformat()
        nickname = ' '.join(str(self.store.settings().get('nickname') or '').split())
        with self.store.connect() as db:
            rows = db.execute('SELECT * FROM reminders WHERE enabled=1 AND due_at<=? ORDER BY due_at LIMIT 100', (stamp,)).fetchall()
            for row in rows:
                reminder = dict(row)
                delivery_id = uid()
                result = db.execute('INSERT OR IGNORE INTO reminder_deliveries VALUES(?,?,?,?,?,NULL,?)',
                    (delivery_id, row['id'], row['due_at'], stamp, row['content'], row['conversation_id']))
                if result.rowcount:
                    count += 1
                    if row['conversation_id']:
                        message_id = uid()
                        # She holds up the promise you wrote, in her own words around it.
                        message = ((nickname + '，' if nickname else '') + '约好的时间到了。\n\n> '
                                   + row['content'].strip().replace('\n', '\n> ') + '\n\n我替你记着呢。')
                        db.execute('INSERT INTO messages VALUES(?,?,?,?,?,?,?,NULL)',
                            (message_id, row['conversation_id'], 'assistant', message, 'completed', stamp, '[]'))
                        db.execute('UPDATE conversations SET updated_at=? WHERE id=?', (stamp, row['conversation_id']))
                        self.store.event(db, row['conversation_id'], None, 'L3', 'reminder',
                            {'message_id': message_id, 'delivery_id': delivery_id, 'text': message,
                             'scheduled_for': row['due_at']})
                following = next_occurrence(datetime.fromisoformat(row['due_at']), current,
                                             reminder['repeat'], row['timezone'])
                db.execute('UPDATE reminders SET due_at=?,enabled=?,updated_at=? WHERE id=?',
                           (following or row['due_at'], int(following is not None), stamp, row['id']))
        self.last_tick, self.last_error = stamp, False
        return count

    async def _run(self) -> None:
        while True:
            try:
                await asyncio.to_thread(self.deliver_due)
            except asyncio.CancelledError:
                raise
            except Exception:
                self.last_error = True
            await asyncio.sleep(5)

    def start(self) -> None:
        if self.task is None or self.task.done():
            self.task = asyncio.create_task(self._run(), name='hajisaki-reminders')

    async def close(self) -> None:
        if self.task:
            self.task.cancel()
            await asyncio.gather(self.task, return_exceptions=True)

    def router(self, authenticate) -> APIRouter:
        router = APIRouter(prefix='/api', dependencies=[Depends(authenticate)])

        @router.get('/reminders')
        async def listing():
            return {'reminders': [self.public(row) for row in self.store.all('SELECT r.*,(SELECT max(delivered_at) FROM reminder_deliveries d WHERE d.reminder_id=r.id) AS last_delivered_at FROM reminders r ORDER BY enabled DESC,due_at')],
                    'scheduler': self.status()}

        @router.post('/reminders')
        async def create(body: ReminderInput):
            due = utc(body.due_at)
            zone(body.timezone)
            if body.conversation_id and not self.store.one('SELECT id FROM conversations WHERE id=?', (body.conversation_id,)):
                raise HTTPException(404, '这条约定对应的乐章还没有找到。')
            ident, stamp = uid(), now()
            with self.store.connect() as db:
                db.execute('INSERT INTO reminders VALUES(?,?,?,?,?,1,?,?,?)',
                           (ident, body.content, due, body.timezone, body.repeat, body.conversation_id, stamp, stamp))
            return self.public(self.store.one('SELECT * FROM reminders WHERE id=?', (ident,)))

        @router.post('/reminders/{ident}/update')
        @router.patch('/reminders/{ident}')
        async def update(ident: str, body: ReminderUpdate):
            original = self.store.one('SELECT * FROM reminders WHERE id=?', (ident,))
            if not original:
                raise HTTPException(404, '这条约定暂时没有找到。')
            changes = body.model_dump(exclude_none=True)
            if 'due_at' in changes:
                changes['due_at'] = utc(changes['due_at'])
            if 'timezone' in changes:
                zone(changes['timezone'])
            if (changes.get('enabled') and changes.get('repeat', original['repeat']) == 'once'
                    and 'due_at' not in changes
                    and self.store.one('SELECT id FROM reminder_deliveries WHERE reminder_id=? AND due_at=?', (ident, original['due_at']))):
                raise HTTPException(409, '这条约定已经送达，请选一个新的时间再约。')
            if changes:
                changes['updated_at'] = now()
                with self.store.connect() as db:
                    db.execute('UPDATE reminders SET ' + ','.join(f'{key}=?' for key in changes) + ' WHERE id=?',
                               (*changes.values(), ident))
            return self.public(self.store.one('SELECT * FROM reminders WHERE id=?', (ident,)))

        @router.get('/inbox')
        async def inbox(after: str = '', unread: bool = False):
            criteria = 'delivered_at>?'
            if unread:
                criteria += ' AND read_at IS NULL'
            return {'items': self.store.all('SELECT * FROM reminder_deliveries WHERE ' + criteria + ' ORDER BY delivered_at DESC LIMIT 200', (after,))}

        @router.post('/inbox/{ident}/read')
        async def read(ident: str):
            with self.store.connect() as db:
                result = db.execute('UPDATE reminder_deliveries SET read_at=? WHERE id=?', (now(), ident))
                if not result.rowcount:
                    raise HTTPException(404, '这封信暂时没有找到。')
            return {'status': 'read'}

        return router
