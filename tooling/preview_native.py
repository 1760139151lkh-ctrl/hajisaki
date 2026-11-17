"""Capture the app's own offscreen ArkUI Previewer output; never uses host input.

The official Previewer creates a hidden GLFW window. This bridge supplies its
named pipe and receives the documented image WebSocket. It is an inspection
tool, not a device emulator or a functional test runner.

Use --interactive for manual JSON commands on stdin:
  {"command":"MousePress","args":{"x":200,"y":300}}
  {"command":"MouseRelease","args":{"x":200,"y":300}}
  {"capture":"C:/absolute/output.png"}
  {"record":"C:/absolute/new-frame-directory","duration_ms":2000}
  {"command":"exit"}
Only Previewer protocol messages are sent; Windows mouse/keyboard APIs are not
used. Capture keeps the original JPEG alongside a lossless PNG.
"""
from __future__ import annotations

import argparse
import contextlib
import io
import json
import pathlib
import re
import secrets
import socket
import struct
import subprocess
import sys
import threading
import time

import pywintypes
import websocket
import win32file
import win32pipe
import win32event
import win32con
from PIL import Image


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--previewer', type=pathlib.Path, required=True)
    parser.add_argument('--ets', type=pathlib.Path, required=True)
    parser.add_argument('--resources', type=pathlib.Path, required=True)
    parser.add_argument('--output', type=pathlib.Path, required=True)
    parser.add_argument('--width', type=int, default=1276)
    parser.add_argument('--height', type=int, default=2848)
    parser.add_argument('--density', type=int, default=480)
    parser.add_argument('--page', default='pages/Index')
    parser.add_argument('--color', choices=['dark', 'light'], default='dark')
    parser.add_argument('--settle', type=float, default=4)
    parser.add_argument('--interactive', action='store_true')
    parser.add_argument('--private-input', action='store_true', help='Do not record SDK/pipe diagnostics when entering credentials; bridge errors still log.')
    args = parser.parse_args()
    executable = args.previewer.resolve()
    ets = args.ets.resolve()
    resources = args.resources.resolve()
    if not executable.is_file() or not ets.is_dir() or not resources.is_dir():
        parser.error('Previewer executable and actual compiled ETS/resources directories are required.')
    if not str(executable).isascii():
        parser.error('Stage the Previewer directory under an ASCII path before launching; SDK resource loading fails on this host with non-ASCII runtime paths.')
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    pipe_name = 'HajiSakiPreview_' + secrets.token_hex(8)
    session_id = secrets.token_hex(16)
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    pipe = win32pipe.CreateNamedPipe(
        '\\\\.\\pipe\\' + pipe_name + '_commandPipe',
        win32pipe.PIPE_ACCESS_DUPLEX | win32con.FILE_FLAG_OVERLAPPED,
        win32pipe.PIPE_TYPE_BYTE | win32pipe.PIPE_READMODE_BYTE | win32pipe.PIPE_WAIT,
        1, 65536, 65536, 0, None,
    )
    connected = threading.Event()
    stopping = threading.Event()
    latest: list[bytes] = []
    image_lock = threading.Lock()
    socket_client = None
    process = None
    recording = None
    log_path = output.with_suffix('.preview.log')
    log = log_path.open('ab', buffering=0)

    def drain_pipe() -> None:
        connect_event = win32event.CreateEvent(None, True, False, None)
        read_event = win32event.CreateEvent(None, True, False, None)
        try:
            connection = pywintypes.OVERLAPPED()
            connection.hEvent = connect_event
            try:
                win32pipe.ConnectNamedPipe(pipe, connection)
            except pywintypes.error as exc:
                if exc.winerror == 535:
                    win32event.SetEvent(connect_event)
                elif exc.winerror != 997:
                    raise
            while win32event.WaitForSingleObject(connect_event, 100) != win32event.WAIT_OBJECT_0:
                if stopping.is_set():
                    return
            connected.set()
            read_buffer = win32file.AllocateReadBuffer(65536)
            while not stopping.is_set():
                win32event.ResetEvent(read_event)
                operation = pywintypes.OVERLAPPED()
                operation.hEvent = read_event
                win32file.ReadFile(pipe, read_buffer, operation)
                while win32event.WaitForSingleObject(read_event, 100) != win32event.WAIT_OBJECT_0:
                    if stopping.is_set():
                        win32file.CancelIo(pipe)
                        return
                count = win32file.GetOverlappedResult(pipe, operation, False)
                if count and not args.private_input:
                    log.write(b'\nPIPE ' + bytes(read_buffer[:count]) + b'\n')
        except pywintypes.error as exc:
            if not stopping.is_set():
                log.write(str(exc).encode('utf-8', errors='replace'))
        finally:
            win32file.CloseHandle(connect_event)
            win32file.CloseHandle(read_event)

    def send(command: str, arguments: dict, message_type: str = 'action') -> None:
        if process is not None and process.poll() is not None:
            raise RuntimeError(f'Previewer process exited {process.returncode}; inspect {log_path}')
        if not connected.wait(5):
            raise RuntimeError('Previewer command pipe did not connect')
        packet = {'version': '1.0.1', 'type': message_type, 'command': command, 'args': arguments}
        event = win32event.CreateEvent(None, True, False, None)
        operation = pywintypes.OVERLAPPED()
        operation.hEvent = event
        encoded_packet = json.dumps(packet).encode('utf-8') + b'\0'
        try:
            win32file.WriteFile(pipe, encoded_packet, operation)
            while win32event.WaitForSingleObject(event, 100) != win32event.WAIT_OBJECT_0:
                if process is not None and process.poll() is not None:
                    win32file.CancelIo(pipe)
                    raise RuntimeError(f'Previewer process exited {process.returncode}; inspect {log_path}')
            win32file.GetOverlappedResult(pipe, operation, False)
        finally:
            win32file.CloseHandle(event)

    def finish_record() -> None:
        nonlocal recording
        with image_lock:
            current, recording = recording, None
        if current is not None:
            folder = current.pop('folder')
            current['elapsed_ms'] = round((time.monotonic()-current.pop('start'))*1000,3)
            current['previewer_alive'] = process is not None and process.poll() is None
            (folder/'frames.json').write_text(json.dumps(current,indent=2),encoding='utf-8')
            print(json.dumps({'recording_complete':str(folder),'frames':len(current['frames'])}),flush=True)

    def start_record(path: pathlib.Path, duration_ms: int) -> None:
        nonlocal recording
        if not 1 <= duration_ms <= 5000 or process is None or process.poll() is not None:
            raise ValueError('Recording needs a live Previewer and a duration of 1–5000 ms')
        with image_lock:
            if recording is not None:
                raise ValueError('A visual recording is already active')
            folder=path.resolve();folder.mkdir(parents=True,exist_ok=False)
            recording={'folder':folder,'start':time.monotonic(),'duration_ms':duration_ms,'frames':[]}
            if latest:
                (folder/'0000-00000.000ms.jpg').write_bytes(latest[0])
                recording['frames'].append({'file':'0000-00000.000ms.jpg','ms':0})
        timer=threading.Timer(duration_ms/1000,finish_record);timer.daemon=True;timer.start()
        print(json.dumps({'recording':str(folder),'duration_ms':duration_ms}),flush=True)

    def receive_images() -> None:
        while not stopping.is_set():
            try:
                frame = socket_client.recv()
                if isinstance(frame, bytes) and len(frame) > 40:
                    magic = struct.unpack('>I', frame[:4])[0]
                    image_bytes = frame[40:]
                    if magic == 0x12345678 and image_bytes.startswith(b'\xff\xd8'):
                        with image_lock:
                            latest[:] = [image_bytes]
                            if recording is not None:
                                elapsed=round((time.monotonic()-recording['start'])*1000,3)
                                name=f"{len(recording['frames']):04d}-{elapsed:09.3f}ms.jpg"
                                (recording['folder']/name).write_bytes(image_bytes)
                                recording['frames'].append({'file':name,'ms':elapsed})
            except websocket.WebSocketTimeoutException:
                continue
            except Exception as exc:
                if not stopping.is_set():
                    log.write(('\nWebSocket: ' + str(exc)).encode('utf-8', errors='replace'))
                return

    def receive_private_diagnostics() -> None:
        # This is the app's deliberately sanitized development diagnostic. Raw
        # SDK lines can contain keystrokes or HTTP headers and are discarded.
        pattern = re.compile(r'HajiSaki preview message fields: client_id=(string|undefined|object|number|boolean)(, client_id_length=\d+)?, model=([A-Za-z0-9_.\-/]*), effort=(low|medium|high|xhigh|max), content=(string|undefined|object|number|boolean)')
        status_pattern = re.compile(r'HajiSaki preview HTTP status=\d{3}, method=(GET|POST|PUT|PATCH|DELETE)')
        sse_pattern = re.compile(r'HajiSaki preview SSE (bytes=\d+, decoded=\d+|seq=\d+, kind=[a-z_]+|committed=\d+, run_active=(true|false))')
        file_pattern = re.compile(r'HajiSaki preview file-save phase=(prepare|storage|transfer|write|verify|picker|export), error_code=-?\d+')
        write_pattern = re.compile(r'HajiSaki preview file-write api=(function|undefined|object), fd_valid=(true|false), buffer_valid=(true|false), bytes=\d+, result=-?\d+, error_kind=(type|range|other)')
        relay_pattern = re.compile(r'HajiSaki preview relay-profile phase=(size|json|shape|keys|pem), characters=\d+')
        crash_pattern = re.compile(r'\[JsEngine Crash\](Engine Crash Info (Begin|End)\.|ErrorCode: 0x[0-9a-fA-F]{8}|Address: 0x[0-9a-fA-F]+)')
        for line in process.stdout:
            decoded = line.decode('utf-8', errors='replace')
            match = pattern.search(decoded) or status_pattern.search(decoded) or sse_pattern.search(decoded) or file_pattern.search(decoded) or write_pattern.search(decoded) or relay_pattern.search(decoded) or crash_pattern.search(decoded)
            if match:
                diagnostic = match.group(0)
                log.write((diagnostic + '\n').encode('utf-8'))
                print(diagnostic, flush=True)

    def capture(path: pathlib.Path) -> None:
        if process is not None and process.poll() is not None:
            print(json.dumps({'capture_error': 'previewer_exited', 'exit_code': process.returncode,
                              'log': str(log_path)}), flush=True)
            return
        with image_lock:
            data = latest[0] if latest else None
        if data is None:
            raise RuntimeError(f'Previewer has not delivered an image; inspect {log_path}')
        path = path.resolve()
        path.parent.mkdir(parents=True, exist_ok=True)
        path.with_suffix('.jpg').write_bytes(data)
        with Image.open(io.BytesIO(data)) as rendered:
            rendered.save(path, format='PNG')
            print(json.dumps({'capture': str(path), 'width': rendered.width, 'height': rendered.height,
                              'previewer_pid': process.pid if process else None}), flush=True)

    def type_text(value: str) -> None:
        punctuation = {',': 2043, '.': 2044, ' ': 2050, '`': 2056, '-': 2057,
                       '=': 2058, '[': 2059, ']': 2060, '\\': 2061, ';': 2062,
                       "'": 2063, '/': 2064}
        shifted = dict(zip('!@#$%^&*()_+{}|:"<>?~', '1234567890-=[]\\;\',./`'))
        for character in value:
            base = shifted.get(character, character.lower())
            shift = character in shifted or ('A' <= character <= 'Z')
            if 'a' <= base <= 'z':
                key_code = 2017 + ord(base) - ord('a')
            elif '0' <= base <= '9':
                key_code = 2000 + int(base)
            else:
                key_code = punctuation.get(base)
            if key_code is None:
                send('KeyPress', {'isInputMethod': True, 'codePoint': ord(character)})
            else:
                pressed = [2047, key_code] if shift else [key_code]
                for action in (0, 1):
                    send('KeyPress', {'isInputMethod': False, 'keyCode': key_code,
                                     'keyAction': action, 'pressedCodes': pressed, 'keyString': character})
            time.sleep(0.02)

    try:
        threading.Thread(target=drain_pipe, daemon=True).start()
        command = [str(executable), '-j', str(ets), '-arp', str(resources),
                   '-url', args.page, '-pages', 'main_pages', '-pm', 'Stage', '-av', 'ACE_2_0',
                   '-or', str(args.width), str(args.height), '-cr', str(args.width), str(args.height),
                   '-device', 'phone', '-shape', 'rect', '-sd', str(args.density), '-cm', args.color,
                   '-l', 'zh_CN', '-s', pipe_name, '-lws', str(port), '-sid', session_id,
                   '-refresh', 'full', '-sm', 'dynamic']
        diagnostic_target = subprocess.PIPE if args.private_input else log
        process = subprocess.Popen(command, cwd=executable.parent, shell=False,
                                   creationflags=subprocess.CREATE_NO_WINDOW,
                                   stdout=diagnostic_target, stderr=subprocess.STDOUT if args.private_input else log)
        if args.private_input:
            threading.Thread(target=receive_private_diagnostics, daemon=True).start()
        deadline = time.monotonic() + 35
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise RuntimeError(f'Previewer exited {process.returncode}; inspect {log_path}')
            try:
                socket_client = websocket.create_connection(
                    f'ws://127.0.0.1:{port}/{session_id}', subprotocols=['ws'],
                    timeout=2, http_no_proxy=['127.0.0.1', 'localhost'],
                )
                break
            except (OSError, websocket.WebSocketException):
                time.sleep(0.25)
        if socket_client is None:
            raise RuntimeError(f'Previewer image WebSocket unavailable; inspect {log_path}')
        threading.Thread(target=receive_images, daemon=True).start()
        while time.monotonic() < deadline and not latest:
            if process.poll() is not None:
                raise RuntimeError(f'Previewer exited {process.returncode}; inspect {log_path}')
            time.sleep(0.1)
        time.sleep(args.settle)
        capture(output)
        if args.interactive:
            print('READY: Previewer JSON commands or capture paths on stdin; no host input.', flush=True)
            for line in sys.stdin:
                request = json.loads(line)
                if 'capture' in request:
                    capture(pathlib.Path(request['capture']))
                elif 'record' in request:
                    start_record(pathlib.Path(request['record']),int(request.get('duration_ms',2000)))
                elif 'text' in request or 'text_file' in request:
                    if 'text_file' in request:
                        if not args.private_input:
                            raise RuntimeError('File input requires --private-input to keep credentials out of diagnostic logs')
                        text_value = pathlib.Path(request['text_file']).read_text(encoding='utf-8')
                        if 'json_key' in request:
                            text_value = str(json.loads(text_value)[request['json_key']])
                    else:
                        text_value = str(request['text'])
                    type_text(text_value)
                    print(json.dumps({'input_characters': len(text_value)}), flush=True)
                else:
                    send(request['command'], request.get('args', {}), request.get('type', 'action'))
                    if request['command'] == 'exit':
                        break
    finally:
        finish_record()
        try:
            if process is not None and process.poll() is None:
                try:
                    send('exit', {})
                    process.wait(timeout=5)
                except (OSError, RuntimeError, pywintypes.error, subprocess.TimeoutExpired):
                    process.terminate()
                    process.wait(timeout=5)
        finally:
            stopping.set()
            if socket_client is not None:
                with contextlib.suppress(OSError, websocket.WebSocketException):
                    socket_client.close()
            with contextlib.suppress(pywintypes.error):
                win32file.CloseHandle(pipe)
            log.close()


if __name__ == '__main__':
    main()
