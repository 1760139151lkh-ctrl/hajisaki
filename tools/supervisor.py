"""HajiSaki's independent, silent per-user gateway supervisor.

python tools/supervisor.py start|stop|status|run [--provider agy|development]
Uses the current user's Antigravity login; never opens a console window.
"""
from __future__ import annotations

import argparse
import ctypes
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

for stream in (sys.stdout, sys.stderr):
    if stream is not None and hasattr(stream, 'reconfigure'):
        stream.reconfigure(encoding='utf-8', errors='replace')

ROOT = Path(__file__).resolve().parents[1]
DATA = Path(os.environ.get('HAJI_DATA_DIR', ROOT / 'runtime')).resolve()
STATE = DATA / 'supervisor.json'
STOP = DATA / 'supervisor.stop'
PORT = int(os.environ.get('HAJI_PORT', '8765'))
FLAGS = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
AWAKE = False


def saved_options() -> dict:
    try:
        value = json.loads((DATA / 'host-settings.json').read_text(encoding='utf-8'))
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def state() -> dict:
    try:
        return json.loads(STATE.read_text(encoding='utf-8'))
    except (OSError, ValueError):
        return {}


def health() -> dict | None:
    try:
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        with opener.open(f'http://127.0.0.1:{PORT}/api/health', timeout=2) as response:
            return json.load(response)
    except (OSError, ValueError, urllib.error.URLError):
        return None


def alive(pid: int) -> bool:
    if not pid:
        return False
    if os.name == 'nt':
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.OpenProcess.argtypes = [ctypes.c_ulong, ctypes.c_bool, ctypes.c_ulong]
        kernel.OpenProcess.restype = ctypes.c_void_p
        handle = kernel.OpenProcess(0x1000, False, pid)
        if not handle:
            return False
        code = ctypes.c_ulong()
        kernel.GetExitCodeProcess.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong)]
        kernel.CloseHandle.argtypes = [ctypes.c_void_p]
        valid = kernel.GetExitCodeProcess(handle, ctypes.byref(code))
        kernel.CloseHandle(handle)
        return bool(valid and code.value == 259)
    try:
        os.kill(pid, 0)
        return True
    except OSError:
        return False


def publish(**values: object) -> None:
    STATE.write_text(json.dumps({'root': str(ROOT), 'port': PORT, 'system_awake_requested': AWAKE,
                                **values}, ensure_ascii=False, indent=2), encoding='utf-8')


def recycle_stop() -> None:
    if STOP.exists():
        from send2trash import send2trash
        send2trash(str(STOP))


def serve(provider: str, proxy_url: str = '') -> int:
    global AWAKE
    DATA.mkdir(parents=True, exist_ok=True)
    lock = None
    if os.name == 'nt':
        import hashlib
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        kernel.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_bool, ctypes.c_wchar_p]
        kernel.CreateMutexW.restype = ctypes.c_void_p
        name = 'Local\\HajiSaki-' + hashlib.sha256(str(DATA).encode()).hexdigest()[:24]
        lock = kernel.CreateMutexW(None, True, name)
        if not lock or ctypes.get_last_error() == 183:
            return 2
    else:
        import fcntl
        lock = (DATA / 'supervisor.lock').open('a+')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return 2
    if health():
        return 2
    recycle_stop()
    if os.name == 'nt':
        kernel.SetThreadExecutionState.argtypes = [ctypes.c_ulong]
        kernel.SetThreadExecutionState.restype = ctypes.c_ulong
        # Keep the host available without forcing its display to stay on or changing a power plan.
        AWAKE = bool(kernel.SetThreadExecutionState(0x80000001))
    stopping = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stopping.set())
    env = os.environ.copy()
    env.update(PYTHONPATH=str(ROOT / 'host'), HAJI_DATA_DIR=str(DATA), HAJI_PROVIDER=provider,
               HAJI_PORT=str(PORT), PYTHONUTF8='1')
    if proxy_url:
        env['HAJI_PROXY_URL'] = proxy_url
    command = [sys.executable, '-m', 'uvicorn', 'hajisaki.app:app', '--host', '127.0.0.1', '--port', str(PORT), '--no-access-log']
    log_path = DATA / 'gateway.log'
    restarts = 0
    child = None
    try:
        with log_path.open('ab', buffering=0) as output:
            while not stopping.is_set() and not STOP.exists():
                child = subprocess.Popen(command, cwd=ROOT, env=env, shell=False, creationflags=FLAGS,
                                         stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT)
                publish(pid=os.getpid(), child_pid=child.pid, provider=provider, status='starting', restarts=restarts)
                healthy = False
                while child.poll() is None and not stopping.wait(0.5) and not STOP.exists():
                    if not healthy and health():
                        healthy = True
                        publish(pid=os.getpid(), child_pid=child.pid, provider=provider, status='running', restarts=restarts)
                if stopping.is_set() or STOP.exists():
                    break
                restarts += 1
                publish(pid=os.getpid(), provider=provider, status='recovering', exit_code=child.returncode, restarts=restarts)
                stopping.wait(3)
    finally:
        if child and child.poll() is None:
            child.terminate()
            try:
                child.wait(timeout=10)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait(timeout=5)
        publish(pid=os.getpid(), provider=provider, status='stopped', restarts=restarts)
        if os.name == 'nt' and lock:
            if AWAKE:
                kernel.SetThreadExecutionState(0x80000000)
                AWAKE = False
            kernel.ReleaseMutex.argtypes = [ctypes.c_void_p]
            kernel.CloseHandle.argtypes = [ctypes.c_void_p]
            kernel.ReleaseMutex(lock)
            kernel.CloseHandle(lock)
    return 0


