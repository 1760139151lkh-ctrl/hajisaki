"""Run-scoped stdio MCP bridge; no owner credentials, shell, or arbitrary file IO.

Prefer HAJI_AGENT_GRANT_FILE pointing to a private {token,run_id,port} JSON file.
Manual compatibility: HAJI_AGENT_TOKEN, HAJI_RUN_ID, HAJI_PORT. The gateway must
explicitly enable this run's grant; an observation-mode grant cannot execute tools.
"""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import sys
import urllib.error
import urllib.request

MAX_LINE = 8 * 1024 * 1024
TOOL_PROFILE = 2
ARTIFACT_ID = {"type": "string", "pattern": "^[0-9a-f]{32}$"}
PATH = {"type": "string", "minLength": 1, "maxLength": 1000}
NAME = {"type": "string", "minLength": 1, "maxLength": 180}
CELL = {"anyOf": [{"type":"string","maxLength":1000},
                  {"type":"number","minimum":-1000000000000000,"maximum":1000000000000000},
                  {"type":"boolean"},{"type":"null"}]}


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, request, response, code, message, headers, new_url):
        return None


def schema(properties: dict, required: list[str]) -> dict:
    return {"type": "object", "properties": properties, "required": required, "additionalProperties": False}


TOOLS = [
    {'name':'read_attachment_image','description':'读取当前会话中已分享或钉选图片的真实像素，或读取其中一份 PDF 的单个指定页（page 从 0 开始）。返回图像内容块及精确来源/页码元数据；GIF 仅返回静态首帧预览。绝不读取任意主机路径。（向用户描述画面时只陈述实际见到的内容，并保持祥子自然清亮的口吻。）',
     'inputSchema':schema({'artifact_id':ARTIFACT_ID,'page':{'type':'integer','minimum':0,'maximum':1000000}},['artifact_id'])},
    {"name": "read_attachment_excerpt", "description": '读取当前会话中已分享或显式钉选附件的受限页码或片段文本（支持 offset、从 0 开始的 page 及 4–32000 范围的 limit）。绝不读取任意主机文件；摘录不等于已阅全文，转述时需区分已读片段与未读范围。',
     "inputSchema": schema({"artifact_id": ARTIFACT_ID, "offset": {"type": "integer", "minimum": 0},
                            "page": {"type": "integer", "minimum": 0}, "limit": {"type": "integer", "minimum": 4, "maximum": 32000}}, ["artifact_id"])},
    {"name": "search_attachment_text", "description": '在已分享的文本、代码或日志附件中搜索字面匹配内容；返回受限上下文片段及续读偏移量（offset）。绝不编造未命中的结果，也不要把片段命中说成已经通读整份文件。',
     "inputSchema": schema({"artifact_id": ARTIFACT_ID, "query": {"type": "string", "minLength": 1, "maxLength": 200},
                            "offset": {"type": "integer", "minimum": 0}, "limit": {"type": "integer", "minimum": 1, "maximum": 100}}, ["artifact_id", "query"])},
    {"name": "create_text_artifact", "description": '新建并自动交付 1 份全新的文本、文档或源代码文件，内容不超过 1 MiB UTF-8。请使用安全的基础文件名（如 report.md）。绝不覆写或执行文件；每轮最多输出 64 份。交付成功后文件已直达客户端，回答时用自然话语通知对方查看即可，不必念出内部规则。',
     "inputSchema": schema({"name": {"type": "string", "minLength": 1, "maxLength": 180},
                            "content": {"type": "string", "maxLength": 1048576}}, ["name", "content"])},
    {'name': 'create_interactive_card',
     'description': '为声明支持 native-cards-v1 的客户端新建并自动交付原生记忆闪卡组或单选决策投票卡。须使用全新的 .hajicard.json 基础文件名。flashcards 需提供 1–20 组包含 front/back Markdown 的卡片；poll 需提供 1 个问题及 2–12 个互不相同的选项字符串。绝不执行脚本。翻面状态由客户端自行维护；投票按配对设备保存，改选会覆盖原投票。',
     'inputSchema': schema({'name': NAME, 'card': schema({
         'kind': {'type': 'string', 'enum': ['flashcards', 'poll']},
         'title': {'type': 'string', 'minLength': 1, 'maxLength': 160},
         'cards': {'type': 'array', 'minItems': 1, 'maxItems': 20,
                   'items': schema({'front': {'type': 'string', 'minLength': 1, 'maxLength': 2000},
                                    'back': {'type': 'string', 'minLength': 1, 'maxLength': 2000}}, ['front', 'back'])},
         'question': {'type': 'string', 'maxLength': 2000},
         'options': {'type': 'array', 'minItems': 2, 'maxItems': 12, 'uniqueItems': True,
                     'items': {'type': 'string', 'minLength': 1, 'maxLength': 300}}
     }, ['kind', 'title'])}, ['name', 'card'])},
    {"name":"create_pdf_artifact", "description":'基于 Markdown 标题、段落、列表、代码块与表格生成并自动交付真实的分页 PDF 文本报告。须使用 .pdf 基础文件名，输入不超过 1 MiB UTF-8，上限 100 页。暂不支持嵌入媒体图像，数学公式按源码文本保留；绝不覆写或执行模型代码。',
     "inputSchema":schema({"name":NAME,"title":{"type":"string","minLength":1,"maxLength":200},
                           "markdown":{"type":"string","maxLength":1048576}},["name","title","markdown"])},
    {"name":"create_spreadsheet_artifact", "description":'生成并自动交付真实的 .xlsx 工作簿，上限 12 张工作表、10000 个单元格与 1 MiB 输入。须先单独声明列头（columns），再传数据行（rows）。字符串按字面值原样保留（含 = 开头的内容），单元格不会执行公式或宏；超长编号或超出 Excel 数值精度范围的数字请传为字符串。',
     "inputSchema":schema({"name":NAME,"sheets":{"type":"array","minItems":1,"maxItems":12,
         "items":schema({"name":{"type":"string","minLength":1,"maxLength":31},
                         "columns":{"type":"array","minItems":1,"maxItems":32,"items":{"type":"string","minLength":1,"maxLength":100}},
                         "rows":{"type":"array","maxItems":1000,"items":{"type":"array","maxItems":32,"items":CELL}}},["name","columns"])}},["name","sheets"])},
    {"name":"create_zip_artifact", "description":'根据当前会话中已分享、已钉选或本轮新生成的显式 artifact_id 列表，打包并自动交付真实的 ZIP 压缩包。最多 64 份原件，总容量上限 64 MiB。保留原文件字节，重名文件会分入带编号的子目录；不把其他压缩包作为原件嵌入，也不会读取任意主机路径。',
     "inputSchema":schema({"name":NAME,"artifact_ids":{"type":"array","minItems":1,"maxItems":64,"uniqueItems":True,"items":ARTIFACT_ID}},["name","artifact_ids"])},
    {"name": "deliver_file_to_phone", "description": '使用相对文件名，从本轮受管输出目录中交付已经完成的文件到用户客户端。',
     "inputSchema": schema({"path": PATH}, ["path"])},
    {"name": "deliver_file_to_client", "description": 'deliver_file_to_phone 面向当前已连接客户端的别名，作用与路径限制完全一致。',
     "inputSchema": schema({"path": PATH}, ["path"])},
    {"name": "deliver_image_to_phone", "description": '使用相对文件名，从本轮受管输出目录中交付已经完成的 PNG、JPEG、GIF 或 WebP 原图文件。',
     "inputSchema": schema({"path": PATH}, ["path"])},
    {"name": "deliver_image_to_client", "description": 'deliver_image_to_phone 面向当前已连接客户端的别名，作用与格式限制完全一致。',
     "inputSchema": schema({"path": PATH}, ["path"])},
    {"name": "deliver_interactive_card", "description": '使用相对文件名，从本轮受管输出目录中交付已经完成的互动文档。客户端决定是否启用沙盒预览；本工具绝不执行文档中的脚本。',
     "inputSchema": schema({"path": PATH}, ["path"])},
    {"name": "deliver_interactive_card_to_client", "description": 'deliver_interactive_card 面向当前已连接客户端的别名，作用与安全限制完全一致。',
     "inputSchema": schema({"path": PATH}, ["path"])},
    {"name": "send_progress_note", "description": '向用户递一张简短公开的进展小纸条（1–1000 字符，通常一句、四十字以内就好，客户端会把它显示成她夹在信里的便笺）。必须用丰川祥子自己干净、自然的中文口吻直接告知现在核对到哪一步、接下来准备做什么；绝不写入私密隐藏推理、长段脚本，也不要出现工具函数名或后台流水账。',
     "inputSchema": schema({"text": {"type": "string", "minLength": 1, "maxLength": 1000}}, ["text"])},
]


