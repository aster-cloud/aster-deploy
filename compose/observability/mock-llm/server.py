#!/usr/bin/env python3
"""
Mock LLM server — 返回 OpenAI 兼容响应

用途：staging 不消耗真实 LLM token，让 aster-api 仍能解析 usage 字段，
触发 llm_tokens_total Counter，让 Grafana LLM 成本面板有数据。
"""
from http.server import HTTPServer, BaseHTTPRequestHandler
import json
import time
import random


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get('Content-Length', 0))
        body = self.rfile.read(length).decode('utf-8') if length else '{}'
        try:
            req = json.loads(body)
        except Exception:
            req = {}

        time.sleep(random.uniform(0.01, 0.03))

        prompt_tokens = sum(len(m.get('content', '')) for m in req.get('messages', [])) // 4 + 50
        completion_tokens = random.randint(80, 250)

        response = {
            "id": "mock-" + str(int(time.time() * 1000)),
            "object": "chat.completion",
            "created": int(time.time()),
            "model": req.get('model', 'gpt-4o-mini'),
            "choices": [{
                "index": 0,
                "message": {
                    "role": "assistant",
                    "content": "Module aster.staging.\n\nRule generated:\n  Return \"mock\"."
                },
                "finish_reason": "stop"
            }],
            "usage": {
                "prompt_tokens": prompt_tokens,
                "completion_tokens": completion_tokens,
                "total_tokens": prompt_tokens + completion_tokens
            }
        }

        body_bytes = json.dumps(response).encode('utf-8')
        self.send_response(200)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body_bytes)))
        self.end_headers()
        self.wfile.write(body_bytes)

    def do_GET(self):
        if self.path in ('/', '/health', '/healthz'):
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain')
            self.end_headers()
            self.wfile.write(b'mock-llm OK')
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass


if __name__ == '__main__':
    server = HTTPServer(('0.0.0.0', 8000), Handler)
    print('mock-llm listening on :8000', flush=True)
    server.serve_forever()
