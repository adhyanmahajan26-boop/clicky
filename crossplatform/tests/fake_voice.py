#!/usr/bin/env python3
"""Stand-in speech services for the dictation tests, on 127.0.0.1. No network, no real key.

  python3 fake_voice.py <log-folder>      prints its port on the first line, then serves until killed

  POST /openai/v1/audio/transcriptions    {"text": FAKE_VOICE_WORDS}                      (OpenAI and Groq style)
  POST /sarvam/speech-to-text             {"transcript": FAKE_VOICE_WORDS}
  POST /deepgram/v1/listen                Deepgram's results shape
  GET  /openai/v1/models                  a short list with a cheap model in it
  POST /openai/v1/chat/completions        the clean-up: the words inside <dictation> with "gonna" as "going to", streamed

Every request is logged (path, whether the key was right, the multipart field names, whether a WAV came, the model, and
whether the clean-up's system prompt was the dictation one), never the key itself.
"""
import json, os, re, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[1] if len(sys.argv) > 1 else "."
KEY = os.environ.get("FAKE_VOICE_KEY", "")
WORDS = os.environ.get("FAKE_VOICE_WORDS", "um so I I think we're gonna ship it today")
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


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def key_is_right(self):
        given = self.headers.get("Authorization", "") or ""
        given = given.replace("Bearer ", "").replace("Token ", "")
        return given == KEY or self.headers.get("api-subscription-key") == KEY

    def send_json(self, status, value):
        data = json.dumps(value).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        record({"method": "GET", "path": self.path, "key_right": self.key_is_right()})
        if self.path.endswith("/models"):
            return self.send_json(200, {"data": [{"id": "whisper-1"}, {"id": "gpt-5"}, {"id": "gpt-4.1-mini"}]})
        self.send_json(404, {"error": {"message": "no such path"}})

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0") or 0)
        body = self.rfile.read(length)
        content_type = self.headers.get("Content-Type", "")
        entry = {"method": "POST", "path": self.path, "key_right": self.key_is_right(), "bytes": len(body), "wav": b"RIFF" in body[:4096] and b"WAVE" in body[:4096]}
        if "multipart/form-data" in content_type:
            entry["fields"] = re.findall(r'name="([^"]+)"', body.decode("latin-1"))
            model = re.search(r'name="model"\r\n\r\n([^\r]*)', body.decode("latin-1"))
            entry["model"] = model.group(1) if model else None
        if not entry["key_right"]:
            record(entry)
            return self.send_json(401, {"error": {"message": "Incorrect API key provided"}})
        if self.path.endswith("/audio/transcriptions"):
            record(entry)
            return self.send_json(200, {"text": WORDS})
        if self.path.endswith("/speech-to-text"):
            record(entry)
            return self.send_json(200, {"transcript": WORDS, "language_code": "en-IN"})
        if "/v1/listen" in self.path:
            record(entry)
            return self.send_json(200, {"results": {"channels": [{"alternatives": [{"transcript": WORDS, "confidence": 0.9}]}]}})
        if self.path.endswith("/chat/completions"):
            request = json.loads(body or b"{}")
            messages = request.get("messages", [])
            system = next((m.get("content", "") for m in messages if m.get("role") == "system"), "")
            user = next((m.get("content", "") for m in messages if m.get("role") == "user"), "")
            entry.update({"model": request.get("model"), "dictation_prompt": system.startswith("You tidy up dictated text.")})
            record(entry)
            said = re.search(r"<dictation>(.*)</dictation>", user, re.S)
            tidied = (said.group(1) if said else user).replace("gonna", "going to")
            events = [{"choices": [{"delta": {"content": tidied}, "finish_reason": None}]}, {"choices": [{"delta": {}, "finish_reason": "stop"}]}]
            data = "".join("data: %s\n\n" % json.dumps(event) for event in events) + "data: [DONE]\n\n"
            data = data.encode()
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)
            return
        record(entry)
        self.send_json(404, {"error": {"message": "no such path"}})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