def grant() -> tuple[str, str, int]:
    global TOOL_PROFILE
    grant_file = os.environ.get("HAJI_AGENT_GRANT_FILE")
    if grant_file:
        path = Path(grant_file).expanduser()
        if not path.is_file() or path.stat().st_size > 8192:
            raise ValueError("Invalid private agent grant file.")
        payload = json.loads(path.read_text(encoding="utf-8"))
        version = payload.get('tool_profile',2)
        if type(version) is not int or version not in {2,3,4}:
            raise ValueError('Unsupported private tool profile.')
        TOOL_PROFILE = version
        token, run_id, port = payload.get("token", ""), payload.get("run_id", ""), payload.get("port", 8765)
    else:
        token, run_id, port = os.environ.get("HAJI_AGENT_TOKEN", ""), os.environ.get("HAJI_RUN_ID", ""), os.environ.get("HAJI_PORT", "8765")
    if not isinstance(token, str) or not re.fullmatch(r"[A-Za-z0-9_-]{64}", token):
        raise ValueError("A private run-scoped agent grant is required.")
    if not isinstance(run_id, str) or not re.fullmatch(r"[0-9a-f]{32}", run_id):
        raise ValueError("A gateway run identifier is required.")
    if isinstance(port, bool) or not 1 <= int(port) <= 65535:
        raise ValueError("Invalid local gateway port.")
    os.environ.pop("HAJI_AGENT_TOKEN", None)
    return token, run_id, int(port)


