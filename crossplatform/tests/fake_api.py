#!/usr/bin/env python3
"""Stand-in model API for the tests: Anthropic's Messages API under /anthropic/v1 and an OpenAI-style chat completions API
under /openai/v1, both streaming server-sent events, on 127.0.0.1. No network, no real key.

  python3 fake_api.py <log-folder>      prints its port on the first line, then serves until killed

The key it accepts comes from the FAKE_API_KEY environment variable. Each request is written to its own file in the log
folder with whether its key was right (never the key itself), the tools it offered and the conversation it carried.

What it answers, so a test can see a whole tool loop: when the conversation has no tool results yet, it asks for the tools
named in FAKE_API_CALLS (a JSON list of {"tool", "args"}) that the request offered; once results came back, it answers
"Done: " followed by every result it was given.
"""
import json, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[1] if len(sys.argv) > 1 else "."
KEY = os.environ.get("FAKE_API_KEY", "")
WANTED_CALLS = json.loads(os.environ.get("FAKE_API_CALLS", "[]") or "[]")
os.makedirs(LOG, exist_ok=True)
counter = [0]
lock = threading.Lock()


def record(entry):
    with lock:
        counter[0] += 1
        number = counter[0]
    path = os.path.join(LOG, "%06d.json" % number)
    with open(path + ".tmp", "w", encoding="utf-8") as f:
        json.dump(entry, f)
    os.replace(path + ".tmp", path)


def tool_results_in(style, body):
    """Every tool result the conversation carried, as text."""
    found = []
    for message in body.get("messages", []):
        if style == "anthropic" and isinstance(message.get("content"), list):
            for block in message["content"]:
                if block.get("type") == "tool_result":
                    content = block.get("content")
                    if isinstance(content, list):
                        content = " ".join(part.get("text", "") for part in content)
                    found.append(str(content))
        if style == "openai" and message.get("role") == "tool":
            found.append(str(message.get("content", "")))
    return found


def offered_tools(style, body):
    if style == "anthropic":
        return [tool["name"] for tool in body.get("tools", [])]
    return [tool["function"]["name"] for tool in body.get("tools", [])]


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def style(self):
        return "anthropic" if self.path.startswith("/anthropic/") else "openai" if self.path.startswith("/openai/") else None

    def key_is_right(self, style):
        if style == "anthropic":
            return self.headers.get("x-api-key") == KEY and bool(self.headers.get("anthropic-version"))
        return self.headers.get("Authorization") == "Bearer " + KEY

    def send_json(self, status, value):
        data = json.dumps(value).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        style = self.style()
        if not style or not self.path.endswith("/models"):
            return self.send_json(404, {"error": {"message": "not here"}})
        record({"method": "GET", "path": self.path, "key_right": self.key_is_right(style)})
        if not self.key_is_right(style):
            return self.send_json(401, {"error": {"type": "authentication_error", "message": "invalid x-api-key"}})
        self.send_json(200, {"data": [{"id": "text-embedding-small"}, {"id": "fake-chat-1"}, {"id": "fake-chat-2"}]})

    def do_POST(self):
        style = self.style()
        length = int(self.headers.get("Content-Length") or 0)
        body = json.loads(self.rfile.read(length).decode("utf-8") or "{}")
        results = tool_results_in(style, body) if style else []
        tools = offered_tools(style, body) if style else []
        record({"method": "POST", "path": self.path, "style": style, "key_right": bool(style) and self.key_is_right(style), "model": body.get("model"),
                "stream": body.get("stream"), "tools": tools, "tool_choice": body.get("tool_choice"), "results": results, "body": body})
        if not style:
            return self.send_json(404, {"error": {"message": "not here"}})
        if not self.key_is_right(style):
            return self.send_json(401, {"error": {"type": "authentication_error", "message": "invalid x-api-key"}})
        calls = [] if results else [call for call in WANTED_CALLS if call["tool"] in tools]
        text = ("Done: " + " | ".join(results)) if results else ("" if calls else "fake api ok on %s" % body.get("model"))
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Connection", "close")
        self.end_headers()
        events = anthropic_events(text, calls) if style == "anthropic" else openai_events(text, calls)
        for event in events:
            self.wfile.write(event.encode("utf-8"))
            self.wfile.flush()
            time.sleep(0.01)
        self.close_connection = True


def sse(value, event=None):
    return ("event: %s\n" % event if event else "") + "data: " + json.dumps(value) + "\n\n"


def anthropic_events(text, calls):
    out = [sse({"type": "message_start", "message": {"id": "msg_fake", "role": "assistant", "content": []}}, "message_start")]
    index = 0
    if text:
        out.append(sse({"type": "content_block_start", "index": index, "content_block": {"type": "text", "text": ""}}, "content_block_start"))
        half = len(text) // 2
        for piece in (text[:half], text[half:]):
            out.append(sse({"type": "content_block_delta", "index": index, "delta": {"type": "text_delta", "text": piece}}, "content_block_delta"))
        out.append(sse({"type": "content_block_stop", "index": index}, "content_block_stop"))
        index += 1
    for number, call in enumerate(calls):
        arguments = json.dumps(call.get("args", {}))
        out.append(sse({"type": "content_block_start", "index": index, "content_block": {"type": "tool_use", "id": "toolu_%d" % number, "name": call["tool"], "input": {}}}, "content_block_start"))
        half = len(arguments) // 2
        for piece in (arguments[:half], arguments[half:]):
            out.append(sse({"type": "content_block_delta", "index": index, "delta": {"type": "input_json_delta", "partial_json": piece}}, "content_block_delta"))
        out.append(sse({"type": "content_block_stop", "index": index}, "content_block_stop"))
        index += 1
    out.append(sse({"type": "message_delta", "delta": {"stop_reason": "tool_use" if calls else "end_turn"}, "usage": {"output_tokens": 5}}, "message_delta"))
    out.append(sse({"type": "message_stop"}, "message_stop"))
    return out


def openai_events(text, calls):
    out = []
    if text:
        half = len(text) // 2
        for piece in (text[:half], text[half:]):
            out.append(sse({"choices": [{"index": 0, "delta": {"content": piece}, "finish_reason": None}]}))
    for number, call in enumerate(calls):
        arguments = json.dumps(call.get("args", {}))
        half = len(arguments) // 2
        out.append(sse({"choices": [{"index": 0, "delta": {"tool_calls": [{"index": number, "id": "call_%d" % number, "type": "function", "function": {"name": call["tool"], "arguments": arguments[:half]}}]}, "finish_reason": None}]}))
        out.append(sse({"choices": [{"index": 0, "delta": {"tool_calls": [{"index": number, "function": {"arguments": arguments[half:]}}]}, "finish_reason": None}]}))
    out.append(sse({"choices": [{"index": 0, "delta": {}, "finish_reason": "tool_calls" if calls else "stop"}]}))
    out.append("data: [DONE]\n\n")
    return out


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
