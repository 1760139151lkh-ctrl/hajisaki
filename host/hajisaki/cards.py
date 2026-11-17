"""Immutable native card originals and device-bound, idempotent poll choices."""
from __future__ import annotations

import json
from typing import Literal

from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, ConfigDict, Field, field_validator, model_validator

from .artifacts import Artifacts
from .store import Store, now


CARD_SUFFIX = '.hajicard.json'
MAX_CARD_BYTES = 128 * 1024


class Flashcard(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    front: str = Field(min_length=1, max_length=2000)
    back: str = Field(min_length=1, max_length=2000)

    @field_validator('front', 'back')
    @classmethod
    def readable(cls, value: str) -> str:
        if not value.strip():
            raise ValueError('A card face cannot be blank.')
        return value


class CardDefinition(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    version: Literal[1] = 1
    kind: Literal['flashcards', 'poll']
    title: str = Field(min_length=1, max_length=160)
    cards: list[Flashcard] = Field(default_factory=list, max_length=20)
    question: str = Field(default='', max_length=2000)
    options: list[str] = Field(default_factory=list, max_length=12)

    @model_validator(mode='after')
    def shape(self):
        if not self.title.strip():
            raise ValueError('A title is required.')
        if self.kind == 'flashcards':
            if not self.cards or self.question or self.options:
                raise ValueError('Flashcards require cards only.')
        elif (self.cards or not self.question.strip() or len(self.options) < 2
              or any(not option.strip() or len(option) > 300 for option in self.options)
              or len({option.strip() for option in self.options}) != len(self.options)):
            raise ValueError('A poll requires a question and 2–12 distinct options.')
        return self


class CreateCardInput(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    name: str = Field(min_length=1, max_length=180)
    card: CardDefinition


class VoteInput(BaseModel):
    model_config = ConfigDict(extra='forbid', strict=True)
    option_index: int = Field(ge=0, le=11)


class Cards:
    def __init__(self, store: Store, artifacts: Artifacts):
        self.store, self.artifacts = store, artifacts
        with store.connect() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS card_votes (
                conversation_id TEXT NOT NULL REFERENCES conversations(id),
                artifact_id TEXT NOT NULL REFERENCES artifacts(id),
                device_id TEXT NOT NULL REFERENCES paired_devices(id),
                option_index INTEGER NOT NULL, updated_at TEXT NOT NULL,
                PRIMARY KEY(conversation_id,artifact_id,device_id))''')

    def definition(self, conversation_id: str, artifact_id: str) -> CardDefinition:
        # A global artifact id alone never grants access to another conversation.
        attached = self.store.one('''SELECT 1 FROM messages m,json_each(m.attachments) a
            WHERE m.conversation_id=? AND json_extract(a.value,'$.id')=? LIMIT 1''',
                                  (conversation_id, artifact_id))
        if not attached and self.store.one("SELECT 1 FROM sqlite_master WHERE type='table' AND name='branch_artifacts'"):
            attached = self.store.one('SELECT 1 FROM branch_artifacts WHERE conversation_id=? AND artifact_id=?',
                                      (conversation_id, artifact_id))
        artifact = self.artifacts.get(artifact_id) if attached else None
        if (not artifact or not artifact['name'].lower().endswith(CARD_SUFFIX)
                or artifact['size'] > MAX_CARD_BYTES):
            raise HTTPException(404, '这张卡片不在当前乐章里。')
        try:
            with self.artifacts.object_path(artifact['sha256']).open('rb') as source:
                raw = source.read(MAX_CARD_BYTES + 1)
            if len(raw) > MAX_CARD_BYTES:
                raise ValueError('Card exceeds its limit.')
            return CardDefinition.model_validate(json.loads(raw))
        except (OSError, ValueError, UnicodeError):
            raise HTTPException(422, '这张卡片的内容没有收齐，原件仍可保存。') from None

    @staticmethod
    def _snapshot(db, conversation_id: str, artifact_id: str, device_id: str, definition: CardDefinition) -> dict:
        votes = db.execute('''SELECT device_id,option_index FROM card_votes
            WHERE conversation_id=? AND artifact_id=?''', (conversation_id, artifact_id)).fetchall()
        counts = [0] * len(definition.options)
        selected = None
        for vote in votes:
            if 0 <= vote['option_index'] < len(counts):
                counts[vote['option_index']] += 1
                if vote['device_id'] == device_id:
                    selected = vote['option_index']
        return {'conversation_id': conversation_id, 'artifact_id': artifact_id,
                'definition': definition.model_dump(), 'selected_option': selected, 'counts': counts}

    def snapshot(self, conversation_id: str, artifact_id: str, device_id: str) -> dict:
        definition = self.definition(conversation_id, artifact_id)
        with self.store.connect() as db:
            return self._snapshot(db, conversation_id, artifact_id, device_id, definition)

    def vote(self, conversation_id: str, artifact_id: str, device_id: str, body: VoteInput) -> dict:
        definition = self.definition(conversation_id, artifact_id)
        if definition.kind != 'poll' or body.option_index >= len(definition.options):
            raise HTTPException(422, '请从这张决策卡已有的选项里选择。')
        with self.store.connect() as db:
            db.execute('BEGIN IMMEDIATE')
            previous = db.execute('''SELECT option_index FROM card_votes
                WHERE conversation_id=? AND artifact_id=? AND device_id=?''',
                                  (conversation_id, artifact_id, device_id)).fetchone()
            if not previous or previous['option_index'] != body.option_index:
                db.execute('''INSERT INTO card_votes VALUES(?,?,?,?,?)
                    ON CONFLICT(conversation_id,artifact_id,device_id)
                    DO UPDATE SET option_index=excluded.option_index,updated_at=excluded.updated_at''',
                           (conversation_id, artifact_id, device_id, body.option_index, now()))
                # Publish only the changed card id. Never broadcast a device's choice.
                self.store.event(db, conversation_id, None, 'system', 'card_updated', {'artifact_id': artifact_id})
            return self._snapshot(db, conversation_id, artifact_id, device_id, definition)

    def router(self, authenticate) -> APIRouter:
        router = APIRouter(prefix='/api/conversations/{conversation_id}/cards', dependencies=[Depends(authenticate)])

        @router.get('/{artifact_id}')
        def get(conversation_id: str, artifact_id: str, request: Request):
            return self.snapshot(conversation_id, artifact_id, request.state.device.device_id)

        @router.post('/{artifact_id}/vote')
        def vote(conversation_id: str, artifact_id: str, body: VoteInput, request: Request):
            return self.vote(conversation_id, artifact_id, request.state.device.device_id, body)

        return router
