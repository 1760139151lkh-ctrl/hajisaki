"""Explicit, read-only host/code and historical-message references for drafts."""
from __future__ import annotations

import asyncio
import hashlib
from itertools import islice
import os
import re
from pathlib import Path, PurePosixPath
import stat
import threading
import time
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, ConfigDict, Field

from .artifacts import Artifacts
from .config import PROJECT_ROOT
from .store import Store, encoded, now, uid


MAX_BYTES = 1024 * 1024
MAX_FILES = 64
SKIP_DIRS = frozenset({'.git', '.venv', 'venv', 'node_modules', 'oh_modules', '__pycache__',
    '.hvigor', 'build', 'dist', 'runtime', 'releases', 'tooling', '.codex', '.gemini', '.ssh', '.aws', '.azure'})
PRIVATE_NAMES = frozenset({'pairing.json', 'credentials.json', 'credential.json', 'token.json',
    'tokens.json', 'auth.json', 'id_rsa', 'id_ed25519', 'package-lock.json', 'pnpm-lock.yaml'})
DOT_FILES = frozenset({'.gitignore', '.gitattributes', '.editorconfig'})
SUFFIXES = frozenset({'.py','.ets','.ts','.tsx','.js','.mjs','.cjs','.jsx','.java','.kt','.swift',
    '.m','.mm','.c','.cpp','.h','.hpp','.rs','.go','.cs','.fs','.json','.jsonl','.toml','.yaml','.yml',
    '.xml','.html','.htm','.css','.scss','.sql','.md','.markdown','.txt','.ps1','.sh','.bat','.cmd',
    '.gradle','.vue','.svelte','.r','.tex'})


class ReferenceBody(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)


class RootInput(ReferenceBody):
    name: str = Field(min_length=1,max_length=80)
    path: str = Field(min_length=1,max_length=2048)


class RootUpdate(ReferenceBody):
    enabled: bool


class SnapshotInput(ReferenceBody):
    kind: Literal['file','folder','message']
    root_id: str = Field(default='',max_length=32,pattern=r'^[0-9a-f]*$')
    path: str = Field(default='',max_length=2048)
    message_id: str = Field(default='',max_length=32,pattern=r'^[0-9a-f]*$')
    operation_id: str = Field(min_length=1,max_length=100,pattern=r'^[A-Za-z0-9_-]+$')


