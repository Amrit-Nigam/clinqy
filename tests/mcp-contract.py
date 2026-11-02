#!/usr/bin/env python3
"""Read-only protocol/schema smoke test against the built executable. Never calls a UI tool."""
import json
from pathlib import Path
import subprocess
root = Path(__file__).resolve().parents[1]
messages = [
    {'jsonrpc': '2.0', 'id': 1, 'method': 'initialize', 'params': {'protocolVersion': '2025-06-18'}},
    {'jsonrpc': '2.0', 'id': 2, 'method': 'tools/list'},
    {'jsonrpc': '2.0', 'id': 3, 'method': 'ping'},
    {'jsonrpc': '2.0', 'id': 4, 'method': 'tools/call', 'params': {'name': 'clinqy_act', 'arguments': {'action': {'do': 'shell'}}}},
]
result = subprocess.run([str(root / '.build/debug/Clinqy'), 'mcp'], input=''.join(json.dumps(m)+'\n' for m in messages),
                        capture_output=True, text=True, timeout=20, check=True)
replies = {r['id']: r for line in result.stdout.splitlines() if line.startswith('{') for r in [json.loads(line)]}
assert replies[1]['result']['protocolVersion'] == '2025-06-18'
assert replies[3]['result'] == {}
assert replies[4]['result']['isError'] is True
tools = {t['name']: t for t in replies[2]['result']['tools']}
assert set(tools) == {'clinqy_run', 'clinqy_look', 'clinqy_stats', 'clinqy_observe', 'clinqy_act', 'clinqy_wait', 'clinqy_verify', 'clinqy_release'}
actions = tools['clinqy_act']['inputSchema']['properties']['action']['properties']['do']['enum']
assert all(kind in actions for kind in ('hover', 'right_click', 'double_click', 'drag', 'click', 'type', 'key'))
assert 'shell' not in actions
assert 'observation' in tools['clinqy_act']['inputSchema']['required']
assert 'condition' in tools['clinqy_verify']['inputSchema']['required']
assert 'single-use' in replies[1]['result']['instructions']
assert tools['clinqy_observe']['annotations']['readOnlyHint'] is True
assert 'Native input requires' in tools['clinqy_run']['description']
print('PASS MCP initialization, discovery, direct schemas and task delegation compatibility')
