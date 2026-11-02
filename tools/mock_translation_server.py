"""Local-only, disposable UI test service. Never records text or authorization."""
import hashlib
import json
import os
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

JOURNAL = Path(f'/private/tmp/MacToolbox-smoke-{os.getuid()}/requests.jsonl')


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', '0'))
        if length > 128 * 1024:
            self.send_error(413)
            return
        body = json.loads(self.rfile.read(length))
        source = body['messages'][-1]['content']
        JOURNAL.parent.mkdir(exist_ok=True)
        with JOURNAL.open('a') as output:
            output.write(json.dumps({'path': self.path, 'model': body.get('model'),
                'text_sha256': hashlib.sha256(source.encode()).hexdigest()}) + '\n')
        data = json.dumps({'choices': [{'message': {'role': 'assistant', 'content': '这是本地测试译文。'}, 'finish_reason': 'stop'}]}, ensure_ascii=False).encode()
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *_):
        pass


if __name__ == '__main__':
    server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    print(f'http://127.0.0.1:{server.server_port}/v1', flush=True)
    server.serve_forever()