class References:
    def __init__(self, artifacts: Artifacts, store: Store):
        self.artifacts,self.store = artifacts,store
        self.lock = threading.Lock()
        self.private_data = artifacts.config.data_dir.resolve()
        self.private_homes = [(Path.home()/part).resolve() for part in ('.codex','.gemini','.ssh','.aws','.azure')]
        with store.connect() as db:
            db.executescript('''
                CREATE TABLE IF NOT EXISTS reference_roots (
                  id TEXT PRIMARY KEY,name TEXT NOT NULL,path TEXT NOT NULL,path_key TEXT UNIQUE NOT NULL,
                  enabled INTEGER NOT NULL,created_at TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS reference_snapshots (
                  device TEXT NOT NULL,operation_id TEXT NOT NULL,payload_hash TEXT NOT NULL,
                  artifact_id TEXT NOT NULL,origin TEXT NOT NULL,created_at TEXT NOT NULL,
                  PRIMARY KEY(device,operation_id));
            ''')
            root = PROJECT_ROOT.resolve()
            db.execute('INSERT OR IGNORE INTO reference_roots VALUES(?,?,?,?,1,?)',
                       (uid(),root.name,str(root),os.path.normcase(str(root)),now()))

    @staticmethod
    def _owner(principal):
        if principal.role != 'owner':
            raise HTTPException(403,'请在主机上用主人钥匙设置可引用的代码目录。')

    def roots(self, owner: bool = False) -> list[dict]:
        result = self.store.all('SELECT id,name,path,enabled,created_at FROM reference_roots ORDER BY created_at,id')
        for item in result:
            item['enabled'] = bool(item['enabled'])
            item['available'] = Path(item['path']).is_dir()
            if not owner:item.pop('path')
        return result if owner else [item for item in result if item['enabled']]

    def add_root(self, body: RootInput) -> dict:
        name = body.name.strip()
        path = Path(body.path).expanduser()
        try:name.encode('utf-8',errors='strict')
        except UnicodeError:raise HTTPException(422,'这份目录名称暂时不能读取，请重新填写。') from None
        if not name or any(ord(c)<32 for c in name) or not path.is_absolute() or str(path).startswith('\\\\'):
            raise HTTPException(422,'请填写代码目录的名称和本机绝对路径。')
        try:path = path.resolve(strict=True)
        except (OSError,ValueError,RuntimeError):raise HTTPException(422,'这份代码目录暂时找不到，请检查主机路径。') from None
        if not path.is_dir() or self._private(path):
            raise HTTPException(422,'请选一份代码目录，配对钥匙与私有运行资料不会加入引用。')
        with self.store.connect() as db:
            existing = db.execute('SELECT id FROM reference_roots WHERE path_key=?',(os.path.normcase(str(path)),)).fetchone()
            if existing:
                active = db.execute('SELECT enabled FROM reference_roots WHERE id=?',(existing['id'],)).fetchone()[0]
                if not active and db.execute('SELECT count(*) FROM reference_roots WHERE enabled=1').fetchone()[0]>=12:
                    raise HTTPException(409,'已经开放十二份目录，请先停用不再引用的目录。')
                db.execute('UPDATE reference_roots SET name=?,enabled=1 WHERE id=?',(name,existing['id']))
                ident = existing['id']
            else:
                if db.execute('SELECT count(*) FROM reference_roots WHERE enabled=1').fetchone()[0]>=12:
                    raise HTTPException(409,'已经登记十二份目录，请先停用不再引用的目录。')
                ident = uid()
                db.execute('INSERT INTO reference_roots VALUES(?,?,?,?,1,?)',
                           (ident,name,str(path),os.path.normcase(str(path)),now()))
        return next(item for item in self.roots(True) if item['id']==ident)

    def _private(self, path: Path) -> bool:
        return path.is_relative_to(self.private_data) or any(path.is_relative_to(p) for p in self.private_homes)

    @staticmethod
    def _name_allowed(name: str, directory: bool) -> bool:
        lower = name.casefold()
        if any(ord(c)<32 or ord(c)==127 for c in name):return False
        if lower.startswith('.env') or lower in PRIVATE_NAMES:return False
        if directory:return lower not in SKIP_DIRS and not lower.startswith('.')
        return (not lower.startswith('.') or lower in DOT_FILES) and (Path(name).suffix.casefold() in SUFFIXES or lower in DOT_FILES)

    def _root(self, ident: str) -> tuple[dict,Path]:
        row = self.store.one('SELECT * FROM reference_roots WHERE id=? AND enabled=1',(ident,))
        if not row:raise HTTPException(404,'这份代码目录还没有开放引用，或已被停用。')
        try:path = Path(row['path']).resolve(strict=True)
        except (OSError,ValueError,RuntimeError):raise HTTPException(404,'这份代码目录暂时没有接回主机。') from None
        if not path.is_dir() or self._private(path):raise HTTPException(403,'这份目录暂时不能作为代码引用。')
        return row,path

    def _path(self, root: Path, relative: str) -> Path:
        pure = PurePosixPath(relative)
        if (pure.is_absolute() or '\\' in relative or ':' in relative or '\0' in relative
                or '..' in pure.parts or any(part.startswith('.env') for part in pure.parts)):
            raise HTTPException(403,'这份内容不在当前可引用目录里。')
        try:path = root.joinpath(*pure.parts).resolve(strict=True)
        except (OSError,ValueError,RuntimeError):raise HTTPException(404,'这份代码刚刚移动了，请刷新后重新选择。') from None
        if not path.is_relative_to(root) or self._private(path):
            raise HTTPException(403,'这份内容不在当前可引用目录里。')
        for parts in (pure.parts,path.relative_to(root).parts):
            for part in parts[:-1]:
                if not self._name_allowed(part,True):raise HTTPException(403,'这份目录没有加入代码引用。')
            if parts and not self._name_allowed(parts[-1],path.is_dir()):
                raise HTTPException(403,'这份文件没有加入代码引用。')
        return path

    def entries(self, root_id: str, relative: str, query: str, limit: int) -> dict:
        row,root = self._root(root_id)
        base = self._path(root,relative)
        if not base.is_dir():raise HTTPException(422,'请先选一份目录。')
        term = query.strip().casefold()
        result,visited = [],0
        pending = [base]
        started = time.monotonic()
        partial = False
        while pending:
            current = pending.pop()
            try:
                with os.scandir(current) as scan:children = sorted(islice(scan,10001),key=lambda e:e.name.casefold())
            except OSError:
                partial = True;continue
            for entry in children:
                visited+=1
                if visited>10000 or time.monotonic()-started>2:
                    partial=True;pending=[];break
                try:
                    directory = entry.is_dir(follow_symlinks=False)
                    if entry.is_symlink() or (hasattr(entry,'is_junction') and entry.is_junction()):continue
                    if not self._name_allowed(entry.name,directory):continue
                    path = Path(entry.path).resolve(strict=True)
                    if not path.is_relative_to(root) or self._private(path):continue
                    if not directory and not entry.is_file(follow_symlinks=False):continue
                    local = path.relative_to(root).as_posix()
                    if term and directory:pending.append(path)
                    if term and term not in local.casefold():continue
                    info = entry.stat(follow_symlinks=False)
                    result.append({'name':entry.name,'path':local,'kind':'folder' if directory else 'file',
                                   'size':0 if directory else info.st_size})
                    if len(result)>limit:partial=True;pending=[];break
                except OSError:partial=True
            if not term:break
        result.sort(key=lambda item:(item['kind']!='folder',item['path'].casefold()))
        return {'root_id':row['id'],'path':'' if base==root else base.relative_to(root).as_posix(),
                'entries':result[:limit],'partial':partial}

    def history(self, query: str, limit: int, offset: int) -> dict:
        term = '%'+query.replace('\\','\\\\').replace('%','\\%').replace('_','\\_')+'%'
        rows = self.store.all('''SELECT m.id,m.conversation_id,m.role,m.content,m.created_at,c.title,c.archived
            FROM messages m JOIN conversations c ON c.id=m.conversation_id
            WHERE c.group_name!='私密保险箱' AND trim(m.content)!='' AND m.status NOT IN ('queued','streaming')
              AND (m.content LIKE ? ESCAPE '\\' OR c.title LIKE ? ESCAPE '\\')
            ORDER BY m.created_at DESC,m.rowid DESC LIMIT ? OFFSET ?''',(term,term,limit+1,offset))
        result=[]
        for row in rows[:limit]:
            row['archived'] = bool(row['archived'])
            text = self.store.public_content(row['id'],row.pop('content'))
            if query and query.casefold() not in (row['title']+'\n'+text).casefold():continue
            start = max(0,text.casefold().find(query.casefold())-60) if query else 0
            result.append({**row,'excerpt':text[start:start+240],'characters':len(text)})
        return {'messages':result,'more':len(rows)>limit}

    def _read(self, path: Path, root: Path) -> tuple[str,str]:
        try:
            flags = os.O_RDONLY | getattr(os,'O_BINARY',0) | getattr(os,'O_NONBLOCK',0) | getattr(os,'O_NOFOLLOW',0)
            with os.fdopen(os.open(path,flags),'rb') as source:
                before = os.fstat(source.fileno())
                if not stat.S_ISREG(before.st_mode) or before.st_size>MAX_BYTES:
                    raise HTTPException(413,'这份代码较大，请选择一个更小的文件或子目录。')
                data = source.read(MAX_BYTES+1)
                after = os.fstat(source.fileno())
            current = path.stat()
        except OSError:raise HTTPException(409,'这份代码暂时读不到，请在主机确认后重新选择。') from None
        if (len(data)>MAX_BYTES or (before.st_dev,before.st_ino,before.st_size,before.st_mtime_ns)!=
                (after.st_dev,after.st_ino,after.st_size,after.st_mtime_ns) or
                (after.st_dev,after.st_ino,after.st_mtime_ns)!=(current.st_dev,current.st_ino,current.st_mtime_ns)):
            raise HTTPException(409,'这份代码刚刚变动了，请重新选择。')
        self._path(root,path.relative_to(root).as_posix())
        try:text = data.decode('utf-16' if data[:2] in (b'\xff\xfe',b'\xfe\xff') else 'utf-8-sig')
        except UnicodeError:raise HTTPException(422,'这份文件不是当前可读取的文字编码，原文件没有改动。') from None
        if '\0' in text:raise HTTPException(422,'这份文件含有二进制内容，暂时不能作为代码引用。')
        return text,hashlib.sha256(data).hexdigest()

    @staticmethod
    def _section(relative: str, text: str, digest: str) -> str:
        fence = '`'*(max([len(part) for part in re.findall(r'`+',text)]+[2])+1)
        return f'## {relative}\n\n原文件 SHA-256：{digest}\n\n{fence}\n{text}\n{fence}\n'

    def _file_content(self, body: SnapshotInput) -> tuple[str,str,str]:
        row,root = self._root(body.root_id)
        path = self._path(root,body.path)
        origin = row['name']+'/'+path.relative_to(root).as_posix()
        header = f'# 代码引用\n\n来源：{origin}\n\n收录时间：{now()}\n\n'
        if body.kind=='file':
            if not path.is_file():raise HTTPException(422,'这一项是一份目录，请按文件夹引用。')
            text,digest = self._read(path,root)
            return path.name+'-引用.md',header+self._section(path.name,text,digest),origin
        if not path.is_dir():raise HTTPException(422,'这一项不是文件夹。')
        pending,sections,count = [path],[],0
        started = time.monotonic()
        while pending:
            current = pending.pop()
            try:
                with os.scandir(current) as scan:children = sorted(islice(scan,10001),key=lambda e:e.name.casefold())
            except OSError:raise HTTPException(409,'文件夹里有暂时读不到的代码，请选择一份可读取的子目录。') from None
            if len(children)>10000:raise HTTPException(413,'这份目录的内容较多，请选择一个子目录。')
            for entry in children:
                if time.monotonic()-started>5:raise HTTPException(413,'这份文件夹较大，请选择一份更小的子目录。')
                directory = entry.is_dir(follow_symlinks=False)
                if entry.is_symlink() or (hasattr(entry,'is_junction') and entry.is_junction()) or not self._name_allowed(entry.name,directory):continue
                raw = Path(entry.path).resolve()
                if self._private(raw):continue
                child = self._path(root,Path(entry.path).relative_to(root).as_posix())
                if directory:pending.append(child);continue
                if not entry.is_file(follow_symlinks=False):continue
                text,digest = self._read(child,root)
                sections.append(self._section(child.relative_to(path).as_posix(),text,digest));count+=1
                if count>MAX_FILES or sum(len(s.encode('utf-8')) for s in sections)>MAX_BYTES:
                    raise HTTPException(413,'这份文件夹超过六十四份文件或一 MiB 文字，请选择一个子目录。')
        if not count:raise HTTPException(422,'这份目录里还没有可引用的代码或文字文件。')
        return path.name+'-文件夹引用.md',header+f'收录文件：{count} 份\n\n范围：可引用的代码与文字文件；依赖、构建缓存和私有运行资料不在其中。\n\n'+''.join(sections),origin

    def snapshot(self, body: SnapshotInput, device: str) -> dict:
        digest = hashlib.sha256(body.model_dump_json(exclude={'operation_id'}).encode()).hexdigest()
        if not self.lock.acquire(timeout=2):raise HTTPException(429,'还有一份引用正在收好，稍后再选。')
        try:
            previous = self.store.one('SELECT * FROM reference_snapshots WHERE device=? AND operation_id=?',(device,body.operation_id))
            if previous:
                if previous['payload_hash']!=digest:raise HTTPException(409,'这份引用已经收好，另一份内容需要重新选择。')
                return {'artifact':self.artifacts.get(previous['artifact_id']),'origin':previous['origin']}
            if body.kind=='message':
                row = self.store.one('''SELECT m.*,c.title,c.group_name FROM messages m JOIN conversations c ON c.id=m.conversation_id WHERE m.id=?''',(body.message_id,))
                if not row or row['group_name']=='私密保险箱' or row['status'] in {'queued','streaming'}:
                    raise HTTPException(404,'这段话暂时不能作为历史引用。')
                text = self.store.public_content(row['id'],row['content'])
                if not text.strip():raise HTTPException(422,'这条消息没有可引用的正文。')
                origin = row['title']+' · '+row['created_at']
                name = row['title']+'-对话引用.md'
                content = f'# 过往乐章引用\n\n乐章：{row["title"]}\n\n时间：{row["created_at"]}\n\n角色：{row["role"]}\n\n原始消息：{row["id"]}\n\n---\n\n{text}\n'
            else:name,content,origin = self._file_content(body)
            data = content.encode('utf-8')
            if len(data)>MAX_BYTES:raise HTTPException(413,'这份引用较长，请选择一段更短的内容或子目录。')
            state = self.artifacts.begin(name,len(data),hashlib.sha256(data).hexdigest(),'text/markdown')
            if state['complete']:artifact = state['artifact']
            else:
                self.artifacts.append(state['id'],state['offset'],data[state['offset']:])
                artifact = self.artifacts.complete(state['id'])
            with self.store.connect() as db:
                db.execute('INSERT INTO reference_snapshots VALUES(?,?,?,?,?,?)',
                           (device,body.operation_id,digest,artifact['id'],origin,now()))
            return {'artifact':artifact,'origin':origin}
        finally:self.lock.release()

    def router(self, authenticate) -> APIRouter:
        router = APIRouter(prefix='/api/references',dependencies=[Depends(authenticate)])

        @router.get('/roots')
        async def roots(principal=Depends(authenticate)):
            return {'roots':await asyncio.to_thread(self.roots,principal.role=='owner'),'can_manage':principal.role=='owner'}

        @router.post('/roots')
        async def add_root(body: RootInput,principal=Depends(authenticate)):
            self._owner(principal)
            return await asyncio.to_thread(self.add_root,body)

        @router.post('/roots/{ident}/update')
        async def update_root(ident: str,body: RootUpdate,principal=Depends(authenticate)):
            self._owner(principal)
            with self.store.connect() as db:
                if not db.execute('SELECT id FROM reference_roots WHERE id=?',(ident,)).fetchone():
                    raise HTTPException(404,'这份目录还没有登记。')
                if body.enabled and not db.execute('SELECT enabled FROM reference_roots WHERE id=?',(ident,)).fetchone()[0] and db.execute('SELECT count(*) FROM reference_roots WHERE enabled=1').fetchone()[0]>=12:
                    raise HTTPException(409,'已经开放十二份目录，请先停用不再引用的目录。')
                db.execute('UPDATE reference_roots SET enabled=? WHERE id=?',(int(body.enabled),ident))
            return {'status':'updated'}

        @router.get('/roots/{ident}/entries')
        async def entries(ident: str,path: str=Query(default='',max_length=2048),q: str=Query(default='',max_length=120),limit: int=Query(default=60,ge=1,le=100)):
            return await asyncio.to_thread(self.entries,ident,path,q,limit)

        @router.get('/history')
        async def history(q: str=Query(default='',max_length=120),offset: int=Query(default=0,ge=0,le=1000000),limit: int=Query(default=40,ge=1,le=100)):
            return await asyncio.to_thread(self.history,q,limit,offset)

        @router.post('/snapshots')
        async def snapshot(body: SnapshotInput,request: Request,principal=Depends(authenticate)):
            result = await asyncio.to_thread(self.snapshot,body,principal.device_id)
            await authenticate(request)
            return result

        return router
