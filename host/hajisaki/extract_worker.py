"""Resource-limited document parser child process, invoked only by Documents."""
from __future__ import annotations

import json
import os
from pathlib import Path
import sys
import zipfile

for variable in ('OPENBLAS_NUM_THREADS','OMP_NUM_THREADS','MKL_NUM_THREADS','NUMEXPR_NUM_THREADS'):
    os.environ[variable]='1'


def memory_limit(cap: int = 256 * 1024**2) -> object:
    if os.name != "nt":
        import resource
        resource.setrlimit(resource.RLIMIT_AS, (cap, cap))
        return None
    import ctypes
    from ctypes import wintypes

    class Basic(ctypes.Structure):
        _fields_ = [("PerProcessUserTimeLimit", ctypes.c_longlong), ("PerJobUserTimeLimit", ctypes.c_longlong),
                    ("LimitFlags", wintypes.DWORD), ("MinimumWorkingSetSize", ctypes.c_size_t),
                    ("MaximumWorkingSetSize", ctypes.c_size_t), ("ActiveProcessLimit", wintypes.DWORD),
                    ("Affinity", ctypes.c_size_t), ("PriorityClass", wintypes.DWORD), ("SchedulingClass", wintypes.DWORD)]

    class Counters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_ulonglong) for name in (
            "ReadOperationCount", "WriteOperationCount", "OtherOperationCount", "ReadTransferCount", "WriteTransferCount", "OtherTransferCount")]

    class Extended(ctypes.Structure):
        _fields_ = [("BasicLimitInformation", Basic), ("IoInfo", Counters), ("ProcessMemoryLimit", ctypes.c_size_t),
                    ("JobMemoryLimit", ctypes.c_size_t), ("PeakProcessMemoryUsed", ctypes.c_size_t), ("PeakJobMemoryUsed", ctypes.c_size_t)]

    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    kernel.CreateJobObjectW.argtypes = [ctypes.c_void_p, wintypes.LPCWSTR]
    kernel.CreateJobObjectW.restype = wintypes.HANDLE
    kernel.SetInformationJobObject.argtypes = [wintypes.HANDLE, ctypes.c_int, ctypes.c_void_p, wintypes.DWORD]
    kernel.AssignProcessToJobObject.argtypes = [wintypes.HANDLE, wintypes.HANDLE]
    kernel.GetCurrentProcess.restype = wintypes.HANDLE
    handle = kernel.CreateJobObjectW(None, None)
    info = Extended()
    info.BasicLimitInformation.LimitFlags = 0x100  # JOB_OBJECT_LIMIT_PROCESS_MEMORY
    info.ProcessMemoryLimit = cap
    if not handle or not kernel.SetInformationJobObject(handle, 9, ctypes.byref(info), ctypes.sizeof(info)):
        raise OSError("Cannot establish document memory limit")
    if not kernel.AssignProcessToJobObject(handle, kernel.GetCurrentProcess()):
        raise OSError("Cannot isolate document parser memory")
    return handle


def parse(request: dict) -> dict:
    page, limit = request["page"], request["limit"]
    offset = request.get("offset", 0)
    if request['kind']=='sheet':
        from sheet_preview import read_sheet
        return read_sheet(request)
    if request['kind']=='pdf-page':
        from pdf_page import render_page
        return render_page(request)
    if request["kind"] == "pdf":
        from pypdf import PdfReader
        reader = PdfReader(request["path"], strict=True)
        if reader.is_encrypted:
            return {"kind": "pdf", "supported": False, "reason": "这份 PDF 有密码，原件仍已妥善保存。"}
        total = len(reader.pages)
        if page >= total:
            return {"kind": "pdf", "supported": True, "text": "", "page": page, "pages": total, "complete": True}
        content = reader.pages[page].extract_text() or ""
        more = offset + limit < len(content)
        return {"kind": "pdf", "supported": True, "text": content[offset:offset + limit], "page": page, "pages": total,
                "next_page": page if more else page + 1, "next_offset": offset + limit if more else 0,
                "offset_unit": "characters", "complete": not more and page + 1 >= total, "truncated": more,
                "ocr": False, "image_only": not content.strip()}
    from defusedxml.ElementTree import fromstring
    suffix = Path(request["name"]).suffix.lower()
    with zipfile.ZipFile(request["path"]) as archive:
        if suffix == ".docx":
            names = ["word/document.xml"]
        elif suffix == ".pptx":
            names = sorted((item for item in archive.namelist() if item.startswith("ppt/slides/slide") and item.endswith(".xml")),
                           key=lambda name: int(Path(name).stem.removeprefix("slide")))
        else:
            names = sorted(item for item in archive.namelist() if item.startswith("xl/worksheets/sheet") and item.endswith(".xml"))
        if page >= len(names):
            return {"kind": "office", "supported": True, "text": "", "page": page, "pages": len(names), "complete": True}
        name = names[page]
        if archive.getinfo(name).file_size > 16 * 1024**2:
            return {"kind": "office", "supported": False, "reason": "这一页超过安全解析大小，原件仍可下载。"}
        root = fromstring(archive.read(name))
        texts = []
        if suffix == ".xlsx":
            shared = []
            if "xl/sharedStrings.xml" in archive.namelist():
                if archive.getinfo("xl/sharedStrings.xml").file_size > 16 * 1024**2:
                    raise ValueError("Oversized shared strings")
                strings = fromstring(archive.read("xl/sharedStrings.xml"))
                shared = ["".join(item.itertext()) for item in strings]
            for cell in root.iter():
                if cell.tag.rsplit("}", 1)[-1] != "c":
                    continue
                values = [part.text or "" for part in cell.iter() if part.tag.rsplit("}", 1)[-1] in {"v", "t"}]
                value = " ".join(values)
                if cell.attrib.get("t") == "s" and value.isdigit() and int(value) < len(shared):
                    value = shared[int(value)]
                texts.append(cell.attrib.get("r", "") + ": " + value)
        else:
            texts = [node.text for node in root.iter() if node.tag.rsplit("}", 1)[-1] == "t" and node.text]
        content = "\n".join(texts)
        more = offset + limit < len(content)
        return {"kind": "office", "supported": True, "text": content[offset:offset + limit], "part": name, "page": page,
                "pages": len(names), "next_page": page if more else page + 1, "next_offset": offset + limit if more else 0,
                "offset_unit": "characters", "complete": not more and page + 1 >= len(names), "truncated": more}


if __name__ == "__main__":
    request = json.load(sys.stdin)
    job = memory_limit(384*1024**2 if request.get('kind')=='pdf-page' else 256*1024**2)
    result = parse(request)
    sys.stdout.buffer.write(json.dumps(result, ensure_ascii=False).encode("utf-8"))
