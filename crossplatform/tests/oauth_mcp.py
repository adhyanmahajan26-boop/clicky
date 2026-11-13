#!/usr/bin/env python3
"""A stand-in remote app for the connector hub's tests: an MCP server over streamable HTTP behind its own OAuth 2.1
sign-in (protected-resource metadata, authorization-server metadata, dynamic client registration, PKCE S256, refresh
tokens that rotate). Standard library only; runs on Mac, Linux and Windows.

    python3 tests/oauth_mcp.py        prints its port on the first line, then serves until killed

TOKEN_LIFETIME (seconds, default 3600) is how long an access token lasts. The /authorize page approves at once, the way a
signed-in user clicking Allow would. Test-only endpoints: GET /debug/stats (counts and every token issued, so a test can
check none of them leaked), POST /debug/revoke-access-tokens (the next request with an old token gets a 401).

Tools: `whoami` (reads), `send_note` (can't be taken back). tools/call answers as an event stream, everything else as
plain JSON, so both kinds of answer are exercised."""
import base64, hashlib, json, os, secrets, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlencode, urlparse

TOKEN_LIFETIME = int(os.environ.get("TOKEN_LIFETIME", "3600"))
lock = threading.Lock()
clients = {}  # client_id -> redirect_uris
codes = {}  # code -> dict(client_id, redirect_uri, challenge, resource)
access_tokens = {}  # token -> expires_at
refresh_tokens = {}  # token -> client_id
stats = {"registrations": 0, "codes": 0, "refreshes": 0, "issued": [], "resources": []}


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    @property
    def base(self):
        return "http://127.0.0.1:%d" % self.server.server_address[1]

    def send_json(self, status, body, headers=None):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        for name, value in (headers or {}).items():
            self.send_header(name, value)
        self.end_headers()
        self.wfile.write(data)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/.well-known/oauth-protected-resource/mcp":
            return self.send_json(200, {"resource": self.base + "/mcp", "authorization_servers": [self.base], "scopes_supported": ["notes"]})
        if url.path == "/.well-known/oauth-authorization-server":
            return self.send_json(200, {"issuer": self.base, "authorization_endpoint": self.base + "/authorize", "token_endpoint": self.base + "/token",
                                        "registration_endpoint": self.base + "/register", "code_challenge_methods_supported": ["S256"],
                                        "grant_types_supported": ["authorization_code", "refresh_token"], "response_types_supported": ["code"]})
        if url.path == "/authorize":
            query = {key: values[0] for key, values in parse_qs(url.query).items()}
            with lock:
                known = clients.get(query.get("client_id"))
            if not known or query.get("redirect_uri") not in known:
                return self.send_json(400, {"error": "invalid_request", "error_description": "unknown client or redirect"})
            if query.get("code_challenge_method") != "S256" or not query.get("code_challenge") or query.get("response_type") != "code":
                return self.send_json(400, {"error": "invalid_request", "error_description": "PKCE S256 required"})
            code = "code-" + secrets.token_urlsafe(16)
            with lock:
                codes[code] = {"client_id": query["client_id"], "redirect_uri": query["redirect_uri"], "challenge": query["code_challenge"], "resource": query.get("resource")}
                stats["codes"] += 1
                stats["resources"].append(query.get("resource"))
            self.send_response(302)
            self.send_header("Location", query["redirect_uri"] + "?" + urlencode({"code": code, "state": query.get("state", "")}))
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        if url.path == "/debug/stats":
            with lock:
                return self.send_json(200, stats)
        self.send_json(404, {"error": "not found"})

    def issue_tokens(self, client_id):
        access = "at-" + secrets.token_urlsafe(24)
        refresh = "rt-" + secrets.token_urlsafe(24)
        with lock:
            access_tokens[access] = time.time() + TOKEN_LIFETIME
            refresh_tokens[refresh] = client_id
            stats["issued"] += [access, refresh]
        return self.send_json(200, {"access_token": access, "token_type": "Bearer", "expires_in": TOKEN_LIFETIME, "refresh_token": refresh, "scope": "notes"})

    def do_POST(self):
        url = urlparse(self.path)
        body = self.read_body()
        if url.path == "/register":
            request = json.loads(body or b"{}")
            client_id = "client-" + secrets.token_urlsafe(8)
            with lock:
                clients[client_id] = request.get("redirect_uris", [])
                stats["registrations"] += 1
            return self.send_json(201, {"client_id": client_id, "redirect_uris": request.get("redirect_uris", []), "token_endpoint_auth_method": "none"})
        if url.path == "/token":
            form = {key: values[0] for key, values in parse_qs(body.decode()).items()}
            if form.get("grant_type") == "authorization_code":
                with lock:
                    grant = codes.pop(form.get("code", ""), None)
                if not grant or grant["client_id"] != form.get("client_id") or grant["redirect_uri"] != form.get("redirect_uri"):
                    return self.send_json(400, {"error": "invalid_grant"})
                challenge = base64.urlsafe_b64encode(hashlib.sha256(form.get("code_verifier", "").encode()).digest()).rstrip(b"=").decode()
                if challenge != grant["challenge"]:
                    return self.send_json(400, {"error": "invalid_grant", "error_description": "PKCE check failed"})
                return self.issue_tokens(grant["client_id"])
            if form.get("grant_type") == "refresh_token":
                with lock:
                    client_id = refresh_tokens.pop(form.get("refresh_token", ""), None)  # rotates: each one works once
                    if client_id:
                        stats["refreshes"] += 1
                if not client_id or client_id != form.get("client_id"):
                    return self.send_json(400, {"error": "invalid_grant"})
                return self.issue_tokens(client_id)
            return self.send_json(400, {"error": "unsupported_grant_type"})
        if url.path == "/debug/revoke-access-tokens":
            with lock:
                access_tokens.clear()
            return self.send_json(200, {"ok": True})
        if url.path == "/mcp":
            token = (self.headers.get("Authorization") or "")[len("Bearer "):]
            with lock:
                expires_at = access_tokens.get(token)
            if not expires_at or expires_at < time.time():
                return self.send_json(401, {"error": "invalid_token"}, {"WWW-Authenticate": 'Bearer error="invalid_token", resource_metadata="%s/.well-known/oauth-protected-resource/mcp"' % self.base})
            message = json.loads(body or b"{}")
            method, request_id = message.get("method"), message.get("id")
            if request_id is None:
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if method == "initialize":
                return self.send_json(200, {"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}},
                                                                                      "serverInfo": {"name": "stand-in-notes", "version": "1"}}},
                                      {"Mcp-Session-Id": "session-1"})
            if method == "tools/list":
                text_input = {"type": "object", "properties": {"text": {"type": "string"}}}
                return self.send_json(200, {"jsonrpc": "2.0", "id": request_id, "result": {"tools": [
                    {"name": "whoami", "description": "Who is signed in.", "inputSchema": {"type": "object"}, "annotations": {"readOnlyHint": True}},
                    {"name": "send_note", "description": "Sends a note.", "inputSchema": text_input}]}})
            if method == "tools/call":
                name = message.get("params", {}).get("name")
                text = "signed in as stand-in user" if name == "whoami" else "sent: " + str(message.get("params", {}).get("arguments", {}).get("text"))
                events = ('event: message\ndata: {"jsonrpc":"2.0","method":"notifications/progress","params":{"progress":1}}\n\n'
                          "event: message\ndata: " + json.dumps({"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": text}]}}) + "\n\n").encode()
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Content-Length", str(len(events)))
                self.end_headers()
                self.wfile.write(events)
                return
            return self.send_json(200, {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}})
        self.send_json(404, {"error": "not found"})


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
print(server.server_address[1], flush=True)
server.serve_forever()
