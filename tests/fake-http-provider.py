#!/usr/bin/env python3
import json, sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
records = {}
class Handler(BaseHTTPRequestHandler):
    def log_message(self, *_): pass
    def do_GET(self):
        data=json.dumps(records).encode();self.send_response(200);self.end_headers();self.wfile.write(data)
    def do_POST(self):
        mode=self.path.split('/')[1]
        body=json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        rows=records.setdefault(mode,[]);rows.append(body)
        fail=mode in ('oversize','custom') or (mode in ('shrink','compact') and len(rows)==1)
        requested=11000 if mode=='shrink' else 30000 if mode=='custom' else 16008
        result={'error':{'message':f'Request too large on tokens per min (TPM): Limit 10000, Requested {requested}.'}} if fail else {'choices':[{'message':{'content':'{"done":true,"actions":[]}'}}]}
        if mode in ('throttle', 'header', 'throttle-repeat', 'cancel-wait', 'quota'):
            fail=mode in ('throttle-repeat','cancel-wait','quota') or len(rows)==1
            wait='10' if mode=='cancel-wait' else '0.2'
            if fail: result={'error':{'message': 'Insufficient quota' if mode=='quota' else f'Rate limit reached on tokens per min (TPM). Please try again in {wait}s.'}}
        data=json.dumps(result).encode();self.send_response(429 if fail else 200)
        if mode=='header' and fail: self.send_header('Retry-After','0.4')
        self.send_header('Content-Type','application/json');self.send_header('Content-Length',str(len(data)));self.end_headers();self.wfile.write(data)
server=ThreadingHTTPServer(('127.0.0.1',0),Handler)
open(sys.argv[1],'w').write(str(server.server_port))
server.serve_forever()
