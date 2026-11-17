"""Quoted side conversations and persisted, blind two-model comparisons."""
from __future__ import annotations

import hashlib
import json
import secrets
import re
from html.parser import HTMLParser
from typing import Awaitable, Callable, Literal

from fastapi import APIRouter, Depends, HTTPException, Request
from markdown_it import MarkdownIt
from pydantic import BaseModel, ConfigDict, Field

from .store import Store, encoded, now, uid


class Input(BaseModel):
    model_config = ConfigDict(extra='forbid')


class ThreadInput(Input):
    message_id: str
    quote: str = Field(min_length=1, max_length=12000)
    client_id: str = Field(min_length=1, max_length=128)
    title: str | None = Field(default=None, min_length=1, max_length=160)
    source_sha256: str | None = Field(default=None, pattern=r'^[0-9a-f]{64}$')


class Choice(Input):
    model: str = Field(max_length=160)
    effort: Literal['low', 'medium', 'high', 'xhigh', 'max'] = 'medium'


class ArenaInput(Input):
    content: str = Field(default='', max_length=500000)
    choices: list[Choice] = Field(min_length=2, max_length=2)
    client_id: str = Field(min_length=1, max_length=128)
    attachments: list[str] = Field(default_factory=list, max_length=20)


class Vote(Input):
    choice: Literal['A', 'B', 'tie']


def fingerprint(value: dict) -> str:
    return hashlib.sha256(json.dumps(value, ensure_ascii=False, sort_keys=True).encode()).hexdigest()