def main() -> int:
    global DATA, STATE, STOP, PORT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'stop', 'status', 'run'])
    parser.add_argument('--data-dir', type=Path, default=DATA)
    parser.add_argument('--port', type=int, default=PORT)
    parser.add_argument('--provider', choices=['agy', 'acp', 'development'])
    parser.add_argument('--proxy-url')
    args = parser.parse_args()
    DATA = args.data_dir.resolve()
    STATE, STOP, PORT = DATA / 'supervisor.json', DATA / 'supervisor.stop', args.port
    options = saved_options()
    args.provider = args.provider or os.environ.get('HAJI_PROVIDER') or options.get('provider', 'acp')
    if args.proxy_url is None:
        args.proxy_url = os.environ.get('HAJI_PROXY_URL', '') or options.get('proxy_url', '')
    if not 1024 <= PORT <= 65535:
        parser.error('port must be between 1024 and 65535')
    sys.path.insert(0, str(ROOT / 'host'))
    from hajisaki.config import secure_data_directory
    secure_data_directory(DATA)
    DATA.mkdir(parents=True, exist_ok=True)
    current = state()
    if args.action == 'status':
        print(json.dumps({'supervisor': current, 'process_alive': alive(current.get('pid', 0)), 'health': health()}, ensure_ascii=False, indent=2))
        return 0
    if args.action == 'run':
        return serve(args.provider, args.proxy_url)
    if args.action == 'stop':
        if current.get('root') != str(ROOT) or not alive(current.get('pid', 0)) or current.get('status') == 'stopped':
            print('No running HajiSaki supervisor for this project.')
            return 0
        STOP.write_text('Stop requested by the project launcher.\n', encoding='utf-8')
        print('Stop requested. Conversations remain on disk.')
        return 0
    if alive(current.get('pid', 0)) and current.get('status') != 'stopped':
        print(f'HajiSaki supervisor already running (PID {current["pid"]}).')
        return 0
    if health():
        print(f'A gateway is already responding on 127.0.0.1:{PORT}; no duplicate launched.')
        return 0
    interpreter = Path(sys.executable)
    if os.name == 'nt' and interpreter.with_name('pythonw.exe').exists():
        interpreter = interpreter.with_name('pythonw.exe')
    with (DATA / 'supervisor.log').open('ab', buffering=0) as output:
        child = subprocess.Popen([str(interpreter), str(Path(__file__).resolve()), 'run', '--provider', args.provider,
                                  '--proxy-url', args.proxy_url, '--data-dir', str(DATA), '--port', str(PORT)],
                                 cwd=ROOT, shell=False, creationflags=FLAGS, stdin=subprocess.DEVNULL,
                                 stdout=output, stderr=subprocess.STDOUT)
    print(f'HajiSaki supervisor starting (PID {child.pid}); http://127.0.0.1:{PORT}')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())

