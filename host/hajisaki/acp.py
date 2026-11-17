"""Native Antigravity CLI harness over ACP, with additive app delivery tools."""
from __future__ import annotations

import argparse
import asyncio
import base64
import hashlib
import ipaddress
import json
import mimetypes
import os
import re
from pathlib import Path
import subprocess
import sys
import threading
from typing import Any, Callable
from urllib.parse import urlsplit

from .config import secure_data_directory
from .diagnostics import PublicTextRouter
from .bridge import tools_for_profile


class AcpError(RuntimeError):
    def __init__(self, code: int, message: str):
        super().__init__(message)
        self.code = code


class AcpClient:
    """An ACP client of the signed CLI, never a replacement model/agent loop.

    Native tools execute in Antigravity. The user's Turbo setting enables the
    CLI's automatic approvals; otherwise only scoped reads/delivery are approved.
    """

    def __init__(self, executable: Path, data_dir: Path, *, proxy_url: str | None = None,
                 bridge_grant: Path | None = None, additional_dirs: tuple[Path, ...] = (), turbo: bool = False):
        self.executable = executable.resolve()
        self.data_dir = secure_data_directory(data_dir)
        self.proxy_url = proxy_url
        self.additional_dirs = tuple(path.resolve() for path in additional_dirs)
        if proxy_url:
            parsed = urlsplit(proxy_url)
            local = parsed.hostname == "localhost"
            try:
                local = local or ipaddress.ip_address(parsed.hostname or "").is_loopback
            except ValueError:
                pass
            if not local or parsed.scheme not in {"http", "https"} or not parsed.port:
                raise ValueError("ACP diagnostics require a loopback HTTP(S) proxy with an explicit port.")
        self.policy = {}  # Native CLI flags govern execution permissions.
        self.turbo = turbo
        self.profile_name = "antigravity-cli"
        self.mcp_servers: list[dict] = []
        self.bridge_tools: list[dict] = []
        if bridge_grant is not None:
            interpreter = Path(sys.executable)
            if os.name == "nt":
                interpreter = interpreter.with_name("pythonw.exe")
            if not interpreter.is_file() or not bridge_grant.is_file():
                raise ValueError("The delivery bridge needs its own interpreter and private run grant.")
            self.mcp_servers = [{"name": "hajisaki", "command": str(interpreter),
                "args": ["-u", str(Path(__file__).with_name("bridge.py"))],
                "env": [{"name": "HAJI_AGENT_GRANT_FILE", "value": str(bridge_grant.resolve())}]}]
            if bridge_grant.stat().st_size > 8192:
                raise ValueError('The delivery bridge grant is too large.')
            profile = json.loads(bridge_grant.read_text(encoding='utf-8')).get('tool_profile', 2)
            if type(profile) is not int or profile not in {2, 3, 4}:
                raise ValueError('Unsupported delivery bridge profile.')
            self.bridge_tools = tools_for_profile(profile)
        self.process: subprocess.Popen | None = None
        self.loop: asyncio.AbstractEventLoop | None = None
        self.reader: threading.Thread | None = None
        self.pending: dict[int, asyncio.Future] = {}
        self.serial = 0
        self.write_lock = threading.Lock()
        self.log = None
        self.capabilities: dict | None = None
        self.server_requests: list[str] = []
        self.notifications: list[str] = []
        self.on_update: Callable[[dict], None] | None = None
        self.active_session: str | None = None
        self.tool_violation = False
        self.control_tasks: set[asyncio.Task] = set()
        self.cancel_requested = False
        self.user_text = ''
        self.text_router: PublicTextRouter | None = None
        self.tool_calls: list[dict] = []
        self.permission_requests: list[dict] = []
        self.available_commands: dict[str,list[dict]] = {}
        self.session_usage: dict[str,dict] = {}
        self.commands_changed = asyncio.Event()
        self.usage_changed = asyncio.Event()
        self.update_counts: dict[str,int] = {}
        self.update_fields: dict[str,list[str]] = {}
        self.result_shape: dict = {}

    async def start(self) -> None:
        if self.process is not None:
            raise RuntimeError("This ACP transport is already started.")
        self.loop = asyncio.get_running_loop()
        workspace = self.data_dir / "workspace"
        workspace.mkdir(exist_ok=True)
        native_settings = Path.home() / '.gemini/antigravity-cli/settings.json'
        args = [str(self.executable)]
        if native_settings.is_file():
            settings = json.loads(native_settings.read_text(encoding='utf-8'))
            if settings.get('useG1Credits') is True or settings.get('modelProvider'):
                raise AcpError(-32600, 'Native CLI mode requires the existing Antigravity account without extra credits or a replacement model provider.')
            # Let the CLI load its own ordinary settings file, without copying
            # credentials or replacing its prompt/tool configuration.
            args += ['--settings', str(native_settings)]
        args += ["acp", "--stdio", "--disable-telemetry", "--include-default-customizations=true",
                 "--app-data-dir", "hajisaki-acp", "--log-file", str(self.data_dir / "server.log")]
        if self.turbo:
            args.append('--dangerously-skip-permissions')
        for directory in self.additional_dirs:
            args += ['--add-dir', str(directory)]
        # Keep the existing native trajectory store so old sessions remain
        # loadable. Do not load the former gateway-tools-* restriction profiles.
        environment = dict(os.environ)
        for name in ("GEMINI_API_KEY", "GOOGLE_API_KEY", "GOOGLE_GENAI_USE_VERTEXAI"):
            environment.pop(name, None)
        if self.proxy_url:
            environment.update(HTTP_PROXY=self.proxy_url, HTTPS_PROXY=self.proxy_url,
                               ALL_PROXY=self.proxy_url, NO_PROXY="localhost,127.0.0.1,::1")
        self.log = (self.data_dir / "stderr.log").open("ab")
        try:
            self.process = subprocess.Popen(args, cwd=workspace, env=environment, stdin=subprocess.PIPE,
                stdout=subprocess.PIPE, stderr=self.log, shell=False,
                creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
        except BaseException:
            self.log.close()
            self.log = None
            raise
        self.reader = threading.Thread(target=self._read, name="hajisaki-acp-reader", daemon=True)
        self.reader.start()

    def _native_read_allowed(self, call: dict) -> bool:
        """Approve only a native read already within the user's task authority."""
        if call.get('kind') != 'read' or str(call.get('name', '')).lower().startswith('mcp'):
            return False
        arguments = call.get('args')
        paths = []
        if isinstance(arguments, dict):
            for key in ('Path', 'path', 'file_path', 'filePath', 'absolutePath', 'TargetFile', 'target_file'):
                if isinstance(arguments.get(key), str):
                    paths.append(arguments[key])
        if not paths:
            locations = call.get('locations', [])
            if isinstance(locations, list):
                paths = [item['path'] for item in locations if isinstance(item, dict) and isinstance(item.get('path'), str)]
        if not paths or len(paths) > 16:
            return False
        workspace = (self.data_dir / 'workspace').resolve()
        user_text = self.user_text.replace('\\', '/').casefold()
        try:
            for value in paths:
                if value.startswith(('\\\\', '//')) or '://' in value:
                    return False
                path = Path(value)
                path = (path if path.is_absolute() else workspace / path).resolve()
                if str(path).startswith('\\\\'):
                    return False
                in_workspace = path.is_relative_to(workspace) or any(path.is_relative_to(root) for root in self.additional_dirs)
                mention = re.escape(path.as_posix().casefold())
                explicitly_requested = re.search(r'(?<![a-z0-9_.:/-])' + mention + r'(?![a-z0-9_.:/-])', user_text) is not None
                if not in_workspace and not explicitly_requested:
                    return False
            return True
        except (OSError, ValueError):
            return False

    def _read(self) -> None:
        try:
            while self.process and self.process.stdout:
                line = self.process.stdout.readline(4 * 1024**2)
                if not line:
                    break
                if len(line) >= 4 * 1024**2:
                    self.loop.call_soon_threadsafe(self._fail, AcpError(-32603, "ACP response exceeded the transport limit."))
                    return
                try:
                    value = json.loads(line)
                except (ValueError, UnicodeError):
                    continue
                self.loop.call_soon_threadsafe(self._receive, value)
        finally:
            if self.loop and not self.loop.is_closed():
                self.loop.call_soon_threadsafe(self._fail, AcpError(-32099, "ACP transport closed."))

    def _fail(self, error: Exception) -> None:
        for future in tuple(self.pending.values()):
            if not future.done():
                future.set_exception(error)
        self.pending.clear()

    def _write(self, value: dict) -> None:
        if not self.process or self.process.poll() is not None or not self.process.stdin:
            raise AcpError(-32099, "ACP transport is not running.")
        payload = (json.dumps(value, ensure_ascii=False, separators=(",", ":")) + "\n").encode("utf-8")
        with self.write_lock:
            self.process.stdin.write(payload)
            self.process.stdin.flush()

    def _receive(self, value: Any) -> None:
        if not isinstance(value, dict) or value.get("jsonrpc") != "2.0":
            return
        method, ident = value.get("method"), value.get("id")
        if method is not None:
            if ident is None:
                if len(self.notifications) < 100:
                    self.notifications.append(str(method))
                if method == "session/update":
                    params = value.get("params", {})
                    update = params.get("update", {})
                    kind = update.get("sessionUpdate")
                    if self.on_update and isinstance(kind,str) and len(self.update_counts)<50:
                        self.update_counts[kind]=self.update_counts.get(kind,0)+1
                        # Record schema only. Thought bodies and arbitrary values
                        # never enter diagnostic events or the public transcript.
                        self.update_fields[kind]=[str(key)[:64] for key in list(update)[:30] if key not in {'content','rawInput','rawOutput'}]
                    if kind=='available_commands_update' and isinstance(params.get('sessionId'),str):
                        commands=update.get('availableCommands',[])
                        if isinstance(commands,list):
                            self.available_commands[params['sessionId']]=[
                                {'name':item['name'][:120],'description':str(item.get('description',''))[:1000]}
                                for item in commands[:100] if isinstance(item,dict) and isinstance(item.get('name'),str)]
                            self.commands_changed.set()
                    if kind=='usage_update' and isinstance(params.get('sessionId'),str):
                        self.session_usage[params['sessionId']]={key:update[key] for key in ('used','size') if type(update.get(key)) is int}
                        self.usage_changed.set()
                    if params.get("sessionId") == self.active_session and self.on_update:
                        # Private thought chunks never enter logs, events, or the phone stream.
                        if kind == "agent_thought_chunk":
                            return
                        if kind in {"tool_call", "tool_call_update"}:
                            # Native tool calls belong to Antigravity's harness.
                            # Forward bounded metadata without replacing their
                            # execution loop or copying raw inputs/outputs.
                            if kind == "tool_call" and len(self.tool_calls) < 100:
                                self.tool_calls.append({"id": str(update.get("toolCallId", ""))[:150],
                                    "title": str(update.get("title", ""))[:150]})
                            self.on_update({"kind": "native_tool", "id": str(update.get("toolCallId", ""))[:150],
                                            "tool_kind": str(update.get("kind", "other"))[:40],
                                            "status": str(update.get("status", "in_progress"))[:40]})
                        elif kind == "agent_message_chunk":
                            content = update.get("content", {})
                            if content.get("type") == "text":
                                if self.text_router:
                                    self.text_router.feed(content.get("text", ""))
                        elif kind == "usage_update":
                            self.on_update({"kind": "usage", "usage": update})
                return
            if len(self.server_requests) < 100:
                self.server_requests.append(str(method))
            if method == "session/request_permission":
                params = value.get("params", {})
                if not isinstance(params, dict):
                    params = {}
                call = params.get("toolCall", {})
                if not isinstance(call, dict):
                    call = {}
                options = params.get("options", [])
                if not isinstance(options, list):
                    options = []
                options = [item for item in options if isinstance(item, dict)]
                definition = next((tool for tool in self.bridge_tools if call.get("name") == "mcp_hajisaki_" + tool["name"]), None)
                arguments = call.get("args")
                option = next((item for item in options if item.get("kind") == "allow_once"
                               and isinstance(item.get("optionId"), str) and item["optionId"]), None)
                if self.turbo and option is None:
                    option = next((item for item in options if item.get('kind') == 'allow_always'
                                   and isinstance(item.get('optionId'), str) and item['optionId']), None)
                owned_tool = bool(self.mcp_servers and definition
                    and call.get("kind") == "other" and isinstance(arguments, dict)
                    and set(definition["inputSchema"]["required"]).issubset(arguments)
                    # The installed ACP server adds its own display-only toolSummary.
                    # It is not a tool capability; bridge input validation remains strict.
                    and not set(arguments) - set(definition["inputSchema"]["properties"]) - {"toolSummary"})
                native_read = self._native_read_allowed(call)
                allowed = bool(self.active_session and self.on_update and not self.cancel_requested
                    and params.get('sessionId') == self.active_session and option and (self.turbo or owned_tool or native_read))
                if len(self.permission_requests) < 100:
                    metadata = call.get("_meta", {})
                    if not isinstance(metadata, dict):
                        metadata = {}
                    self.permission_requests.append({
                        "parameter_keys": list(params), "tool_keys": list(call),
                        "name": str(call.get("name", ""))[:200], "allowed": allowed,
                        "authorization_basis": 'user_enabled_turbo' if self.turbo else 'app_delivery_tool' if owned_tool else 'authorized_native_read' if native_read else 'requires_user_consent',
                        "argument_keys": list(arguments) if isinstance(arguments, dict) else [],
                        "title": str(call.get("title", ""))[:200], "kind": call.get("kind"),
                        "metadata": {key: str(metadata[key])[:200] for key in
                            ("server", "serverName", "toolName", "name", "permissionResource") if key in metadata},
                        "options": [{"optionId": item.get("optionId"), "kind": item.get("kind")}
                                    for item in options],
                    })
                outcome = {"outcome": "selected", "optionId": option["optionId"]} if allowed else {"outcome": "cancelled"}
                self._write({"jsonrpc": "2.0", "id": ident, "result": {"outcome": outcome}})
                if self.active_session and not allowed:
                    if self.on_update:
                        self.on_update({"kind": "permission_required", "title": str(call.get("title", ""))[:150]})
                    # Decline this unconfirmed operation through ACP, without
                    # cancelling the whole native agent turn or deleting tools.
            else:
                self._write({"jsonrpc": "2.0", "id": ident,
                             "error": {"code": -32601, "message": "Client capability is disabled."}})
            return
        future = self.pending.pop(ident, None)
        if future is None or future.done():
            return
        if "error" in value:
            error = value["error"]
            future.set_exception(AcpError(error.get("code", -32603), str(error.get("message", "ACP request failed."))))
        else:
            future.set_result(value.get("result"))

    async def _request(self, method: str, params: dict) -> dict:
        if method not in {"initialize", "session/new", "session/close", "session/load", "session/prompt", "session/set_config_option"}:
            raise AcpError(-32601, "This method is disabled by the restricted client.")
        self.serial += 1
        ident = self.serial
        future = asyncio.get_running_loop().create_future()
        self.pending[ident] = future
        try:
            await asyncio.to_thread(self._write, {"jsonrpc": "2.0", "id": ident, "method": method, "params": params})
            return await future
        finally:
            self.pending.pop(ident, None)

    async def initialize(self) -> dict:
        result = await self._request("initialize", {
            "protocolVersion": 1,
            "clientInfo": {"name": "hajisaki", "title": "HajiSaki", "version": "0.1.0"},
            "clientCapabilities": {"fs": {"readTextFile": False, "writeTextFile": False}, "terminal": False},
        })
        if not isinstance(result, dict) or result.get("protocolVersion") != 1:
            raise AcpError(-32603, "ACP did not negotiate supported protocol version 1.")
        self.capabilities = result
        return result

    async def session_configuration(self) -> dict:
        if not self.capabilities:
            raise AcpError(-32600, "Initialize before requesting session configuration.")
        if not self.proxy_url:
            raise AcpError(-32600, "A host proxy is required before requesting account configuration.")
        result = await self._request("session/new", {"cwd": str(self.data_dir / "workspace"), "mcpServers": []})
        session_id = result.get("sessionId")
        if session_id:
            await self._request("session/close", {"sessionId": session_id})
            result['availableCommands']=self.available_commands.get(session_id,result.get('availableCommands',[]))
        return result

    async def open_session(self, previous: str | None = None) -> dict:
        if not self.capabilities or not self.proxy_url:
            raise AcpError(-32600, "Initialize and configure the host proxy before opening a session.")
        params = {"cwd": str(self.data_dir / "workspace"), "mcpServers": self.mcp_servers}
        if previous:
            params["sessionId"] = previous
        result = await self._request("session/load" if previous else "session/new", params)
        self.active_session = previous or result["sessionId"]
        return {**result, "sessionId": self.active_session}

    async def configure(self, configuration: dict, model: str = "default", effort: str = "medium") -> dict:
        if model == 'default':
            return configuration  # Inherit the CLI's model and its thinking level together.
        options = configuration.get("configOptions", [])
        if model != "default":
            grouped = next((option for option in options if option["id"] == "model"), None)
            values = []
            for item in grouped.get("options", []) if grouped else []:
                values.extend(item.get("options", [item]))
            selected = model
            allowed = {item["value"] for item in values}
            if selected not in allowed:
                suffix = "-" + effort
                if selected.endswith(suffix) and selected[:-len(suffix)] in allowed:
                    selected = selected[:-len(suffix)]
                else:
                    raise AcpError(-32602, "This model is not in the negotiated ACP configuration.")
            configuration = await self._request("session/set_config_option", {"sessionId": self.active_session, "configId": "model", "value": selected})
            options = configuration.get("configOptions", [])
        thinking = next((option for option in options if option["id"] == "thought_level"), None)
        if thinking:
            if effort not in {item["value"] for item in thinking.get("options", [])}:
                raise AcpError(-32602, "This thinking level is not available for the selected model.")
            if thinking.get("currentValue") != effort:
                configuration = await self._request("session/set_config_option", {"sessionId": self.active_session, "configId": "thought_level", "value": effort})
        return configuration

    async def supports_compact(self) -> bool:
        if self.active_session not in self.available_commands:
            try:await asyncio.wait_for(self.commands_changed.wait(),timeout=2)
            except TimeoutError:return False
        return any(item['name']=='compact' for item in self.available_commands.get(self.active_session,[]))

    async def compact(self, on_update: Callable[[dict], None], *, before_hint: int | None = None) -> dict:
        """Invoke only the agent's explicitly advertised built-in compact action."""
        if not await self.supports_compact():
            raise AcpError(-32601,'The agent has not advertised context compaction.')
        before = self.session_usage.get(self.active_session,{}).get('used',before_hint)
        self.usage_changed.clear()
        result = await self.prompt([{'type':'text','text':'/compact'}],on_update,user_text='/compact')
        if not self.usage_changed.is_set():
            try:await asyncio.wait_for(self.usage_changed.wait(),timeout=2)
            except TimeoutError:pass
        after = self.session_usage.get(self.active_session,{}).get('used')
        return {'result':result,'tokens_before':before,'tokens_after':after}

    def cancel(self) -> None:
        if self.active_session and self.process and self.process.poll() is None and not self.cancel_requested:
            self.cancel_requested = True
            task = asyncio.create_task(asyncio.to_thread(self._write, {
                "jsonrpc": "2.0", "method": "session/cancel", "params": {"sessionId": self.active_session}}))
            self.control_tasks.add(task)
            def completed(done):
                self.control_tasks.discard(done)
                if not done.cancelled():
                    done.exception()
            task.add_done_callback(completed)

    async def prompt(self, content: list[dict], on_update: Callable[[dict], None], *, user_text: str | None = None) -> dict:
        if not self.active_session or not self.proxy_url:
            raise AcpError(-32600, "Open a proxied session before sending inline content.")
        capabilities = self.capabilities.get("agentCapabilities", {}).get("promptCapabilities", {})
        for item in content:
            kind = item.get("type")
            allowed = kind == "text" or (kind == "image" and capabilities.get("image"))
            allowed = allowed or (kind == "resource" and capabilities.get("embeddedContext") and "text" in item.get("resource", {}))
            if not allowed:
                raise AcpError(-32602, "This content type is not enabled for the restricted session.")
        if len(json.dumps(content, ensure_ascii=False).encode("utf-8")) > 24 * 1024**2:
            raise AcpError(-32602, "Inline content exceeds the current 24MiB transport bound.")
        self.on_update, self.tool_violation, self.cancel_requested = on_update, False, False
        self.tool_calls = []
        self.update_counts = {};self.update_fields={};self.result_shape={}
        if user_text is None:
            user_text = "\n".join(item.get("text", "") for item in content if item.get("type") == "text")
        self.user_text = user_text
        self.text_router = PublicTextRouter(
            lambda text: on_update({"kind": "reply_delta", "text": text}),
            lambda raw: on_update({"kind": "provider_diagnostic", "raw_text": raw}), user_text,
        )
        try:
            result = await self._request("session/prompt", {"sessionId": self.active_session, "prompt": content})
            self.result_shape={'keys':[str(key)[:64] for key in list(result)[:30]]}
            if isinstance(result.get('_meta'),dict):
                self.result_shape['meta_keys']=[str(key)[:64] for key in list(result['_meta'])[:30]]
                for key,value in result['_meta'].items():
                    if isinstance(value,dict):self.result_shape[str(key)[:64]+'_keys']=[str(name)[:64] for name in list(value)[:30]]
            if self.tool_violation:
                raise AcpError(-32010, "The session attempted an operation outside its allowed tools; the request was cancelled.")
            if self.text_router.fatal_schema_error:
                raise AcpError(-32602, 'The provider rejected the card tool schema; the original response is retained as a diagnostic.')
            return result
        except asyncio.CancelledError:
            self.cancel()
            raise
        finally:
            self.text_router.finish()
            self.text_router = None
            self.on_update = None
            self.user_text = ''

    async def close(self) -> None:
        """Close an initialization-only transport; no model turn is submitted."""
        process = self.process
        if process and process.poll() is None:
            if process.stdin:
                process.stdin.close()
            try:
                await asyncio.to_thread(process.wait, 5)
            except subprocess.TimeoutExpired:
                process.terminate()
                await asyncio.to_thread(process.wait)
        if self.reader:
            await asyncio.to_thread(self.reader.join, 2)
        if self.log:
            self.log.close()
            self.log = None
        self._fail(AcpError(-32099, "ACP diagnostic transport closed."))


def fingerprint(path: Path) -> dict:
    if not path.is_file():
        return {"exists": False}
    data = path.read_bytes()
    return {"exists": True, "sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}


async def inspect(args: argparse.Namespace) -> dict:
    global_settings = Path.home() / ".gemini/antigravity-cli/settings.json"
    before = fingerprint(global_settings)
    client = AcpClient(Path(args.executable), Path(args.data_dir), proxy_url=args.proxy,
                       bridge_grant=Path(args.bridge_grant) if args.bridge_grant else None)
    try:
        await client.start()
        negotiated = await client.initialize()
        result = {"negotiated": negotiated, "model_prompt_submitted": False,
                  "permission_policy_requested": client.policy, "effective_permission_policy_verified": False,
                  "isolated_profile": False, "native_settings_inherited": True,
                  "conversation_storage_root": "hajisaki-acp",
                  "native_harness": True, "default_customizations_included": True,
                  "server_requests": client.server_requests, "notifications": client.notifications}
        if args.session and not args.prompt_file:
            try:
                configuration = await client.open_session(args.session)
                await asyncio.sleep(0.15)  # Allow already-dispatched metadata notifications to arrive.
                configuration['availableCommands']=client.available_commands.get(args.session,configuration.get('availableCommands',[]))
                result['session_configuration']=configuration
            except AcpError as exc:
                result['session_configuration_error']={'code':exc.code,'message':str(exc)}
        elif args.session_config:
            try:
                result["session_configuration"] = await client.session_configuration()
            except AcpError as exc:
                result["session_configuration_error"] = {"code": exc.code, "message": str(exc)}
        if args.prompt_file:
            configuration = await client.open_session(args.session)
            (client.data_dir / "active-session.json").write_text(json.dumps({"sessionId": client.active_session}), encoding="utf-8")
            await client.configure(configuration, args.model, args.effort)
            content = [{"type": "text", "text": Path(args.prompt_file).read_text(encoding="utf-8")}]
            if args.image:
                path = Path(args.image)
                content.append({"type": "image", "mimeType": mimetypes.guess_type(path.name)[0] or "image/png",
                                "data": base64.b64encode(path.read_bytes()).decode("ascii")})
            updates = []
            def collect(update):
                updates.append(update)
                with (client.data_dir / "reply-events.jsonl").open("a", encoding="utf-8") as stream:
                    stream.write(json.dumps(update, ensure_ascii=False) + "\n")
            result["model_prompt_submitted"] = True
            result["session_id"] = client.active_session
            result["prompt_result"] = await client.prompt(content, collect)
            result["public_updates"] = updates
            result["unexpected_tool_attempt"] = client.tool_violation
            await client._request("session/close", {"sessionId": client.active_session})
    finally:
        await client.close()
    result["global_settings_content_unchanged"] = before == fingerprint(global_settings)
    destination = Path(args.output_file).resolve() if args.output_file else Path(args.data_dir).resolve() / "capabilities.json"
    destination.write_text(json.dumps(result, ensure_ascii=False, indent=2), encoding="utf-8")
    return result


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--executable", default=str(Path.home() / "AppData/Local/agy/bin/agy.exe"))
    parser.add_argument("--data-dir", required=True)
    parser.add_argument("--proxy")
    parser.add_argument("--session-config", action="store_true", help="Create and close one empty session to inspect account config; never submit a model prompt.")
    parser.add_argument("--prompt-file", help="Send a real inline-only request from this UTF-8 file.")
    parser.add_argument("--image", help="An existing image explicitly selected for the request.")
    parser.add_argument("--session", help="Load an existing ACP conversation.")
    parser.add_argument('--bridge-grant', help='Existing private bridge grant path; never print its contents.')
    parser.add_argument('--output-file', help='Metadata destination when preserving an existing diagnostic record.')
    parser.add_argument("--model", default="default")
    parser.add_argument("--effort", default="medium")
    args = parser.parse_args()
    result = asyncio.run(inspect(args))
    sys.stdout.buffer.write((json.dumps(result, ensure_ascii=False, indent=2) + "\n").encode("utf-8"))


if __name__ == "__main__":
    main()
