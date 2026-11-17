"""Separate observed CLI retry/schema banners from prose without filtering quoted code."""
from __future__ import annotations

import re
from typing import Callable


FRIENDLY_RETRY = "……信号被晚风吹散了一下，我正在重新接好。已经写下的话都还在。"
PREFIX = "⚠ API error (attempt "
SCHEMA_PREFIX = '⚠ INVALID_ARGUMENT (code 400): '
SCHEMA_LINE = re.compile(
    r'\A⚠ INVALID_ARGUMENT \(code 400\): \* GenerateContentRequest\.tools\[[0-9]+\]\.[^\r\n]+\r?\n\Z'
)
RETRY_LINE = re.compile(
    r"\A⚠ API error \(attempt ([1-9][0-9]*)\): "
    r"(?:request failed: [^\r\n]+|UNAVAILABLE \(code 503\): "
    r"No capacity available for model [A-Za-z0-9._/-]+ on the server)\r?\n\Z"
)


class PublicTextRouter:
    """Buffer only a possible observed vendor banner; ordinary chunks pass immediately.

    The observed vendor banner is one standalone newline-terminated line. The
    match is deliberately exact: no generic Error/timeout/exception suppression.
    Explicit user quotations, Markdown blockquotes and fenced code are preserved.
    """

    def __init__(self, on_text: Callable[[str], None], on_diagnostic: Callable[[str], None], user_text: str = ""):
        self.on_text = on_text
        self.on_diagnostic = on_diagnostic
        self.quoted = 'API error (attempt ' in user_text or 'INVALID_ARGUMENT (code 400)' in user_text or 'GenerateContentRequest.tools[' in user_text
        self.fatal_schema_error = False
        self.pending = ""
        self.line_tail = ""
        self.fence: tuple[str, int] | None = None
        self.quote_paragraph = False
        self.emission_parts: list[str] = []

    def _flush_text(self) -> None:
        if self.emission_parts:
            text = "".join(self.emission_parts)
            self.emission_parts.clear()
            self.on_text(text)

    def _plain(self, text: str) -> None:
        if not text:
            return
        self.emission_parts.append(text)
        lines = (self.line_tail + text).split("\n")
        for line in lines[:-1]:
            previous_fence = self.fence
            match = re.match(r"^ {0,3}(`{3,}|~{3,})(.*)$", line)
            if match:
                marker, remainder = match.groups()
                if self.fence is None:
                    self.fence = (marker[0], len(marker))
                elif marker[0] == self.fence[0] and len(marker) >= self.fence[1] and not remainder.strip():
                    self.fence = None
            if previous_fence is None and self.fence is None:
                if not line.strip():
                    self.quote_paragraph = False
                elif re.match(r"^ {0,3}>", line):
                    self.quote_paragraph = True
        self.line_tail = lines[-1]

    def feed(self, text: str) -> None:
        if not text:
            return
        parts = text.split("\n")
        for index, part in enumerate(parts):
            piece = part + ("\n" if index < len(parts) - 1 else "")
            if piece:
                self._segment(piece)
        self._flush_text()

    def _segment(self, text: str) -> None:
        if self.quoted or self.fence or self.quote_paragraph:
            self._plain(self.pending + text)
            self.pending = ""
            return
        combined = self.pending + text
        # Nonempty indentation is never a vendor banner, even if it arrived alone.
        possible = self.line_tail == '' and any(prefix.startswith(combined) or combined.startswith(prefix)
                                                for prefix in (PREFIX, SCHEMA_PREFIX))
        if not possible:
            self.pending = ""
            self._plain(combined)
            return
        schema_error = SCHEMA_LINE.match(combined)
        match = RETRY_LINE.match(combined) or schema_error
        if match:
            self.pending = ""
            self.fatal_schema_error = self.fatal_schema_error or schema_error is not None
            self._flush_text()
            self.on_diagnostic(match.group())
        elif "\n" in combined or len(combined) > 4096:
            self.pending = ""
            self._plain(combined)
        else:
            self.pending = combined

    def finish(self) -> None:
        self._plain(self.pending)
        self.pending = ""
        self._flush_text()
