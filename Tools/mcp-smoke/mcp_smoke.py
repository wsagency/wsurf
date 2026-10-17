#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 WSurf Agency
# SPDX-License-Identifier: Apache-2.0
"""Attended smoke test for WSurf's MCP server, driven by a plain stdio MCP client.

Not part of any automated gate: it needs a running WSurf (a Stage Debug app) and a person who answers the access sheet once.
It speaks MCP over the same `WSurf --mcp` relay a real client launches, so it checks the whole path: relay, socket, consent,
page tools, development tools and shutdown. It adds no consent bypass.

  python3 -I Tools/mcp-smoke/mcp_smoke.py --app /path/to/WSurf.app --stage-home "$stage_home"

Steps (see MCP.md, "Verify with a real client"): initialize, tools/list, requestAccess(development), listTabs, readPage,
screenshotPage, getDevelopmentInfo, setViewport, emulateDevice(phone), startDiagnostics, readConsole, resetDevelopment, then EOF
on stdin. `--engine` says which engine the fixture tab runs on: the phone profile applies on Chromium and is rejected, with
nothing changed, on WebKit.
"""
import argparse
import functools
import http.server
import json
import os
import subprocess
import sys
import threading
import time

FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fixture")
EXPECTED_TOOLS = 33
JPEG = "/9j/"  # base64 of FF D8 FF


class Client:
    def __init__(self, command, env):
        self.process = subprocess.Popen(
            command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True, bufsize=1)
        self.next_id = 1

    def send(self, message):
        self.process.stdin.write(json.dumps(message) + "\n")
        self.process.stdin.flush()

    def request(self, method, params=None, timeout=30):
        request_id = self.next_id
        self.next_id += 1
        self.send({"jsonrpc": "2.0", "id": request_id, "method": method, "params": params or {}})
        deadline = time.monotonic() + timeout
        result = {}

        def read():
            while True:
                line = self.process.stdout.readline()
                if not line:
                    result["error"] = "relay closed its output"
                    return
                message = json.loads(line)
                if message.get("id") == request_id:
                    result["message"] = message
                    return

        reader = threading.Thread(target=read, daemon=True)
        reader.start()
        reader.join(max(0.0, deadline - time.monotonic()))
        if "message" not in result:
            raise RuntimeError(result.get("error") or "no answer within %ds to %s" % (timeout, method))
        if "error" in result["message"]:
            raise RuntimeError("%s failed: %s" % (method, result["message"]["error"]))
        return result["message"]["result"]

    def call(self, name, arguments=None, timeout=30):
        return self.request("tools/call", {"name": name, "arguments": arguments or {}}, timeout)

    def close(self):
        self.process.stdin.close()
        try:
            return self.process.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.process.kill()
            return None


def texts(result):
    return "\n".join(item.get("text", "") for item in result.get("content", []) if item.get("type") == "text")


def status(result):
    return (result.get("structuredContent") or {}).get("status")


def main():
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--app", required=True, help="path to the Stage Debug WSurf.app")
    parser.add_argument("--stage-home", required=True, help="the WSURF_STAGE_HOME the app was launched with")
    parser.add_argument("--engine", choices=["webkit", "chromium"], default="webkit", help="engine of the fixture tab")
    parser.add_argument("--timeout", type=int, default=180, help="seconds to wait for the access sheet to be answered")
    args = parser.parse_args()

    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=FIXTURE)
    handler.log_message = lambda *a, **k: None
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = "http://127.0.0.1:%d/" % server.server_address[1]

    env = dict(os.environ, WSURF_STAGE="1", WSURF_STAGE_HOME=args.stage_home)
    client = Client([os.path.join(args.app, "Contents/MacOS/WSurf"), "--mcp"], env)
    failures = []

    def step(name, ok, detail=""):
        print("%-22s %s %s" % (name, "PASS" if ok else "FAIL", detail))
        if not ok:
            failures.append(name)

    try:
        init = client.request("initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "wsurf-smoke", "version": "1"}})
        client.send({"jsonrpc": "2.0", "method": "notifications/initialized"})
        step("initialize", "serverInfo" in init, init.get("serverInfo", {}).get("name", ""))
        tools = [tool["name"] for tool in client.request("tools/list")["tools"]]
        step("tools/list", len(tools) == EXPECTED_TOOLS, "%d tools" % len(tools))

        print("\nOpen this address in the Stage WSurf window, then press Return here:\n  %s" % url)
        input()
        print("WSurf now shows an access sheet. Choose Allow Development.")
        access = client.call("requestAccess", {"development": True}, timeout=args.timeout)
        step("requestAccess", not access.get("isError"), texts(access)[:80].replace("\n", " "))
        listed = client.call("listTabs")
        tabs = [tab for tab in (listed.get("structuredContent") or {}).get("tabs", []) if "127.0.0.1" in str(tab.get("url", ""))]
        step("listTabs", len(tabs) >= 1, "%d shared fixture tab(s)" % len(tabs))
        if not tabs:
            raise RuntimeError("the fixture tab is not shared; nothing further can run")
        tab = tabs[0]["tabID"]

        page = client.call("readPage", {"tabID": tab})
        step("readPage", "smoke-marker-7f3a" in texts(page), "marker in page text")
        shot = client.call("screenshotPage", {"tabID": tab})
        images = [item for item in shot.get("content", []) if item.get("type") == "image"]
        step("screenshotPage", bool(images) and images[0]["data"].startswith(JPEG), "%d image(s)" % len(images))
        info = client.call("getDevelopmentInfo", {"tabID": tab})
        step("getDevelopmentInfo", status(info) == "ok", status(info) or texts(info)[:60])
        viewport = client.call("setViewport", {"tabID": tab, "width": 400, "height": 700})
        measured = (viewport.get("structuredContent") or {}).get("viewport") or {}
        step("setViewport", status(viewport) == "ok" and measured.get("innerWidth") == 400, "innerWidth %s" % measured.get("innerWidth"))
        phone = client.call("emulateDevice", {"tabID": tab, "profile": "phone", "orientation": "portrait"})
        wanted = "ok" if args.engine == "chromium" else "unsupported"
        measured = (phone.get("structuredContent") or {}).get("viewport") or {}
        step("emulateDevice phone", status(phone) == wanted, "%s (wanted %s), dpr %s" % (status(phone), wanted, measured.get("devicePixelRatio")))
        started = client.call("startDiagnostics", {"tabID": tab})
        step("startDiagnostics", status(started) == "ok", status(started) or texts(started)[:60])
        seen = []
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline and not seen:
            records = (client.call("readConsole", {"tabID": tab}).get("structuredContent") or {}).get("records", [])
            seen = [record for record in records if "smoke tick" in str(record.get("text", ""))]
            time.sleep(0.4)
        step("readConsole", bool(seen), "%d console record(s)" % len(seen))
        reset = client.call("resetDevelopment", {"tabID": tab})
        step("resetDevelopment", status(reset) == "ok", status(reset) or texts(reset)[:60])
    except Exception as error:  # a failed step ends the run; the relay is still closed below
        step("run", False, str(error))
    code = client.close()
    step("relay exit", code == 0, "exit %s" % code)
    server.shutdown()
    print("\n%s" % ("All steps passed." if not failures else "Failed: " + ", ".join(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
