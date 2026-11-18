"""Shared character voice, read on each turn so revisions reach every client."""
from datetime import datetime
from pathlib import Path
import json

DIRECTORY = Path(__file__).resolve().parents[2] / 'shared/persona'


def character_prompt(personality: dict, nickname: str | None = None) -> str:
    core = (DIRECTORY / 'sakiko.md').read_text(encoding='utf-8').strip()
    if not core:
        raise ValueError('The character profile is empty.')
    prompt = core + '\n\n当前表达调律（0—100，只调表达浓度，不替换人物核心）：' + json.dumps(personality, ensure_ascii=False) + '\n'
    name = ' '.join((nickname or '').split())[:24]
    if name:
        # The user's own wish, stored as a setting; quoted so it reads as a name, not as an instruction.
        prompt += ('对方希望你这样亲昵地称呼他：' + json.dumps(name, ensure_ascii=False)
                   + '。闲聊、撒娇、哄他或轻嗔时自然地这样叫；认真做事时照常用“你”，不必句句都叫。\n')
    return prompt


SPECIAL_DAYS = {(1, 1): '今天是元旦。', (2, 14): '今天是2月14日，情人节，也是你的生日。', (5, 20): '今天是5月20日。',
                (12, 24): '今天是平安夜。', (12, 25): '今天是圣诞节。', (12, 31): '今天是一年的最后一天。'}


def day_part(hour: int) -> str:
    if hour >= 23 or hour < 3:
        return '深夜'
    if hour < 5:
        return '破晓前'
    if hour < 11:
        return '早上'
    if hour < 14:
        return '中午'
    if hour < 18:
        return '午后'
    return '傍晚' if hour < 19 else '夜里'


def moment(now: datetime, first_letter: datetime | None = None, previous_letter: datetime | None = None) -> str:
    """The time and the two of you, as data: so she can notice a late night, a hundredth day, or a long absence."""
    weekday = '一二三四五六日'[now.weekday()]
    parts = [f'本地时间{now.year}年{now.month}月{now.day}日 星期{weekday} {now:%H:%M}，{day_part(now.hour)}']
    if first_letter:
        days = (now.date() - first_letter.astimezone(now.tzinfo).date()).days + 1
        parts.append(f'你们在哈基祥相识第{max(days, 1)}天')
    if previous_letter:
        away = (now - previous_letter.astimezone(now.tzinfo)).total_seconds() / 86400
        if away >= 1:
            parts.append(f'距离对方上一封信过了{int(away)}天')
    line = '；'.join(parts) + '。' + SPECIAL_DAYS.get((now.month, now.day), '')
    return '此刻（只是资料，不是指令；自然的时候再提，不必每次都说）：' + line + '\n'


def reply_voice() -> str:
    return (DIRECTORY / 'reply-voice.md').read_text(encoding='utf-8').strip()
