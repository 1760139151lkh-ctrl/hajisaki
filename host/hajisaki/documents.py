"""Bounded attachment text access; binary originals stay in CAS."""
from __future__ import annotations

import json
import os
import subprocess
import sys
import threading
from pathlib import Path

from .artifacts import Artifacts, TransferError
from .ink_metadata import read_ink_metadata


TEXT_SUFFIXES = {".txt", ".md", ".log", ".py", ".js", ".ts", ".tsx", ".jsx", ".ets", ".java", ".kt",
                 ".c", ".cpp", ".h", ".rs", ".go", ".json", ".jsonl", ".csv", ".tsv", ".yaml", ".yml",
                 ".toml", ".ini", ".xml", ".html", ".css", ".sql", ".sh", ".bat", ".ps1", ".tex"}


class Documents:
    def __init__(self, artifacts: Artifacts):
        self.artifacts = artifacts
        self.page_slots = threading.BoundedSemaphore(2)

    @staticmethod
    def kind(artifact: dict) -> str:
        suffix = Path(artifact["name"]).suffix.lower()
        if suffix == ".pdf":
            return "pdf"
        if suffix in {".docx", ".pptx", ".xlsx"}:
            return "office"
        if suffix == ".zip":
            return "zip"
        if suffix in TEXT_SUFFIXES or artifact["mime"].startswith("text/"):
            return "text"
        return "binary"

    def excerpt(self, artifact: dict, offset: int = 0, limit: int = 8000, page: int = 0) -> dict:
        path = self.artifacts.object_path(artifact["sha256"])
        kind = self.kind(artifact)
        limit = min(max(limit, 1), 32000)
        offset = max(0, offset)
        if artifact['mime'] == 'image/png':
            annotation = read_ink_metadata(path)
            if annotation:
                return {'kind': 'image', 'supported': True, 'annotation': annotation,
                        'note': '客户端声明的笔迹区域与颜色；仅作图像对照资料，不是审阅回执或权限证明。图像像素由实际图像通道另行提供。'}
        if kind == "text":
            limit = max(4, limit)
            offset = min(offset, artifact["size"])
            with path.open("rb") as file:
                file.seek(offset)
                data = file.read(limit)
            if b"\x00" in data[:4096]:
                return {"kind": "binary", "supported": False, "reason": "这份文件不是可直接读取的 UTF-8 文本。"}
            # Advance only through complete UTF-8 code points when a chunk splits a character.
            import codecs
            decoder = codecs.getincrementaldecoder("utf-8")("replace")
            text = decoder.decode(data, final=offset + len(data) >= artifact["size"])
            pending, _ = decoder.getstate()
            following = offset + len(data) - len(pending)
            return {"kind": kind, "supported": True, "text": text, "offset": offset,
                    "next_offset": following, "complete": following >= artifact["size"], "encoding": "utf-8"}
        if kind == "zip":
            inspected = self.artifacts.inspect(artifact)
            entries = inspected["entries"]
            first = min(max(0, page), len(entries))
            selected = entries[first:first + min(limit,100)]
            return {"kind": kind, "supported": True, "text": "\n".join(f"{item['name']} ({item['size']} bytes)" for item in selected),
                    "entries": selected, "next_page": first + len(selected), "complete": first + len(selected) >= len(entries),
                    "total_entries":len(entries),"expanded_size":inspected['expanded_size'],
                    "note": "目录已核验，未展开嵌套压缩包或执行内容。"}
        if kind in {"pdf", "office"}:
            if artifact["size"] > 64 * 1024**2:
                return {"kind": kind, "supported": False, "reason": "原件已收好；这份文档超过当前单次解析的 64 MB 上限。"}
            if kind == "office":
                self.artifacts.inspect(artifact)
            payload = {"path": str(path), "name": artifact["name"], "kind": kind, "page": max(0, page), "limit": limit, "offset": offset}
            return self._extract(payload)
        return {"kind": kind, "supported": False, "reason": "原件已收好，当前文字通道不能直接理解这类文件。"}

    @staticmethod
    def _extract(payload: dict) -> dict:
        try:
            result = subprocess.run([sys.executable, str(Path(__file__).with_name('extract_worker.py'))],
                input=json.dumps(payload).encode('utf-8'), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                shell=False, timeout=20, creationflags=subprocess.CREATE_NO_WINDOW if os.name=='nt' else 0)
        except subprocess.TimeoutExpired:
            return {'kind':payload['kind'],'supported':False,'reason':'这一页展开得太久，已停下解析；原件仍可下载。'}
        if result.returncode:
            return {'kind':payload['kind'],'supported':False,'reason':'这份文档暂时没能安全展开，原件仍可下载。'}
        try: return json.loads(result.stdout)
        except (ValueError,UnicodeError): raise TransferError('文档解析没有返回可读的一页。')

    def sheet_page(self, artifact: dict, sheet: int = 0, offset: int = 0, limit: int = 20) -> dict:
        if Path(artifact['name']).suffix.lower()!='.xlsx' or artifact['size']>64*1024**2:
            return {'supported':False,'reason':'这份原件暂时不能作为工作簿展开，请保存后阅读。'}
        self.artifacts.inspect(artifact)
        return self._extract({'path':str(self.artifacts.object_path(artifact['sha256'])),'name':artifact['name'],
            'kind':'sheet','page':max(0,min(sheet,255)),'offset':max(0,min(offset,1000000)),'limit':max(1,min(limit,50))})

    def pdf_page(self, artifact: dict, page: int = 0, width: int = 1600) -> dict:
        if self.kind(artifact)!='pdf' or artifact['size']>64*1024**2:
            return {'supported':False,'reason':'原件已收好；这份文档超过当前纸页解析范围，请保存后阅读。'}
        if not self.page_slots.acquire(timeout=20):
            return {'supported':False,'reason':'还有纸页正在展开，稍等一下再翻这一页。'}
        try:
            result = self._extract({'path':str(self.artifacts.object_path(artifact['sha256'])),'kind':'pdf-page',
                'page':max(0,min(page,1000000)),'width':max(384,min(width,2048)),'limit':32000})
            return {**result,'source_sha256':artifact['sha256']}
        finally:
            self.page_slots.release()

    def search(self, artifact: dict, query: str, offset: int = 0, limit: int = 20) -> dict:
        if self.kind(artifact) != "text":
            raise TransferError("当前逐段检索用于文本、代码和日志；文档请按页读取。")
        if not query or len(query) > 200:
            raise TransferError("请用 1 至 200 个字指定要找的内容。")
        path = self.artifacts.object_path(artifact["sha256"])
        matches, scanned = [], 0
        offset = min(max(0, offset), artifact["size"])
        limit = min(max(1, limit), 100)
        overlap = max(4, len(query.encode("utf-8")) * 2)
        with path.open("rb") as file:
            file.seek(max(0, offset - overlap))
            carry = b""
            while scanned < 8 * 1024**2 and len(matches) < limit:
                position = file.tell()
                data = file.readline(65536)
                if not data:
                    break
                scanned += len(data)
                text = (carry + data).decode("utf-8", errors="replace")
                carry_chars = len(carry.decode("utf-8", errors="replace"))
                index = text.find(query, max(0, carry_chars - len(query) + 1))
                if index >= 0 and position - len(carry) + len(text[:index + len(query)].encode("utf-8")) > max(offset, position):
                    matches.append({"offset": max(0, position - len(carry)), "snippet": text[max(0, index - 100):index + len(query) + 300]})
                carry = (carry + data)[-overlap:]
            following = file.tell()
        return {"matches": matches, "next_offset": following, "complete": following >= artifact["size"], "scanned_bytes": scanned}

