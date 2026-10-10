#!/bin/bash
# TEMPORARY (PR14 only): launches the Debug WSurf.app already built by the
# `xcodebuild test` step in an isolated Stage home, then drives the bundled
# `--mcp` stdio relay against that app's own socket. Removed after one run.
set -u
BIN="$DD/Build/Products/Debug/WSurf.app/Contents/MacOS/WSurf"
[ -x "$BIN" ] || { echo "FAIL: built app missing at \$DD/Build/Products/Debug/WSurf.app"; ls "$DD/Build/Products" 2>&1; exit 1; }

HOME_DIR=""
SOCKDIR=""
SUITE=""
OWN_SOCK=0
OWN_SUITE=0
PID=""
APP_STATUS="not-run"

cleanup() {
  rc=$?
  trap - EXIT
  if [ -n "$PID" ]; then
    if kill -0 "$PID" 2>/dev/null; then
      kill -TERM "$PID" 2>/dev/null
      deadline=$((SECONDS + 20))
      while kill -0 "$PID" 2>/dev/null && [ "$SECONDS" -lt "$deadline" ]; do sleep 0.5; done
      kill -0 "$PID" 2>/dev/null && kill -KILL "$PID" 2>/dev/null
    fi
    wait "$PID" 2>/dev/null
    APP_STATUS="exit-$?"
  fi
  if [ "$rc" -ne 0 ] && [ -f "$HOME_DIR/app.out" ]; then
    mkdir -p "${GITHUB_WORKSPACE:-.}/build/ci-diagnostics"
    tail -c 65536 "$HOME_DIR/app.out" >"${GITHUB_WORKSPACE:-.}/build/ci-diagnostics/pr14-smoke-app.log"
  fi
  [ "$OWN_SUITE" = 1 ] && defaults delete "$SUITE" >/dev/null 2>&1
  [ "$OWN_SOCK" = 1 ] && [ -d "$SOCKDIR" ] && [ ! -L "$SOCKDIR" ] && rm -rf "$SOCKDIR"
  [ -n "$HOME_DIR" ] && rm -rf "$HOME_DIR"
  echo "app cleanup (separate from relay check): $APP_STATUS"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 143' TERM INT

HOME_DIR=$(mktemp -d "${RUNNER_TEMP:?}/wsurf-smoke.XXXXXX") || exit 1
# Physical path; the exact same string is handed to Stage and hashed here.
HOME_DIR=$(cd -P "$HOME_DIR" && pwd -P) || exit 1
# StageMode.identity(for:) = SHA256 of the standardized home path; the suite and
# LocalMCPEndpoint.stageDirectory derive from it (WSurf/Stage/StageMode.swift).
ID=$(printf %s "$HOME_DIR" | shasum -a 256 | cut -d' ' -f1)
[[ "$ID" =~ ^[0-9a-f]{64}$ ]] || { echo "FAIL: stage identity is not 64 hex characters"; exit 1; }
SUITE="io.wsagency.wsurf.stage.$ID"
SOCKDIR="/tmp/wsurf-mcp-$(id -u)-${ID:0:32}"
SOCK="$SOCKDIR/browser.sock"
STAGE_ENV=(WSURF_STAGE=1 "WSURF_STAGE_HOME=$HOME_DIR" WSURF_STAGE_SEED=0)

# Ownership only after the directory is proven absent (and not a dangling link).
if [ -e "$SOCKDIR" ] || [ -L "$SOCKDIR" ]; then echo "FAIL: stage socket directory already exists; left untouched"; exit 1; fi
OWN_SOCK=1
OWN_SUITE=1
defaults write "$SUITE" mcp.enabled -bool true
[ "$(defaults read "$SUITE" mcp.enabled)" = "1" ] || { echo "FAIL: isolated mcp.enabled not set"; exit 1; }

env -u XCTestConfigurationFilePath "${STAGE_ENV[@]}" "$BIN" >"$HOME_DIR/app.out" 2>&1 &
PID=$!
echo "app launched: owned pid started"

deadline=$((SECONDS + 90))
while [ ! -S "$SOCK" ] && [ "$SECONDS" -lt "$deadline" ]; do
  if ! kill -0 "$PID" 2>/dev/null; then
    wait "$PID"; status=$?; PID=""; APP_STATUS="exit-$status (before socket)"
    echo "FAIL: app exited before opening its socket (exit $status); app log preserved in diagnostics"
    exit 1
  fi
  sleep 0.5
done
[ -S "$SOCK" ] || { echo "FAIL: own socket not created within 90s; app log preserved in diagnostics"; exit 1; }
echo "own stage socket present"

env -u XCTestConfigurationFilePath "${STAGE_ENV[@]}" SOCK="$SOCK" BIN="$BIN" python3 - <<'PY' || exit 1
import json, os, select, subprocess, sys, time

EXPECTED = sorted("""clickOnPage closeTab fillFields goBack hoverOnPage inspectControl listTabs navigate newTab
pressKey readPage requestAccess screenshotPage scrollPage selectOption setChecked switchTab typeOnPage
waitForPage""".split())
assert len(EXPECTED) == 19
for key in ("WSURF_STAGE", "WSURF_STAGE_HOME", "WSURF_STAGE_SEED"):
    assert key in os.environ, key
assert "XCTestConfigurationFilePath" not in os.environ

relay = subprocess.Popen([os.environ["BIN"], "--mcp", "--mcp-socket", os.environ["SOCK"]],
                         stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                         bufsize=0, env=os.environ.copy())
buffer = b""

def send(message):
    relay.stdin.write(json.dumps(message).encode() + b"\n")

def receive(expect_id, timeout=30):
    global buffer
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        while b"\n" in buffer:
            line, buffer = buffer.split(b"\n", 1)
            if not line.strip():
                continue
            message = json.loads(line)
            if message.get("id") == expect_id:
                return message
        ready, _, _ = select.select([relay.stdout], [], [], 1)
        if ready:
            chunk = os.read(relay.stdout.fileno(), 65536)
            if not chunk:
                break
            buffer += chunk
    raise SystemExit(f"FAIL: no response for id {expect_id}")

try:
    send({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
        "protocolVersion": "2025-06-18", "capabilities": {},
        "clientInfo": {"name": "PR14 app smoke", "version": "1"}}})
    init = receive(1)
    assert init["result"]["serverInfo"]["name"] == "WSurf" and "tools" in init["result"]["capabilities"], "initialize"
    print("initialize ok")
    send({"jsonrpc": "2.0", "method": "notifications/initialized"})
    send({"jsonrpc": "2.0", "id": 2, "method": "tools/list"})
    names = sorted(tool["name"] for tool in receive(2)["result"]["tools"])
    assert names == EXPECTED, f"tools/list inventory differs: {names}"
    print("tools/list inventory: exact 19 baseline names (listed only; only listTabs is executed below)")
    send({"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "listTabs", "arguments": {}}})
    listed = receive(3)
    assert "error" not in listed and not listed["result"].get("isError", False), f"listTabs failed: {json.dumps(listed)[:300]}"
    tabs = listed["result"]["structuredContent"]["tabs"]
    print(f"listTabs relay->app socket->session: isError=false, shared tabs={len(tabs)} (no consent given; liveness only)")
    relay.stdin.close()
    try:
        code = relay.wait(timeout=20)
    except subprocess.TimeoutExpired:
        raise SystemExit("FAIL: relay did not exit within 20s of EOF")
    stderr = relay.stderr.read()
    assert code == 0, f"relay exit {code}"
    assert not stderr, f"relay stderr {len(stderr)} bytes"
    print("relay EOF exit 0, empty stderr")
finally:
    if relay.poll() is None:
        relay.kill()
    relay.wait(timeout=10)
PY
echo "SMOKE PASS"
