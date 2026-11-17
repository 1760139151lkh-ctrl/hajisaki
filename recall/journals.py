"""Deterministic, source-cited daily/weekly journals made only from supplied quotes.

No database access, model calls, file writes, inferred feelings, or invented recap.
The caller supplies eligible messages already filtered to the selected period.
"""

from __future__ import annotations

from datetime import date as calendar_date, datetime, time, timedelta
import html
import re
from zoneinfo import ZoneInfo


EXCERPT_LIMIT = 60
CHARACTER_LIMIT = 320


def _timestamp(value: str) -> datetime:
    if not isinstance(value, str):
        raise ValueError("Journal timestamps must be ISO strings with a timezone.")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("Journal timestamps must include a timezone.")
    return parsed


def _visible_text(value: str) -> str:
    value = value.replace("\r\n", "\n").replace("\r", "\n")
    return "".join(character for character in value
                   if character in "\n\t" or (ord(character) >= 32 and not 127 <= ord(character) < 160))


def _markdown_text(value: str, *, single_line: bool = False) -> str:
    visible = _visible_text(value)
    if single_line:
        visible = " ".join(visible.split())
    escaped = html.escape(visible, quote=False)
    return re.sub(r"([\\`*_{}\[\]()#+\-.!|>~$])", r"\\\1", escaped)


