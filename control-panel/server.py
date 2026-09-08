#!/usr/bin/env python3
"""Local control panel for the docker-compose stack.

Standalone: uses only the Python 3 standard library, and only talks to the
existing docker-compose.yml via the `docker compose` CLI. It does not import
or depend on any code from gateway/order-service/payment-service/inventory-
service.

Run:
    python3 server.py

Then open http://127.0.0.1:5151

Env vars:
    CONTROL_PANEL_PORT  port to listen on (default 5151)
    COMPOSE_DIR         directory containing docker-compose.yml
                        (default: ../docker-compose relative to this file)
"""

import json
import os
import re
import subprocess
import sys
import threading
import time
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

HOST = "127.0.0.1"
PORT = int(os.environ.get("CONTROL_PANEL_PORT", "5151"))

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
COMPOSE_DIR = os.environ.get(
    "COMPOSE_DIR",
    os.path.normpath(os.path.join(SCRIPT_DIR, "..", "docker-compose")),
)
COMPOSE_FILE = os.path.join(COMPOSE_DIR, "docker-compose.yml")
TESTS_DIR = os.environ.get(
    "TESTS_DIR",
    os.path.normpath(os.path.join(SCRIPT_DIR, "..", "tests")),
)

STACK_ACTIONS = {"up", "down", "restart"}
SERVICE_ACTIONS = {"start", "stop", "restart"}

ANSI_RE = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")

RUNS_LOCK = threading.Lock()
RUNS = {}  # run_id -> {"script": str, "output": str, "done": bool, "returncode": int|None, "started": float}


def run_compose(args, timeout=120):
    cmd = ["docker", "compose", "-f", COMPOSE_FILE] + args
    try:
        result = subprocess.run(cmd, cwd=COMPOSE_DIR, capture_output=True, text=True, timeout=timeout)
        return result.returncode, result.stdout, result.stderr
    except FileNotFoundError:
        return 1, "", "docker not found on PATH"
    except subprocess.TimeoutExpired:
        return 1, "", f"command timed out after {timeout}s"


def defined_services():
    code, out, err = run_compose(["config", "--services"])
    if code != 0:
        return [], err
    return [s for s in out.splitlines() if s.strip()], None


def container_status():
    code, out, err = run_compose(["ps", "--all", "--format", "json"])
    if code != 0:
        return {}, err
    out = out.strip()
    if not out:
        return {}, None
    # docker compose emits either one JSON array or newline-delimited JSON objects
    # depending on version, so handle both.
    try:
        data = json.loads(out)
        if isinstance(data, dict):
            data = [data]
    except json.JSONDecodeError:
        data = []
        for line in out.splitlines():
            line = line.strip()
            if not line:
                continue
            try:
                data.append(json.loads(line))
            except json.JSONDecodeError:
                pass

    status = {}
    for c in data:
        name = c.get("Service") or c.get("service")
        if not name:
            continue
        status[name] = {
            "state": c.get("State") or c.get("state") or "unknown",
            "status": c.get("Status") or c.get("status") or "",
            "health": c.get("Health") or c.get("health") or "",
            "ports": c.get("Publishers") or c.get("ports") or [],
        }
    return status, None


def all_services():
    services, err = defined_services()
    if err:
        return None, err
    status, err2 = container_status()
    if err2:
        return None, err2
    result = []
    for s in services:
        st = status.get(s, {})
        result.append(
            {
                "name": s,
                "state": st.get("state", "not created"),
                "status": st.get("status", ""),
                "health": st.get("health", ""),
                "ports": st.get("ports", []),
            }
        )
    return result, None


def list_test_scripts():
    if not os.path.isdir(TESTS_DIR):
        return []
    return sorted(f for f in os.listdir(TESTS_DIR) if f.endswith(".sh"))


def start_test_run(script_name):
    run_id = uuid.uuid4().hex[:12]
    with RUNS_LOCK:
        RUNS[run_id] = {
            "script": script_name,
            "output": "",
            "done": False,
            "returncode": None,
            "started": time.time(),
        }

    def worker():
        script_path = os.path.join(TESTS_DIR, script_name)
        try:
            proc = subprocess.Popen(
                ["bash", script_path],
                cwd=COMPOSE_DIR,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
                text=True,
                bufsize=1,
            )
            for line in proc.stdout:
                with RUNS_LOCK:
                    RUNS[run_id]["output"] += ANSI_RE.sub("", line)
            proc.wait()
            with RUNS_LOCK:
                RUNS[run_id]["returncode"] = proc.returncode
                RUNS[run_id]["done"] = True
        except Exception as e:
            with RUNS_LOCK:
                RUNS[run_id]["output"] += f"\n[control-panel] failed to run script: {e}\n"
                RUNS[run_id]["returncode"] = -1
                RUNS[run_id]["done"] = True

    threading.Thread(target=worker, daemon=True).start()
    return run_id


