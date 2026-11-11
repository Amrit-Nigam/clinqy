#!/usr/bin/python3
import json, re, sys, time, signal, os

if "stop-reading" in sys.argv:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    with open(os.environ["BRAIN_TEST_PID"], "w") as f: f.write(str(os.getpid()))
    time.sleep(30)
    sys.exit(0)

def emit(event):
    print(json.dumps(event), flush=True)

for line in sys.stdin:
    text = json.loads(line)['message']['content'][0]['text']
    match = re.search(r'Screenshot for this turn: (\S+)', text)
    path = match.group(1) if match else None
    mode = text.split('CASE:')[-1].split()[0]
    if mode == 'drop':
        sys.exit(0)
    if mode == 'wait':
        time.sleep(30)
        continue
    if path and mode != 'skip':
        if mode == 'stale': path = path.replace('screen-2.jpg', 'screen-1.jpg')
        emit({'event': 'step_update', 'step_update': {'step_type': 'tool', 'tool_name': 'read_file' if mode == 'read' else 'view_file', 'state': 'ERROR' if mode == 'error' else 'DONE', 'tool_info': {'parameters': {'Path': path}}}})
    emit({'event': 'step_update', 'step_update': {'step_type': 'agent_response', 'step_index': 1, 'text_delta': '{"actions":[{"do":"click","x":1,"y":1}],"done":true}'}})
    emit({'event': 'result', 'result': {'status': 'SUCCESS', 'response': '{"actions":[{"do":"click","x":1,"y":1}],"done":true}'}})