def build_journal(messages: list[dict], period: str, date: str,
                  timezone_name: str, generated_at: str) -> dict:
    """Return Markdown and a complete provenance document for one local period.

    Weekly periods use the Monday containing ``date``; end bounds are exclusive.
    Every supplied source is represented in JSON, including those not excerpted.
    Quotes contain the exact initial source span (up to 320 Unicode code points);
    Markdown escaping and control-character removal affect display only.
    """
    aliases = {"day": "daily", "daily": "daily", "week": "weekly", "weekly": "weekly"}
    if period not in aliases:
        raise ValueError("Journal period must be daily or weekly.")
    if not isinstance(messages, list):
        raise ValueError("Journal messages must be a list.")
    period = aliases[period]
    selected_date = calendar_date.fromisoformat(date)
    zone = ZoneInfo(timezone_name)
    start_date = selected_date if period == "daily" else selected_date - timedelta(days=selected_date.weekday())
    end_date = start_date + timedelta(days=1 if period == "daily" else 7)
    start = datetime.combine(start_date, time.min, zone)
    end = datetime.combine(end_date, time.min, zone)
    generated = _timestamp(generated_at)
    ordered = []
    seen = set()
    fields = ("id", "conversation_id", "conversation_title", "role", "content", "created_at", "source_hash")
    for message in messages:
        if not isinstance(message, dict) or any(not isinstance(message.get(key), str) for key in fields):
            raise ValueError("A journal source is missing normalized string fields.")
        identity = (message["conversation_id"], message["id"])
        if not all(identity) or identity in seen:
            raise ValueError("Journal sources must have distinct message identities.")
        seen.add(identity)
        if not re.fullmatch(r"[0-9a-fA-F]{64}", message["source_hash"]):
            raise ValueError("Journal sources require SHA-256 source hashes.")
        for flag in ("partial", "simulated"):
            if type(message.get(flag, False)) is not bool:
                raise ValueError("Journal source flags must be boolean.")
        created = _timestamp(message["created_at"])
        if not start <= created < end:
            raise ValueError("A supplied journal source is outside the requested local period.")
        ordered.append((created, message))
    ordered.sort(key=lambda item: (item[0], item[1]["conversation_id"], item[1]["id"]))
    candidates = [item for item in ordered if item[1]["content"].strip()]
    count = min(EXCERPT_LIMIT, len(candidates))
    positions = ([0] if count == 1 else
                 [index * (len(candidates) - 1) // (count - 1) for index in range(count)]) if count else []
    chosen = [candidates[index] for index in positions]
    chosen_ids = {(message["conversation_id"], message["id"]): index + 1
                  for index, (_, message) in enumerate(chosen)}
    sources = []
    for created, message in ordered:
        source = {key: message[key] for key in fields if key != "content"}
        source.update(local_created_at=created.astimezone(zone).isoformat(),
                      partial=message.get("partial", False), simulated=message.get("simulated", False),
                      content_characters=len(message["content"]),
                      excerpt_number=chosen_ids.get((message["conversation_id"], message["id"])))
        if isinstance(message.get("source_url"), str):
            source["source_url"] = message["source_url"]
        sources.append(source)
    counts = {"messages": len(ordered), "conversations": len({message["conversation_id"] for _, message in ordered}),
              "user_messages": sum(message["role"] == "user" for _, message in ordered),
              "assistant_messages": sum(message["role"] == "assistant" for _, message in ordered),
              "partial_messages": sum(message.get("partial", False) for _, message in ordered),
              "simulated_messages": sum(message.get("simulated", False) for _, message in ordered),
              "excerpts": count}
    title = "回忆乐谱 · " + (start_date.isoformat() if period == "daily" else
                           f"{start_date.isoformat()} — {(end_date - timedelta(days=1)).isoformat()}")
    lines = ["# " + title, "", f"{_markdown_text(timezone_name, single_line=True)} · "
             f"{counts['messages']} 条消息 · {counts['conversations']} 段对话", ""]
    if count:
        policy = "全部有文字的消息均已摘录。" if count == len(candidates) else "按时间顺序均匀选取 60 段原文，首尾消息均保留。"
        lines.extend([policy + "每段最多 320 字，来源见脚注。", ""])
    else:
        lines.extend(["这段时间没有可摘录的对话文字。", ""])
    if counts["partial_messages"] or counts["simulated_messages"]:
        lines.extend([f"其中 {counts['partial_messages']} 条为未完成消息，{counts['simulated_messages']} 条为开发演示消息；对应摘录已标明。", ""])
    excerpts = []
    footnotes = []
    for number, (created, message) in enumerate(chosen, 1):
        raw = message["content"][:CHARACTER_LIMIT]
        local = created.astimezone(zone)
        role = {"user": "你", "assistant": "哈基祥"}.get(message["role"], message["role"])
        flags = (["未完成片段"] if message.get("partial", False) else []) + (["开发演示"] if message.get("simulated", False) else [])
        label = " · ".join([role, *flags])
        lines.extend([f"### {local.strftime('%m-%d %H:%M')} · {_markdown_text(label, single_line=True)} [^{number}]", ""])
        lines.extend("> " + line for line in _markdown_text(raw).split("\n"))
        lines.append("")
        truncated = len(message["content"]) > len(raw)
        if truncated:
            lines.extend(["（节选，原文更长。）", ""])
        excerpts.append({"number": number, "message_id": message["id"], "conversation_id": message["conversation_id"],
                         "source_hash": message["source_hash"], "text": raw, "source_span": [0, len(raw)],
                         "truncated": truncated, "display_sanitized": _visible_text(raw) != raw,
                         "partial": message.get("partial", False), "simulated": message.get("simulated", False)})
        footnotes.append(f"[^{number}]: {_markdown_text(message['conversation_title'], single_line=True)} · "
                         f"{local.isoformat()} · 消息 {_markdown_text(message['id'], single_line=True)} · "
                         f"对话 {_markdown_text(message['conversation_id'], single_line=True)}")
    if footnotes:
        lines.extend(["---", "", *footnotes, ""])
    document = {"schema_version": 1, "kind": "extractive_journal", "title": title,
                "period": period, "date": selected_date.isoformat(), "timezone": timezone_name,
                "start_at": start.isoformat(), "end_at_exclusive": end.isoformat(),
                "generated_at": generated.isoformat(), "counts": counts,
                "selection": {"method": "evenly_spaced_chronological_indices", "maximum_excerpts": EXCERPT_LIMIT,
                              "maximum_characters_per_excerpt": CHARACTER_LIMIT, "empty_messages_quoted": False,
                              "generated_summary": False, "inferred_emotions": False},
                "sources": sources, "excerpts": excerpts}
    return {"markdown": "\n".join(lines), "document": document}
