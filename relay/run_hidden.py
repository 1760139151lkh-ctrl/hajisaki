"""Launch/stop this package's Windows helpers without a visible console."""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import time
from pathlib import Path

import psutil

ROOT = Path(__file__).resolve().parent


def recorded_process(state: dict) -> psutil.Process | None:
    try:
        process = psutil.Process(state["pid"])
        if process.create_time() == state.get("created") and process.is_running():
            return process
    except (KeyError, psutil.NoSuchProcess):
        pass
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["start", "status", "stop"])
    parser.add_argument("role", choices=["relay", "host"])
    parser.add_argument("--config", required=True)
    parser.add_argument("--bind", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=9443)
    parser.add_argument("--development", action="store_true")
    args = parser.parse_args()
    config = Path(args.config).resolve()
    state_file = config.parent / "process.json"
    state = json.loads(state_file.read_text()) if state_file.exists() else {}
    existing = recorded_process(state)
    running = existing is not None
    if args.action == "status":
        print(json.dumps({"role": args.role, "running": running, "pid": state.get("pid")}))
        return
    if args.action == "stop":
        if running:
            # Check the recorded executable creation identity before stopping a potentially reused PID.
            if state.get("role") != args.role or state.get("config") != str(config):
                raise ValueError("Process record does not match this helper")
            existing.terminate()
            existing.wait(timeout=10)
        state["status"] = "stopped"
        state_file.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
        print(json.dumps({"role": args.role, "running": False}))
        return
    if running:
        print(json.dumps({"role": args.role, "running": True, "pid": state["pid"], "reused": True}))
        return
    module = "server" if args.role == "relay" else "connector"
    command = [sys.executable, "-m", "hajisaki_relay." + module, "--config", str(config)]
    if args.development:
        command.append("--development")
    if args.role == "relay":
        command.extend(["--bind", args.bind, "--port", str(args.port)])
    log = config.parent / "process.log"
    with log.open("ab") as output:
        process = subprocess.Popen(command, cwd=ROOT, stdin=subprocess.DEVNULL, stdout=output,
                                   stderr=subprocess.STDOUT, shell=False,
                                   creationflags=subprocess.CREATE_NO_WINDOW if os.name == "nt" else 0)
    created = psutil.Process(process.pid).create_time()
    state = {"pid": process.pid, "role": args.role, "config": str(config), "created": created,
             "status": "started", "log": str(log)}
    state_file.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    time.sleep(.8)
    if process.poll() is not None:
        raise RuntimeError("Helper exited during startup; inspect its local process.log")
    print(json.dumps({"role": args.role, "running": True, "pid": process.pid, "log": str(log)}))


if __name__ == "__main__":
    main()
