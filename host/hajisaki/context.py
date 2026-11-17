"""Conversation anchors and task state, stored separately from the original transcript."""
from __future__ import annotations

import re
import json
from pathlib import Path
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from .store import Store, encoded, now, uid
from .composer import ToneId, catalog, tone


class PinInput(BaseModel):
    model_config = ConfigDict(extra='forbid')
    kind: Literal['message', 'artifact', 'text']
    target_id: str | None = Field(default=None, max_length=80)
    content: str = Field(default='', max_length=4000)


class TaskUpdate(BaseModel):
    model_config = ConfigDict(extra='forbid')
    checked: bool


class ToneUpdate(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    tone_id: ToneId


def task_items(content: str) -> list[dict]:
    from markdown_it import MarkdownIt
    items = []
    tokens = MarkdownIt('commonmark').parse(content)
    for index, token in enumerate(tokens):
        if (token.type == 'inline' and index >= 2
                and tokens[index - 1].type == 'paragraph_open'
                and tokens[index - 2].type == 'list_item_open'):
            match = re.match(r'^\[([ xX])\]\s+(.+)', token.content, re.S)
            if match:
                item = {'index': len(items), 'text': match[2], 'initial_checked': match[1].lower() == 'x'}
                if (isinstance(token.map, (list, tuple)) and len(token.map) == 2
                        and all(type(value) is int for value in token.map)
                        and 0 <= token.map[0] < token.map[1]):
                    item.update(source_start_line=token.map[0], source_end_line=token.map[1])
                items.append(item)
    return items


class Context:
    def __init__(self, store: Store, data_dir: Path):
        self.store, self.data_dir = store, data_dir
        with store.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS context_pins (
                  id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id),
                  kind TEXT NOT NULL, target_id TEXT, content TEXT NOT NULL, created_at TEXT NOT NULL);
                CREATE INDEX IF NOT EXISTS pins_conversation ON context_pins(conversation_id);
                CREATE TABLE IF NOT EXISTS message_tasks (
                  message_id TEXT NOT NULL REFERENCES messages(id), item_index INTEGER NOT NULL,
                  checked INTEGER NOT NULL, updated_at TEXT NOT NULL,
                  PRIMARY KEY(message_id,item_index));
                CREATE TABLE IF NOT EXISTS conversation_tones (
                  conversation_id TEXT PRIMARY KEY REFERENCES conversations(id),tone_id TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS context_compactions (
                  id TEXT PRIMARY KEY,conversation_id TEXT NOT NULL REFERENCES conversations(id),
                  run_id TEXT NOT NULL UNIQUE REFERENCES runs(id),operation_id TEXT NOT NULL,
                  previous_provider_id TEXT,cutoff_message_id TEXT NOT NULL,
                  archive_id TEXT,summary TEXT NOT NULL DEFAULT '',activated_at TEXT,created_at TEXT NOT NULL,
                  UNIQUE(conversation_id,operation_id));
                CREATE INDEX IF NOT EXISTS compactions_conversation ON context_compactions(conversation_id,created_at);
                CREATE TABLE IF NOT EXISTS conversation_contexts (
                  conversation_id TEXT PRIMARY KEY REFERENCES conversations(id),
                  compaction_id TEXT NOT NULL REFERENCES context_compactions(id));
            ''')
            columns = {row['name'] for row in db.execute('PRAGMA table_info(context_compactions)')}
            for name,definition in (('method',"TEXT NOT NULL DEFAULT 'summary'"),('tokens_before','INTEGER'),('tokens_after','INTEGER'),('verification_run_id','TEXT REFERENCES runs(id)')):
                if name not in columns:db.execute('ALTER TABLE context_compactions ADD COLUMN '+name+' '+definition)

    def tone_id(self, conversation_id: str) -> str:
        row = self.store.one('SELECT tone_id FROM conversation_tones WHERE conversation_id=?', (conversation_id,))
        return tone(row['tone_id'] if row else 'inherit')['id']

    def compaction_for_run(self, run_id: str) -> dict | None:
        return self.store.one('SELECT * FROM context_compactions WHERE run_id=?', (run_id,))

    def run_tone_id(self, run_id: str) -> str | None:
        row = self.store.one("SELECT payload FROM events WHERE run_id=? AND kind='message_created' ORDER BY seq LIMIT 1",(run_id,))
        return json.loads(row['payload']).get('tone_id') if row else None

    def active_compaction(self, conversation_id: str) -> dict | None:
        return self.store.one('''SELECT c.*,r.assistant_message_id FROM conversation_contexts x
            JOIN context_compactions c ON c.id=x.compaction_id JOIN runs r ON r.id=c.run_id
            WHERE x.conversation_id=? AND c.activated_at IS NOT NULL''', (conversation_id,))

    def active_summary(self, conversation_id: str) -> dict | None:
        row = self.active_compaction(conversation_id)
        return row if row and row['method']=='summary' else None

    def _public_compaction(self, row: dict | None) -> dict | None:
        if not row:return None
        result = {key:row[key] for key in ('id','run_id','operation_id','summary','created_at','activated_at','method','tokens_before','tokens_after','verification_run_id')}
        run = self.store.one('SELECT status,failure,assistant_message_id FROM runs WHERE id=?', (row['run_id'],))
        result.update(run or {})
        result['generation_status']=result.get('status')
        if row['activated_at']:result['status']='completed'
        elif row['method']=='native' and result.get('status') in {'completed','failed'} and self.store.one(
                "SELECT seq FROM events WHERE run_id=? AND kind='context_native_result' LIMIT 1",(row['run_id'],)):
            result['status']='verifying'
        artifact = self.store.one('SELECT * FROM artifacts WHERE id=?', (row['archive_id'],)) if row['archive_id'] else None
        if artifact:artifact['url']='/api/artifacts/'+artifact['id']+'/content'
        result['archive']=artifact
        return result

    def confirm_pending_native(self, verification: dict) -> bool:
        """Confirm a deferred agent counter from a real subsequent model turn.

        The original generation status and failure events remain immutable.
        No model request, provider-session replacement or estimated count occurs.
        """
        if verification['status']!='completed' or self.compaction_for_run(verification['id']):return False
        with self.store.connect() as db:
            row=db.execute('''SELECT c.*,r.finished_at,r.model,r.effort FROM context_compactions c
                JOIN runs r ON r.id=c.run_id WHERE c.conversation_id=? ORDER BY c.created_at DESC,c.rowid DESC LIMIT 1''',
                (verification['conversation_id'],)).fetchone()
            if (not row or row['method']!='native' or row['activated_at'] or not row['finished_at']
                    or verification['created_at']<=row['finished_at'] or verification['model']!=row['model']
                    or verification['effort']!=row['effort']):return False
            if not db.execute("SELECT seq FROM events WHERE run_id=? AND kind='context_native_result' LIMIT 1",(row['run_id'],)).fetchone():return False
            provider=db.execute('SELECT provider_id FROM conversations WHERE id=?',(row['conversation_id'],)).fetchone()['provider_id']
            if not provider or provider!=row['previous_provider_id']:return False
            after=None
            for event in db.execute("SELECT payload FROM events WHERE run_id=? AND kind='usage' ORDER BY seq DESC",(verification['id'],)):
                value=json.loads(event['payload']).get('usage',{}).get('used')
                if type(value) is int:after=value;break
            before=row['tokens_before']
            if type(before) is not int or type(after) is not int or not 0<=after<before:return False
            stamp=now()
            summary='后续回复已确认整理结果，原始记录和同一模型会话保留。'
            db.execute('UPDATE context_compactions SET summary=?,tokens_after=?,verification_run_id=?,activated_at=? WHERE id=?',
                       (summary,after,verification['id'],stamp,row['id']))
            db.execute('INSERT INTO conversation_contexts VALUES(?,?) ON CONFLICT(conversation_id) DO UPDATE SET compaction_id=excluded.compaction_id',
                       (row['conversation_id'],row['id']))
            self.store.event(db,row['conversation_id'],row['run_id'],'system','context_compacted',
                             {'compaction_id':row['id'],'method':'native','verification_run_id':verification['id']})
            self.store.event(db,row['conversation_id'],verification['id'],'L2','context_verified',
                             {'summary':summary,'tokens_before':before,'tokens_after':after,'source':'gateway_verification'})
        return True

    def reconcile_native(self) -> int:
        count=0
        for candidate in self.store.all("SELECT DISTINCT conversation_id FROM context_compactions WHERE method='native' AND activated_at IS NULL"):
            run=self.store.one('''SELECT r.* FROM runs r LEFT JOIN context_compactions c ON c.run_id=r.id
                WHERE r.conversation_id=? AND r.status='completed' AND c.id IS NULL ORDER BY r.created_at DESC,r.rowid DESC LIMIT 1''',
                (candidate['conversation_id'],))
            if run and self.confirm_pending_native(run):count+=1
        return count

    def composer_state(self, conversation_id: str) -> dict:
        if not self.store.one('SELECT id FROM conversations WHERE id=?', (conversation_id,)):
            raise HTTPException(404,'这一页乐章暂时没有找到。')
        latest = self.store.one('SELECT * FROM context_compactions WHERE conversation_id=? ORDER BY created_at DESC,rowid DESC LIMIT 1', (conversation_id,))
        busy = self.store.one("SELECT id FROM runs WHERE conversation_id=? AND status IN ('queued','running','stopping')", (conversation_id,))
        history = self.store.one('SELECT id FROM messages WHERE conversation_id=? AND length(trim(content))>0 LIMIT 1',(conversation_id,))
        return {'tone_id':self.tone_id(conversation_id),'active_compaction':self._public_compaction(self.active_compaction(conversation_id)),
                'latest_compaction':self._public_compaction(latest),'busy':bool(busy),'has_history':bool(history)}

    def activate_compaction(self, run: dict, summary: str, *, native_usage: tuple[int,int] | None = None) -> bool:
        """Publish the new context and the run's success in one durable commit."""
        with self.store.connect() as db:
            active = db.execute("SELECT status FROM runs WHERE id=?", (run['id'],)).fetchone()
            if not active or active['status'] not in {'running','queued'}:return False
            row = db.execute('SELECT * FROM context_compactions WHERE run_id=?', (run['id'],)).fetchone()
            if not row or not row['archive_id'] or not db.execute('SELECT id FROM artifacts WHERE id=?', (row['archive_id'],)).fetchone():
                raise ValueError('The original transcript has not been archived.')
            previous = db.execute('SELECT provider_id FROM conversations WHERE id=?', (run['conversation_id'],)).fetchone()['provider_id']
            stamp = now()
            db.execute('UPDATE context_compactions SET summary=?,previous_provider_id=?,activated_at=?,method=?,tokens_before=?,tokens_after=? WHERE id=?',
                       (summary,previous,stamp,'native' if native_usage else 'summary',
                        native_usage[0] if native_usage else None,native_usage[1] if native_usage else None,row['id']))
            db.execute('INSERT INTO conversation_contexts VALUES(?,?) ON CONFLICT(conversation_id) DO UPDATE SET compaction_id=excluded.compaction_id',
                       (run['conversation_id'],row['id']))
            # This is the user's explicit context-compaction action. The prior
            # provider session and full transcript remain intact; the next turn
            # starts with the published summary and subsequent messages.
            if not native_usage:db.execute('UPDATE conversations SET provider_id=NULL WHERE id=?', (run['conversation_id'],))
            db.execute("UPDATE runs SET status='completed',finished_at=?,failure=NULL WHERE id=?", (stamp,run['id']))
            db.execute("UPDATE messages SET status='completed' WHERE id=?", (run['assistant_message_id'],))
            self.store.event(db,run['conversation_id'],run['id'],'system','context_compacted',
                             {'compaction_id':row['id'],'method':'native' if native_usage else 'summary'})
            self.store.event(db,run['conversation_id'],run['id'],'system','run_finished',
                             {'message_id':run['assistant_message_id'],'status':'completed'})
        return True

    def tasks(self, message_id: str) -> dict:
        message = self.store.one('SELECT content,status FROM messages WHERE id=?', (message_id,))
        if not message:
            raise HTTPException(404, '这页手稿暂时没有找到。')
        items = task_items(message['content'])
        saved = {row['item_index']: bool(row['checked']) for row in self.store.all('SELECT * FROM message_tasks WHERE message_id=?', (message_id,))}
        return {'tasks': {str(item['index']): saved.get(item['index'], item['initial_checked']) for item in items},
                'items': items, 'editable': message['status'] not in {'queued', 'streaming'}}

    def pins(self, conversation_id: str) -> list[dict]:
        result = self.store.all('SELECT * FROM context_pins WHERE conversation_id=? ORDER BY created_at', (conversation_id,))
        for pin in result:
            if pin['kind'] == 'message':
                source = self.store.one('SELECT role,content FROM messages WHERE id=?', (pin['target_id'],))
                if source:
                    source['content'] = self.store.public_content(pin['target_id'], source['content'])
                pin['source'] = source
            elif pin['kind'] == 'artifact':
                source = self.store.one('SELECT id,name,size,mime,sha256 FROM artifacts WHERE id=?', (pin['target_id'],))
                pin['source'] = source
        return result

    def model_context(self, conversation_id: str) -> dict:
        pins = self.pins(conversation_id)
        for pin in pins:
            if pin['kind'] == 'message' and pin.get('source'):
                content = pin['source']['content']
                pin['source']['content'] = content[:12000]
                pin['source']['excerpt_only'] = len(content) > 12000
        rows = self.store.all('''SELECT t.message_id,t.item_index,t.checked,m.content
            FROM message_tasks t JOIN messages m ON m.id=t.message_id WHERE m.conversation_id=?
            ORDER BY t.updated_at DESC LIMIT 200''', (conversation_id,))
        tasks = []
        parsed = {}
        for row in rows:
            if row['message_id'] not in parsed:
                parsed[row['message_id']] = task_items(row['content'])
            items = parsed[row['message_id']]
            if row['item_index'] < len(items):
                tasks.append({'message_id': row['message_id'], 'text': items[row['item_index']]['text'],
                              'checked': bool(row['checked'])})
        return {'pinned_anchors': pins, 'user_task_states': tasks}

    def router(self, authenticate) -> APIRouter:
        router = APIRouter(prefix='/api', dependencies=[Depends(authenticate)])

        @router.get('/composer/catalog')
        async def composer_catalog():
            return catalog()

        @router.get('/conversations/{conversation_id}/composer')
        async def get_composer(conversation_id: str):
            return self.composer_state(conversation_id)

        @router.post('/conversations/{conversation_id}/tone')
        async def set_tone(conversation_id: str, body: ToneUpdate):
            with self.store.connect() as db:
                if not db.execute('SELECT id FROM conversations WHERE id=?', (conversation_id,)).fetchone():
                    raise HTTPException(404,'这一页乐章暂时没有找到。')
                db.execute('INSERT INTO conversation_tones VALUES(?,?) ON CONFLICT(conversation_id) DO UPDATE SET tone_id=excluded.tone_id',
                           (conversation_id,body.tone_id))
                self.store.event(db,conversation_id,None,'system','tone_changed',{'tone_id':body.tone_id})
            return self.composer_state(conversation_id)

        @router.get('/messages/{message_id}/tasks')
        async def get_tasks(message_id: str):
            return self.tasks(message_id)

        @router.post('/messages/{message_id}/tasks/{index}/update')
        @router.patch('/messages/{message_id}/tasks/{index}')
        async def update_task(message_id: str, index: int, body: TaskUpdate):
            tasks = self.tasks(message_id)
            if not tasks['editable']:
                raise HTTPException(409, '等这一页写完，再勾下已经完成的事。')
            if index < 0 or index >= len(tasks['items']):
                raise HTTPException(404, '这一项不在当前清单里。')
            with self.store.connect() as db:
                message = db.execute('SELECT conversation_id FROM messages WHERE id=?', (message_id,)).fetchone()
                db.execute('INSERT INTO message_tasks VALUES(?,?,?,?) ON CONFLICT(message_id,item_index) DO UPDATE SET checked=excluded.checked,updated_at=excluded.updated_at',
                           (message_id, index, int(body.checked), now()))
                self.store.event(db, message['conversation_id'], None, 'L4', 'widget_updated',
                                 {'message_id': message_id, 'kind': 'task', 'index': index, 'checked': body.checked})
            return self.tasks(message_id)

        @router.get('/conversations/{conversation_id}/pins')
        async def get_pins(conversation_id: str):
            if not self.store.one('SELECT id FROM conversations WHERE id=?', (conversation_id,)):
                raise HTTPException(404, '这一页乐章暂时没有找到。')
            return {'pins': self.pins(conversation_id)}

        @router.post('/conversations/{conversation_id}/pins')
        async def add_pin(conversation_id: str, body: PinInput):
            with self.store.connect() as db:
                if not db.execute('SELECT id FROM conversations WHERE id=?', (conversation_id,)).fetchone():
                    raise HTTPException(404, '这一页乐章暂时没有找到。')
                if db.execute('SELECT count(*) FROM context_pins WHERE conversation_id=?', (conversation_id,)).fetchone()[0] >= 20:
                    raise HTTPException(409, '这一页已经夹了二十枚书签，先收起一枚再添新的吧。')
                if body.kind == 'text' and not body.content.strip():
                    raise HTTPException(422, '先写下要一直记住的话。')
                if body.kind == 'message' and not db.execute('SELECT id FROM messages WHERE id=? AND conversation_id=?', (body.target_id, conversation_id)).fetchone():
                    raise HTTPException(404, '这段话不在当前乐章里。')
                if body.kind == 'artifact' and not db.execute('SELECT id FROM artifacts WHERE id=?', (body.target_id,)).fetchone():
                    raise HTTPException(404, '这份原件还没有收好。')
                ident = uid()
                db.execute('INSERT INTO context_pins VALUES(?,?,?,?,?,?)',
                           (ident, conversation_id, body.kind, body.target_id, body.content, now()))
                self.store.event(db, conversation_id, None, 'system', 'pins_changed', {'pin_id': ident})
            return self.store.one('SELECT * FROM context_pins WHERE id=?', (ident,))

        @router.delete('/pins/{ident}')
        async def remove_pin(ident: str):
            from send2trash import send2trash
            with self.store.connect() as db:
                row = db.execute('SELECT * FROM context_pins WHERE id=?', (ident,)).fetchone()
                if not row:
                    raise HTTPException(404, '这枚书签暂时没有找到。')
                destination = self.data_dir / f'pin-{ident}-{uid()}.json'
                destination.write_text(encoded(dict(row)), encoding='utf-8')
                try:
                    send2trash(str(destination))
                except OSError:
                    raise HTTPException(503, '回收站暂时没有接好，书签仍留在原处。')
                db.execute('DELETE FROM context_pins WHERE id=?', (ident,))
                self.store.event(db, row['conversation_id'], None, 'system', 'pins_changed', {'pin_id': ident})
            return {'status': 'recycled'}

        return router
