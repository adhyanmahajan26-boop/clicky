#!/usr/bin/env python3
"""A stand-in for an OpenAI-compatible model provider, for the stranger test: no network, no real key, no real model.

  python3 stand_in_openai.py <record-folder>      prints the port it listens on, then serves until killed

GET  /v1/models            one model, "stand-in-model"
POST /v1/chat/completions  streamed (SSE) or not. Each request body is saved to <record-folder>/<n>.json (the key is never
                           saved: only whether an Authorization header came). When the request offers a tool named
                           echo__echo and no tool answer is in the messages yet, it asks for that tool once; otherwise it
                           answers "Stand-in here." followed by any tool answer it was given.
"""
import http.server, json, pathlib, sys, threading

RECORD = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "stand-in-requests")
RECORD.mkdir(parents=True, exist_ok=True)
LOCK = threading.Lock()
MODEL = "stand-in-model"
TOOL = "echo__echo"


def record(body, authorized):
    with LOCK:
        number = len(list(RECORD.glob("*.json"))) + 1
        (RECORD / ("%03d.json" % number)).write_text(json.dumps({"authorized": authorized, "body": body}), encoding="utf-8")


def tool_names(body):
    return [t.get("function", {}).get("name") for t in body.get("tools") or []]


def tool_answers(body):
    return [m.get("content") if isinstance(m.get("content"), str) else json.dumps(m.get("content"))
            for m in body.get("messages", []) if m.get("role") == "tool"]


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def send_json(self, status, obj):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            return self.send_json(200, {"object": "list", "data": [{"id": MODEL, "object": "model"}]})
        self.send_json(404, {"error": {"message": "not here"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self.send_json(400, {"error": {"message": "bad json"}})
        record(body, bool(self.headers.get("Authorization")))
        if not self.path.rstrip("/").endswith("/chat/completions"):
            return self.send_json(404, {"error": {"message": "not here"}})
        answers = tool_answers(body)
        wants_tool = TOOL in tool_names(body) and not answers
        text = "Stand-in here." + ("".join(" " + a for a in answers) if answers else "")
        call = {"id": "call_stranger_1", "type": "function", "function": {"name": TOOL, "arguments": json.dumps({"text": "hello stranger"})}}
        if not body.get("stream"):
            message = {"role": "assistant", "content": None if wants_tool else text}
            if wants_tool:
                message["tool_calls"] = [call]
            return self.send_json(200, {"id": "chatcmpl-stranger", "object": "chat.completion", "model": MODEL,
                                        "choices": [{"index": 0, "message": message, "finish_reason": "tool_calls" if wants_tool else "stop"}],
                                        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.end_headers()

        def chunk(delta, finish=None):
            payload = {"id": "chatcmpl-stranger", "object": "chat.completion.chunk", "model": MODEL,
                       "choices": [{"index": 0, "delta": delta, "finish_reason": finish}]}
            self.wfile.write(("data: %s\n\n" % json.dumps(payload)).encode())
            self.wfile.flush()

        chunk({"role": "assistant"})
        if wants_tool:
            chunk({"tool_calls": [dict(call, index=0)]})
            chunk({}, "tool_calls")
        else:
            for word in text.split(" "):
                chunk({"content": word + " "})
            chunk({}, "stop")
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()


if __name__ == "__main__":
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