class Handler(BaseHTTPRequestHandler):
    server_version = "ControlPanel/1.0"

    def log_message(self, fmt, *args):
        sys.stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    def _send_json(self, obj, status=200):
        body = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_text(self, text, status=200):
        body = text.encode()
        self.send_response(status)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_file(self, path, content_type):
        with open(path, "rb") as f:
            body = f.read()
        self.send_response(200)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        parts = [p for p in path.split("/") if p]

        if path in ("/", "/index.html"):
            return self._send_file(os.path.join(SCRIPT_DIR, "index.html"), "text/html; charset=utf-8")

        if path == "/api/services":
            services, err = all_services()
            if err:
                return self._send_json({"error": err}, 500)
            return self._send_json({"services": services, "compose_file": COMPOSE_FILE})

        if path.startswith("/api/logs/"):
            name = path[len("/api/logs/") :]
            qs = parse_qs(parsed.query)
            lines = qs.get("lines", ["200"])[0]
            services, err = defined_services()
            if err:
                return self._send_json({"error": err}, 500)
            if name not in services:
                return self._send_json({"error": f"unknown service '{name}'"}, 404)
            code, out, err2 = run_compose(["logs", "--no-color", "--tail", lines, name], timeout=30)
            return self._send_text(out + (("\n" + err2) if err2 else ""))

        if path == "/api/tests":
            return self._send_json({"scripts": list_test_scripts(), "tests_dir": TESTS_DIR})

        if len(parts) == 4 and parts[0] == "api" and parts[1] == "tests" and parts[2] == "runs":
            run_id = parts[3]
            with RUNS_LOCK:
                run = RUNS.get(run_id)
                payload = dict(run) if run else None
            if payload is None:
                return self._send_json({"error": "unknown run_id"}, 404)
            return self._send_json(payload)

        return self._send_json({"error": "not found"}, 404)

    def do_POST(self):
        parts = [p for p in urlparse(self.path).path.split("/") if p]

        if len(parts) == 3 and parts[0] == "api" and parts[1] == "stack":
            action = parts[2]
            if action not in STACK_ACTIONS:
                return self._send_json({"error": "bad action"}, 400)
            if action == "up":
                code, out, err = run_compose(["up", "-d"], timeout=600)
            elif action == "down":
                code, out, err = run_compose(["down"], timeout=180)
            else:
                code, out, err = run_compose(["restart"], timeout=300)
            return self._send_json({"ok": code == 0, "stdout": out, "stderr": err})

        if len(parts) == 4 and parts[0] == "api" and parts[1] == "service":
            name, action = parts[2], parts[3]
            if action not in SERVICE_ACTIONS:
                return self._send_json({"error": "bad action"}, 400)
            services, err = defined_services()
            if err:
                return self._send_json({"error": err}, 500)
            if name not in services:
                return self._send_json({"error": f"unknown service '{name}'"}, 404)
            if action == "start":
                code, out, err = run_compose(["up", "-d", name], timeout=300)
            elif action == "stop":
                code, out, err = run_compose(["stop", name], timeout=60)
            else:
                code, out, err = run_compose(["restart", name], timeout=120)
            return self._send_json({"ok": code == 0, "stdout": out, "stderr": err})

        if len(parts) == 4 and parts[0] == "api" and parts[1] == "tests" and parts[3] == "run":
            name = parts[2]
            if name not in list_test_scripts():
                return self._send_json({"error": f"unknown test script '{name}'"}, 404)
            run_id = start_test_run(name)
            return self._send_json({"run_id": run_id})

        return self._send_json({"error": "not found"}, 404)


def main():
    if not os.path.isfile(COMPOSE_FILE):
        print(f"docker-compose.yml not found at {COMPOSE_FILE}", file=sys.stderr)
        print("Set the COMPOSE_DIR env var to point at the right directory.", file=sys.stderr)
        sys.exit(1)

    server = ThreadingHTTPServer((HOST, PORT), Handler)
    print(f"Control panel running at http://{HOST}:{PORT}")
    print(f"Controlling stack defined in: {COMPOSE_FILE}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopping.")


if __name__ == "__main__":
    main()
