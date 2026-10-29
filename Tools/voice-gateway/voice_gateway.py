#!/usr/bin/env python3
"""Clicky voice gateway: lets another Mac on the same network use this
Mac's Qwen voice.

Listens on 0.0.0.0:11240 and forwards GET /v1/models and
POST /v1/audio/speech to mlx-serve on 127.0.0.1:11234, but only for
requests that carry "Authorization: Bearer <key>". The key lives in
~/.clicky/voice-gateway.key (0600). If mlx-serve isn't running, the
gateway starts it (loopback only), the same way Clicky does.
"""

import hmac
import http.client
import http.server
import os
import socketserver
import subprocess
import sys
import time

LISTEN_HOST = os.environ.get("CLICKY_VOICE_GATEWAY_HOST", "0.0.0.0")
LISTEN_PORT = int(os.environ.get("CLICKY_VOICE_GATEWAY_PORT", "11240"))
UPSTREAM_HOST = "127.0.0.1"
UPSTREAM_PORT = 11234
MLX_SERVE = "/Applications/MLX Core.app/Contents/MacOS/mlx-serve"
KEY_PATH = os.path.expanduser("~/.clicky/voice-gateway.key")
ALLOWED = {("GET", "/v1/models"), ("POST", "/v1/audio/speech")}
MAX_BODY_BYTES = 8 * 1024 * 1024


def log(message):
    print(time.strftime("%Y-%m-%d %H:%M:%S"), message, flush=True)


def read_key():
    with open(KEY_PATH) as key_file:
        key = key_file.read().strip()
    if len(key) < 24:
        sys.exit("voice gateway key in %s is missing or too short" % KEY_PATH)
    return key


def upstream_is_up():
    try:
        connection = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=2)
        connection.request("GET", "/v1/models")
        return connection.getresponse().status == 200
    except OSError:
        return False


def ensure_upstream():
    if upstream_is_up():
        return True
    if not os.access(MLX_SERVE, os.X_OK):
        log("mlx-serve is not installed")
        return False
    log("starting mlx-serve on 127.0.0.1:%d" % UPSTREAM_PORT)
    subprocess.Popen([MLX_SERVE, "serve", "--host", UPSTREAM_HOST, "--port", str(UPSTREAM_PORT)],
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)
    for _ in range(60):
        time.sleep(1)
        if upstream_is_up():
            return True
    return False


class GatewayHandler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "ClickyVoiceGateway/1"

    def log_message(self, format, *args):
        log("%s %s" % (self.client_address[0], format % args))

    def reply(self, status, body=b"", content_type="application/json"):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def handle_any(self, method):
        path = self.path.split("?", 1)[0]
        if path == "/health":
            return self.reply(200, b'{"ok":true}')
        if (method, path) not in ALLOWED:
            return self.reply(404, b'{"error":"not found"}')
        supplied = self.headers.get("Authorization", "")
        expected = "Bearer " + self.server.key
        if not hmac.compare_digest(supplied.encode(), expected.encode()):
            return self.reply(401, b'{"error":"wrong or missing key"}')

        length = int(self.headers.get("Content-Length") or 0)
        if length > MAX_BODY_BYTES:
            return self.reply(413, b'{"error":"too large"}')
        body = self.rfile.read(length) if length else None

        if not ensure_upstream():
            return self.reply(503, b'{"error":"voice model not running"}')
        try:
            connection = http.client.HTTPConnection(UPSTREAM_HOST, UPSTREAM_PORT, timeout=180)
            headers = {"Content-Type": self.headers.get("Content-Type", "application/json")}
            connection.request(method, path, body=body, headers=headers)
            response = connection.getresponse()
            data = response.read()
            self.reply(response.status, data, response.getheader("Content-Type", "application/octet-stream"))
        except OSError as error:
            log("upstream error: %s" % error)
            self.reply(502, b'{"error":"voice model did not answer"}')

    def do_GET(self):
        self.handle_any("GET")

    def do_POST(self):
        self.handle_any("POST")


class GatewayServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def main():
    server = GatewayServer((LISTEN_HOST, LISTEN_PORT), GatewayHandler)
    server.key = read_key()
    log("Clicky voice gateway on %s:%d -> %s:%d" % (LISTEN_HOST, LISTEN_PORT, UPSTREAM_HOST, UPSTREAM_PORT))
    ensure_upstream()
    server.serve_forever()


if __name__ == "__main__":
    main()