class _SelectionText(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts, self.hidden = [], 0

    def handle_starttag(self, tag, attrs):
        if tag in {'script', 'style'}: self.hidden += 1
        elif not self.hidden and tag in {'p','div','br','li','tr','h1','h2','h3','h4','h5','h6','pre'}: self.parts.append('\n')
        elif not self.hidden and tag == 'img': self.parts.append(dict(attrs).get('alt',''))

    def handle_endtag(self, tag):
        if tag in {'script','style'}: self.hidden = max(0,self.hidden-1)
        elif not self.hidden and tag in {'p','div','li','tr','h1','h2','h3','h4','h5','h6','pre'}: self.parts.append('\n')
        elif not self.hidden and tag in {'td','th'}: self.parts.append('\t')

    def handle_data(self, text):
        if not self.hidden: self.parts.append(text)


def selection_text(content: str) -> str:
    parser = _SelectionText()
    parser.feed(MarkdownIt('commonmark', {'html':True}).enable('table').render(content))
    return re.sub(r'\n{3,}', '\n\n', ''.join(parser.parts)).strip()


def normalized_quote(value: str) -> str:
    return re.sub(r'\s+', ' ', value).strip()


class Branches:
    def __init__(self, store: Store, runner, context):
        self.store, self.runner, self.context = store, runner, context
        with store.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS conversation_threads (
                  id TEXT PRIMARY KEY REFERENCES conversations(id), parent_id TEXT NOT NULL REFERENCES conversations(id),
                  source_message_id TEXT NOT NULL REFERENCES messages(id), quote TEXT NOT NULL,
                  source_sha256 TEXT NOT NULL, client_id TEXT NOT NULL, request_hash TEXT NOT NULL,
                  context_snapshot TEXT NOT NULL, created_at TEXT NOT NULL, UNIQUE(parent_id,client_id));
                CREATE TABLE IF NOT EXISTS arenas (
                  id TEXT PRIMARY KEY, parent_id TEXT NOT NULL REFERENCES conversations(id),
                  client_id TEXT NOT NULL, request_hash TEXT NOT NULL, content TEXT NOT NULL,
                  attachments TEXT NOT NULL, context_snapshot TEXT NOT NULL, created_at TEXT NOT NULL,
                  revealed INTEGER NOT NULL DEFAULT 0, choice TEXT, UNIQUE(parent_id,client_id));
                CREATE TABLE IF NOT EXISTS arena_sides (
                  arena_id TEXT NOT NULL REFERENCES arenas(id), side TEXT NOT NULL,
                  conversation_id TEXT NOT NULL UNIQUE REFERENCES conversations(id),
                  model TEXT NOT NULL, effort TEXT NOT NULL, run_id TEXT REFERENCES runs(id),
                  PRIMARY KEY(arena_id,side));
                CREATE TABLE IF NOT EXISTS branch_artifacts (
                  conversation_id TEXT NOT NULL REFERENCES conversations(id),
                  artifact_id TEXT NOT NULL REFERENCES artifacts(id),PRIMARY KEY(conversation_id,artifact_id));
            ''')
            if 'stopped_at' not in {row['name'] for row in db.execute('PRAGMA table_info(arenas)')}:
                db.execute('ALTER TABLE arenas ADD COLUMN stopped_at TEXT')

    def selection(self, message_id: str) -> dict:
        row = self.store.one('SELECT * FROM messages WHERE id=?', (message_id,))
        if not row: raise HTTPException(404,'所引用的那句话暂时没有找到。')
        content = self.store.public_message(row)['content']
        if len(content)>500000: raise HTTPException(413,'这一页较长，请先在原文中缩小阅读范围。')
        return {'message_id':message_id,'conversation_id':row['conversation_id'],'text':selection_text(content),
                'source_sha256':hashlib.sha256(content.encode('utf-8')).hexdigest(),'status':row['status']}

    def _share(self, db, child: str, snapshot: dict, source: dict | None = None) -> None:
        ids = {file['id'] for message in snapshot['history'] for file in message['attachments']}
        ids.update(pin['target_id'] for pin in snapshot['anchors_and_tasks']['pinned_anchors'] if pin['kind']=='artifact')
        if source: ids.update(file['id'] for file in source['attachments'])
        for ident in ids:
            db.execute('INSERT OR IGNORE INTO branch_artifacts SELECT ?,id FROM artifacts WHERE id=?',(child,ident))

    def _inherit_tone(self, db, parent: str, child: str) -> None:
        db.execute('INSERT INTO conversation_tones VALUES(?,?)',(child,self.context.tone_id(parent)))

    def _parent(self, ident: str) -> dict:
        parent = self.store.one('SELECT * FROM conversations WHERE id=?', (ident,))
        if not parent:
            raise HTTPException(404, '原来的乐章暂时没有找到。')
        return parent

    def _snapshot(self, parent_id: str) -> dict:
        history, budget = [], 60000
        rows = self.store.all('SELECT * FROM messages WHERE conversation_id=? ORDER BY created_at DESC,rowid DESC LIMIT 60', (parent_id,))
        for row in rows:
            public = self.store.public_message(row)
            if budget <= 0:
                break
            text = public['content'][:min(12000, budget)]
            history.append({'message_id': row['id'], 'role': row['role'], 'content': text,
                            'excerpt_only': len(text) != len(public['content']), 'attachments': public['attachments']})
            budget -= len(text)
        return {'parent_id': parent_id, 'history': list(reversed(history)),
                'anchors_and_tasks': self.context.model_context(parent_id),
                'personality': self.store.settings()['personality'],
                'memories': self.store.all('SELECT id,content FROM memories ORDER BY updated_at DESC LIMIT 100')}

    def context_for(self, conversation_id: str) -> dict | None:
        thread = self.store.one('SELECT * FROM conversation_threads WHERE id=?', (conversation_id,))
        if thread:
            return {'kind': 'thread', 'source_message_id': thread['source_message_id'],
                    'selected_rendered_quote': thread['quote'], 'context': json.loads(thread['context_snapshot'])}
        side = self.store.one('SELECT a.context_snapshot FROM arena_sides s JOIN arenas a ON a.id=s.arena_id WHERE s.conversation_id=?', (conversation_id,))
        return {'kind': 'arena', 'context': json.loads(side['context_snapshot'])} if side else None

    def view(self, ident: str) -> dict:
        with self.store.connect() as db:
            db.execute('BEGIN')
            row = db.execute('SELECT * FROM arenas WHERE id=?', (ident,)).fetchone()
            if not row: raise HTTPException(404, '这一组对照暂时没有找到。')
            row=dict(row)
            result = []
            for side in db.execute('SELECT * FROM arena_sides WHERE arena_id=? ORDER BY side',(ident,)).fetchall():
                run = db.execute('SELECT status,user_message_id,assistant_message_id FROM runs WHERE id=?',(side['run_id'],)).fetchone() if side['run_id'] else None
                # A comparison keeps its original answer. Continuing that side
                # later must not replace the answer that was voted on.
                messages = db.execute('SELECT * FROM messages WHERE id=?',(run['assistant_message_id'],)).fetchall() if run else []
                cursor = db.execute('SELECT COALESCE(MAX(seq),0) FROM events WHERE conversation_id=?',(side['conversation_id'],)).fetchone()[0]
                item = {'side':side['side'],'conversation_id':side['conversation_id'],'run_id':side['run_id'],'cursor':cursor,
                        'question_message_id':run['user_message_id'] if run else '',
                        'question_created_at':db.execute('SELECT created_at FROM messages WHERE id=?',(run['user_message_id'],)).fetchone()[0] if run else '',
                        'status':run['status'] if run else 'not_started' if row['stopped_at'] else 'preparing',
                        'messages':[self.store.public_message(message) for message in messages]}
                if row['revealed']: item.update(model=side['model'],effort=side['effort'])
                result.append(item)
            files=[dict(file) for ident in json.loads(row['attachments'])
                   if (file:=db.execute('SELECT * FROM artifacts WHERE id=?',(ident,)).fetchone())]
        for file in files: file['url']='/api/artifacts/'+file['id']+'/content'
        return {'id': ident, 'parent_id': row['parent_id'], 'content': row['content'], 'created_at': row['created_at'],
                'client_id':row['client_id'],'stopped_at':row['stopped_at'],
                'attachments':files,
                'revealed': bool(row['revealed']), 'choice': row['choice'], 'sides': result}

    def router(self, authenticate, send: Callable[[str, dict, Request], Awaitable[dict]]) -> APIRouter:
        router = APIRouter(prefix='/api', dependencies=[Depends(authenticate)])

        @router.get('/messages/{ident}/selection')
        async def selection(ident: str):
            return self.selection(ident)

        @router.get('/conversations/{ident}/threads')
        async def threads(ident: str):
            self._parent(ident)
            return {'threads': self.store.all('SELECT t.id,t.parent_id,t.source_message_id,t.quote,t.client_id,t.created_at,c.title FROM conversation_threads t JOIN conversations c ON c.id=t.id WHERE t.parent_id=? ORDER BY t.created_at', (ident,))}

        @router.get('/conversations/{ident}/origin')
        async def origin(ident: str):
            self._parent(ident)
            return {'thread': self.store.one('SELECT id,parent_id,source_message_id,quote FROM conversation_threads WHERE id=?', (ident,)),
                    'arena': self.store.one('SELECT s.arena_id,s.side,a.parent_id FROM arena_sides s JOIN arenas a ON a.id=s.arena_id WHERE s.conversation_id=?', (ident,))}

        @router.post('/conversations/{ident}/threads')
        async def create_thread(ident: str, body: ThreadInput):
            parent = self._parent(ident)
            digest = fingerprint(body.model_dump())
            existing = self.store.one('SELECT * FROM conversation_threads WHERE parent_id=? AND client_id=?', (ident, body.client_id))
            if existing:
                if existing['request_hash'] != digest:
                    raise HTTPException(409, '这枚附页编号已经用过，请重新打开一页。')
                return self.store.conversation(self.store.one('SELECT * FROM conversations WHERE id=?', (existing['id'],)))
            source = self.store.one('SELECT * FROM messages WHERE id=? AND conversation_id=?', (body.message_id, ident))
            if not source: raise HTTPException(404, '所引用的那句话不在当前乐章里。')
            selected = self.selection(body.message_id)
            if body.source_sha256 and body.source_sha256!=selected['source_sha256']:
                raise HTTPException(409,'这段话又添了内容，请重新选一下。')
            if not normalized_quote(body.quote) or normalized_quote(body.quote) not in normalized_quote(selected['text']):
                raise HTTPException(422,'请从这段回复的实际文字中选一句。')
            snapshot, child, stamp = self._snapshot(ident), uid(), now()
            with self.store.connect() as db:
                db.execute('BEGIN IMMEDIATE')
                existing=db.execute('SELECT id,request_hash FROM conversation_threads WHERE parent_id=? AND client_id=?',(ident,body.client_id)).fetchone()
                if existing:
                    if existing['request_hash']!=digest: raise HTTPException(409,'这枚附页编号已经用过，请重新打开一页。')
                    return self.store.conversation(dict(db.execute('SELECT * FROM conversations WHERE id=?',(existing['id'],)).fetchone()))
                db.execute('INSERT INTO conversations VALUES(?,?,?,0,0,?,?,NULL)',
                           (child, body.title or parent['title'][:150] + ' · 附页', parent['group_name'], stamp, stamp))
                db.execute('INSERT INTO conversation_threads VALUES(?,?,?,?,?,?,?,?,?)',
                           (child, ident, body.message_id, body.quote, selected['source_sha256'],
                            body.client_id, digest, encoded(snapshot), stamp))
                self._share(db,child,snapshot,self.store.public_message(source))
                self._inherit_tone(db,ident,child)
            return self.store.conversation(self.store.one('SELECT * FROM conversations WHERE id=?', (child,)))

        @router.get('/conversations/{ident}/arenas')
        async def arenas(ident: str):
            self._parent(ident)
            return {'arenas': self.store.all('SELECT id,parent_id,client_id,content,created_at,revealed,choice FROM arenas WHERE parent_id=? ORDER BY created_at DESC', (ident,))}

        async def ensure_runs(row: dict, request: Request) -> dict:
            if row['stopped_at']: return self.view(row['id'])
            for side in self.store.all('SELECT * FROM arena_sides WHERE arena_id=? ORDER BY side',(row['id'],)):
                current=self.store.one('SELECT stopped_at FROM arenas WHERE id=?',(row['id'],))
                if current['stopped_at']: break
                if side['run_id'] is None:
                    response=await send(side['conversation_id'],{'content':row['content'],
                        'client_id':row['id']+'-'+side['side'],'model':side['model'],'effort':side['effort'],
                        'attachments':json.loads(row['attachments']),'tone_id':self.context.tone_id(side['conversation_id'])},request)
                    with self.store.connect() as db:
                        db.execute('UPDATE arena_sides SET run_id=? WHERE arena_id=? AND side=?',
                                   (response['run_id'],row['id'],side['side']))
            return self.view(row['id'])

        @router.post('/conversations/{ident}/arenas')
        async def compare(ident: str, body: ArenaInput, request: Request):
            parent = self._parent(ident)
            if not body.content.strip() and not body.attachments:
                raise HTTPException(422,'先留下一道题，或带一份原件来吧。')
            if len({(item.model,item.effort) for item in body.choices})!=2:
                raise HTTPException(422,'选两种不同的模型或思考档位，再听听它们的回答。')
            catalog = {model['id']: model for model in self.runner.models()}
            for choice in body.choices:
                if choice.model not in catalog or (choice.model != 'default' and choice.effort not in catalog[choice.model]['efforts']):
                    raise HTTPException(422, '这一组模型或档位还没有接好，请重新选择。')
            for artifact in body.attachments:
                if not self.store.one('SELECT id FROM artifacts WHERE id=?', (artifact,)):
                    raise HTTPException(404, '有一份附件还没有收齐。')
            digest = fingerprint(body.model_dump())
            row = self.store.one('SELECT * FROM arenas WHERE parent_id=? AND client_id=?', (ident, body.client_id))
            if row and row['request_hash'] != digest:
                raise HTTPException(409, '这枚对照编号已经用过，请重新开始一组。')
            if not row:
                arena_id, stamp, snapshot = uid(), now(), self._snapshot(ident)
                choices = list(body.choices)
                if secrets.randbelow(2):
                    choices.reverse()
                with self.store.connect() as db:
                    db.execute('BEGIN IMMEDIATE')
                    existing=db.execute('SELECT * FROM arenas WHERE parent_id=? AND client_id=?',(ident,body.client_id)).fetchone()
                    if existing:
                        if existing['request_hash']!=digest: raise HTTPException(409,'这枚对照编号已经用过，请重新开始一组。')
                        row=dict(existing)
                    else:
                        db.execute('INSERT INTO arenas(id,parent_id,client_id,request_hash,content,attachments,context_snapshot,created_at,revealed,choice) VALUES(?,?,?,?,?,?,?,?,0,NULL)',
                               (arena_id, ident, body.client_id, digest, body.content, encoded(body.attachments), encoded(snapshot), stamp))
                        for label, choice in zip(['A', 'B'], choices):
                            child = uid()
                            db.execute('INSERT INTO conversations VALUES(?,?,?,0,0,?,?,NULL)',
                                   (child, parent['title'][:140] + ' · 对照 ' + label, parent['group_name'], stamp, stamp))
                            db.execute('INSERT INTO arena_sides VALUES(?,?,?,?,?,NULL)', (arena_id, label, child, choice.model, choice.effort))
                            self._share(db,child,snapshot)
                            self._inherit_tone(db,ident,child)
                if row is None: row = self.store.one('SELECT * FROM arenas WHERE id=?', (arena_id,))
            return await ensure_runs(row,request)

        @router.post('/arenas/{ident}/resume')
        async def resume(ident: str, request: Request):
            self.view(ident)
            return await ensure_runs(self.store.one('SELECT * FROM arenas WHERE id=?',(ident,)),request)

        @router.get('/arenas/{ident}')
        async def view_arena(ident: str):
            return self.view(ident)

        @router.post('/arenas/{ident}/reveal')
        async def reveal(ident: str):
            self.view(ident)
            with self.store.connect() as db:
                db.execute('UPDATE arenas SET revealed=1 WHERE id=?', (ident,))
            return self.view(ident)

        @router.post('/arenas/{ident}/vote')
        async def vote(ident: str, body: Vote):
            current = self.view(ident)
            if any(side['status'] in {'preparing', 'queued', 'running', 'stopping'} for side in current['sides']):
                raise HTTPException(409, '两段演奏还没结束；也可以先停下，再做选择。')
            with self.store.connect() as db:
                db.execute('UPDATE arenas SET choice=?,revealed=1 WHERE id=?', (body.choice, ident))
            return self.view(ident)

        @router.post('/arenas/{ident}/stop')
        async def stop(ident: str):
            current = self.view(ident)
            with self.store.connect() as db: db.execute('UPDATE arenas SET stopped_at=COALESCE(stopped_at,?) WHERE id=?',(now(),ident))
            for side in current['sides']:
                if side['run_id']:
                    run = self.store.one('SELECT * FROM runs WHERE id=?', (side['run_id'],))
                    if run and run['status'] in {'queued','running','stopping'}:
                        await self.runner.stop(run)
            return self.view(ident)

        return router