def tools_for_profile(version: int) -> list[dict]:
    # Legacy live hosts issue versionless grants. Keep their exact older tool
    # catalog until that host explicitly opts into the image-capable profile.
    return [tool for tool in TOOLS
            if (version >= 3 or tool['name'] != 'read_attachment_image')
            and (version >= 4 or tool['name'] != 'create_interactive_card')]


def active_tools() -> list[dict]:
    return tools_for_profile(TOOL_PROFILE)


def tool_call(name: str, arguments: dict, token: str, run_id: str, port: int, opener) -> dict:
    definition = next((tool for tool in active_tools() if tool["name"] == name), None)
    if definition is None or not isinstance(arguments, dict):
        raise ValueError("Unknown tool or invalid arguments.")
    shape = definition["inputSchema"]
    if not set(shape["required"]).issubset(arguments) or set(arguments) - set(shape["properties"]):
        raise ValueError("Tool argument names are invalid.")
    routes = {"read_attachment_excerpt": "read-attachment-excerpt", "search_attachment_text": "search-attachment-text",
              'read_attachment_image':'read-attachment-image',
              "create_text_artifact": "create-text-artifact", "send_progress_note": "progress",
              'create_interactive_card': 'create-interactive-card',
              "create_pdf_artifact":"create-pdf-artifact", "create_spreadsheet_artifact":"create-spreadsheet-artifact",
              "create_zip_artifact":"create-zip-artifact"}
    if name in routes:
        route, payload = routes[name], arguments
    else:
        kind = "image" if name.startswith("deliver_image") else "interactive" if name.startswith("deliver_interactive") else "file"
        route, payload = "deliver", {"path": arguments["path"], "kind": kind}
    call = urllib.request.Request(f"http://127.0.0.1:{port}/internal/agent/{run_id}/{route}",
        data=json.dumps(payload, ensure_ascii=False).encode("utf-8"),
        headers={"Content-Type": "application/json", "X-Haji-Agent": token})
    try:
        with opener.open(call, timeout=300) as response:
            data = response.read(MAX_LINE + 1)
            if len(data) > MAX_LINE:
                raise ValueError("Gateway result exceeds the bounded bridge response size.")
            result = json.loads(data)
        if name == 'read_attachment_image':
            image_data = result.pop('image_base64',None)
            result.pop('placeholder_base64',None)
            result.pop('thumbhash',None)
            mime = result.get('mime')
            if not isinstance(image_data,str) or len(image_data)>4*1024**2 or mime not in {'image/png','image/jpeg','image/webp'}:
                raise ValueError('The image result is incomplete.')
            return {'content':[{'type':'text','text':json.dumps(result,ensure_ascii=False)},
                               {'type':'image','mimeType':mime,'data':image_data}]}
        return {"content": [{"type": "text", "text": json.dumps(result, ensure_ascii=False)}]}
    except urllib.error.HTTPError as exc:
        try:
            detail = json.loads(exc.read(8192)).get("detail", "这一次工具操作暂时没有完成。")
        except (ValueError, UnicodeError):
            detail = "这一次工具操作暂时没有完成。"
        return {"isError": True, "content": [{"type": "text", "text": str(detail)[:2000]}]}
    except (urllib.error.URLError, TimeoutError):
        return {"isError": True, "content": [{"type": "text", "text": "与主机工具的连接暂时中断，请保留当前进展。"}]}


