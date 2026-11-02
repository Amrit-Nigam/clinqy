#!/usr/bin/env python3
"""Local protocol fixture; never connects to a model or invokes a tool."""
import json
import os
import signal
import sys
import time

scenario, log_path = sys.argv[1:3]
args = sys.argv[3:]

def log(value):
    with open(log_path, "a") as handle:
        handle.write(json.dumps(value) + "\n")

log({"argv": args, "pid": os.getpid()})

def emit(value):
    # Fragment writes to exercise the Swift client's newline buffering.
    data = json.dumps(value) + "\n"
    sys.stdout.write(data[:7]); sys.stdout.flush()
    sys.stdout.write(data[7:]); sys.stdout.flush()

def event(method, params):
    emit({"method": method, "params": params})

turns = 0
for line in sys.stdin:
    request = json.loads(line)
    log(request)
    method, params = request["method"], request.get("params", {})
    if "id" not in request:
        continue
    result = {}
    if method == "initialize":
        result = {"userAgent": "fake-codex/0.165.0"}
    elif method == "config/read":
        flags = {}
        for arg in args:
            if arg.startswith("features.") and arg.endswith("=false"):
                flags[arg[len("features."):-len("=false")]] = False
        servers = {}
        for server in ["test.server", 'quoted"server']:
            marker = json.dumps(server, separators=(",", ":")) + "={enabled=false}"
            disabled = any(arg.startswith("mcp_servers={") and marker in arg for arg in args)
            servers[server] = {"enabled": not disabled}
        if scenario == "unsafe":
            flags["shell_tool"] = True
        if scenario == "new-server":
            servers["unexpected"] = {"enabled": True}
        result = {"config": {"features": flags, "mcp_servers": servers, "web_search": "disabled"}}
    elif method == "thread/start":
        assert params["ephemeral"] is True
        assert params["environments"] == []
        assert params["sandbox"] == "read-only"
        assert params["approvalPolicy"] == "untrusted"
        result = {"thread": {"id": "thread-1", "environments": []},
                  "sandbox": {"type": "readOnly", "networkAccess": False}, "approvalPolicy": "untrusted"}
        if scenario == "unsafe-ack":
            result["thread"]["environments"] = [{"id": "local"}]
        if scenario == "stop-reading":
            emit({"id": request["id"], "result": result})
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            time.sleep(60)
            continue
    elif method == "turn/start":
        turns += 1
        assert params["threadId"] == "thread-1"
        assert params["environments"] == []
        if scenario == "drop":
            os._exit(3)
        turn_id = "turn-" + str(turns)
        if scenario == "early":
            # Old-turn completion and the real turn's final items can precede its RPC acknowledgement.
            event("turn/completed", {"threadId": "thread-1", "turn": {"id": "old-turn", "status": "failed"}})
            event("item/completed", {"threadId": "thread-1", "turnId": turn_id,
                                     "item": {"id": "message", "type": "agentMessage", "text": "Early " + str(turns)}})
            event("turn/completed", {"threadId": "thread-1", "turn": {"id": turn_id, "status": "completed"}})
            emit({"id": request["id"], "result": {"turn": {"id": turn_id, "status": "completed"}}})
            continue
        emit({"id": request["id"], "result": {"turn": {"id": turn_id, "status": "inProgress"}}})
        if scenario == "wait":
            continue
        if scenario == "tool":
            emit({"id": 900, "method": "item/commandExecution/requestApproval", "params": {"threadId": "thread-1", "turnId": turn_id}})
            continue
        if scenario == "tool-item":
            event("item/started", {"threadId": "thread-1", "turnId": turn_id,
                                   "item": {"type": "commandExecution", "id": "tool-1"}})
            continue
        event("turn/started", {"threadId": "thread-1", "turn": {"id": turn_id}})
        event("item/agentMessage/delta", {"threadId": "wrong-thread", "turnId": turn_id,
                                           "itemId": "bogus", "delta": "WRONG"})
        event("item/agentMessage/delta", {"threadId": "thread-1", "turnId": "old-turn",
                                           "itemId": "bogus", "delta": "OLD"})
        event("item/agentMessage/delta", {"threadId": "thread-1", "turnId": turn_id,
                                           "itemId": "message", "delta": "Reply "})
        event("item/agentMessage/delta", {"threadId": "thread-1", "turnId": turn_id,
                                           "itemId": "message", "delta": str(turns)})
        event("item/completed", {"threadId": "thread-1", "turnId": turn_id,
                                 "item": {"id": "message", "type": "agentMessage", "text": "Reply " + str(turns), "phase": "final_answer"}})
        event("turn/completed", {"threadId": "thread-1", "turn": {"id": turn_id,
                                      "status": "failed" if scenario == "failed" else "completed"}})
        continue
    else:
        emit({"id": request["id"], "error": {"code": -32601, "message": "unexpected method"}})
        continue
    emit({"id": request["id"], "result": result})
