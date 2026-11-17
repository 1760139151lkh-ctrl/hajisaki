"""Shared character voice, read on each turn so revisions reach every client."""
from pathlib import Path
import json

DIRECTORY = Path(__file__).resolve().parents[2] / 'shared/persona'


def character_prompt(personality: dict) -> str:
    core = (DIRECTORY / 'sakiko.md').read_text(encoding='utf-8').strip()
    if not core:
        raise ValueError('The character profile is empty.')
    return core + '\n\n当前表达调律（0—100，只调表达浓度，不替换人物核心）：' + json.dumps(personality, ensure_ascii=False) + '\n'


def reply_voice() -> str:
    return (DIRECTORY / 'reply-voice.md').read_text(encoding='utf-8').strip()