def respond(response: dict) -> None:
    sys.stdout.buffer.write((json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8"))
    sys.stdout.buffer.flush()


def main() -> None:
    try:
        token, run_id, port = grant()
    except (OSError, ValueError, TypeError):
        raise SystemExit("The private run-scoped bridge grant is missing or invalid.") from None
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
    while line := sys.stdin.buffer.readline(MAX_LINE + 1):
        if len(line) > MAX_LINE:
            while line and not line.endswith(b"\n"):
                line = sys.stdin.buffer.readline(65536)
            respond({"jsonrpc": "2.0", "id": None, "error": {"code": -32700, "message": "MCP request exceeds the input limit."}})
            continue
        request = {}
        try:
            request = json.loads(line)
            if not isinstance(request, dict) or request.get("jsonrpc") != "2.0":
                raise ValueError("Invalid JSON-RPC envelope.")
            ident = request.get("id")
            method = request.get("method")
            if ident is None:
                continue
            if method == "initialize":
                offered = request.get("params", {}).get("protocolVersion")
                version = offered if offered in {"2024-11-05", "2025-03-26", "2025-06-18", "2025-11-25"} else "2024-11-05"
                result = {"protocolVersion": version, "capabilities": {"tools": {}},
                          "serverInfo": {"name": "hajisaki-engineering", "version": "0.3.0" if TOOL_PROFILE>=3 else "0.2.0"}}
            elif method == "ping":
                result = {}
            elif method == "tools/list":
                result = {"tools": active_tools()}
            elif method == "tools/call":
                params = request.get("params", {})
                result = tool_call(params.get("name"), params.get("arguments", {}), token, run_id, port, opener)
            else:
                response = {"jsonrpc": "2.0", "id": ident, "error": {"code": -32601, "message": "Method not found"}}
                respond(response)
                continue
            response = {"jsonrpc": "2.0", "id": ident, "result": result}
        except Exception:
            response = {"jsonrpc": "2.0", "id": request.get("id") if isinstance(locals().get("request"), dict) else None,
                        "error": {"code": -32603, "message": "Bridge request could not be completed"}}
        respond(response)


if __name__ == "__main__":
    main()
