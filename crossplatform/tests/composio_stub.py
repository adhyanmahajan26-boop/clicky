#!/usr/bin/env python3
"""A stand-in for Composio's API, for the connector hub's tests: tool-router sessions (POST /api/v3.1/tool_router/session),
each session's MCP server (streamable HTTP, the API key in x-api-key), connect links (POST …/session/<id>/link) and the
owner's connected accounts (GET /api/v3.1/connected_accounts). Shaped after Composio's documented API as of November 2026.
Standard library only; runs on Mac, Linux and Windows.

    python3 tests/composio_stub.py        prints its port on the first line, then serves until killed

The only key it takes is COMPOSIO_TEST_KEY (default `ck-test-key`). Test-only endpoints: GET /debug/stats (sessions made,
user ids, the slugs each run ran, and whether any request carried the key anywhere but x-api-key), POST
/debug/forget-sessions (every session so far stops working, as an expired one does)."""
import json, os, re, sys, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

KEY = os.environ.get("COMPOSIO_TEST_KEY", "ck-test-key")
TOOLKITS = {"gmail", "slack", "github", "googlecalendar", "notion"}
lock = threading.Lock()
sessions = {}  # session id -> user id
stats = {"sessionsMade": 0, "userIds": [], "sessionRequests": [], "ran": [], "keyOutsideItsHeader": False, "links": []}

TOOLS = [
    {"name": "COMPOSIO_SEARCH_TOOLS", "description": "Find the tools for a task.", "inputSchema": {"type": "object", "properties": {"queries": {"type": "array"}}}},
    {"name": "COMPOSIO_MANAGE_CONNECTIONS", "description": "Connect an app: gives a link to open.", "inputSchema": {"type": "object", "properties": {"toolkits": {"type": "array"}}}},
    {"name": "COMPOSIO_MULTI_EXECUTE_TOOL", "description": "Run app tools by slug.", "inputSchema": {"type": "object", "properties": {"tools": {"type": "array"}}}},
    {"name": "COMPOSIO_REMOTE_WORKBENCH", "description": "Run Python in a sandbox.", "inputSchema": {"type": "object", "properties": {"code_to_execute": {"type": "string"}}}},
]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    @property
    def base(self):
        return "http://127.0.0.1:%d" % self.server.server_address[1]

    def send_json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        return self.rfile.read(length) if length else b""

    def key_ok(self):
        for name, value in self.headers.items():
            if name.lower() != "x-api-key" and KEY in value:
                with lock:
                    stats["keyOutsideItsHeader"] = True
        return self.headers.get("x-api-key") == KEY

    def do_GET(self):
        url = urlparse(self.path)
        if url.path == "/debug/stats":
            with lock:
                return self.send_json(200, stats)
        if url.path == "/api/v3.1/connected_accounts":
            if not self.key_ok():
                return self.send_json(401, {"error": {"message": "Invalid API key"}})
            query = parse_qs(url.query)
            user = (query.get("user_ids") or ["?"])[0]
            items = [
                {"id": "ca_1", "user_id": user, "toolkit": {"slug": "gmail"}, "status": "ACTIVE", "is_disabled": False},
                {"id": "ca_2", "user_id": user, "toolkit": {"slug": "slack"}, "status": "ACTIVE", "is_disabled": False},
                {"id": "ca_3", "user_id": user, "toolkit": {"slug": "github"}, "status": "INITIALIZING", "is_disabled": False},
            ]
            return self.send_json(200, {"items": items, "next_cursor": None, "total_pages": 1, "current_page": 1, "total_items": len(items)})
        self.send_json(404, {"error": "not found"})

    def do_POST(self):
        url = urlparse(self.path)
        body = self.read_body()
        if url.path == "/debug/forget-sessions":
            with lock:
                sessions.clear()
            return self.send_json(200, {"ok": True})
        if not self.key_ok():
            return self.send_json(401, {"error": {"message": "Invalid API key"}})
        if url.path == "/api/v3.1/tool_router/session":
            request = json.loads(body or b"{}")
            if not request.get("user_id"):
                return self.send_json(400, {"error": {"message": "user_id is required"}})
            with lock:
                stats["sessionsMade"] += 1
                session_id = "trs_%d" % stats["sessionsMade"]
                sessions[session_id] = request["user_id"]
                stats["userIds"].append(request["user_id"])
                stats["sessionRequests"].append(request)
            return self.send_json(201, {"session_id": session_id, "mcp": {"type": "http", "url": "%s/tool_router/v3/%s/mcp" % (self.base, session_id)},
                                        "tool_router_tools": [tool["name"] for tool in TOOLS], "config_version": 0})
        link = re.fullmatch(r"/api/v3\.1/tool_router/session/([^/]+)/link", url.path)
        if link:
            with lock:
                known = link.group(1) in sessions
            if not known:
                return self.send_json(404, {"error": {"message": "session not found"}})
            toolkit = json.loads(body or b"{}").get("toolkit")
            if toolkit not in TOOLKITS:
                return self.send_json(400, {"error": {"message": "Toolkit not found"}})
            with lock:
                stats["links"].append(toolkit)
            return self.send_json(201, {"link_token": "lt_1", "redirect_url": "https://app.composio.dev/link/lt_%s" % toolkit, "connected_account_id": "ca_new"})
        mcp = re.fullmatch(r"/tool_router/v3/([^/]+)/mcp", url.path)
        if mcp:
            with lock:
                known = mcp.group(1) in sessions
            if not known:
                return self.send_json(404, {"error": {"message": "session not found"}})
            message = json.loads(body or b"{}")
            method, request_id = message.get("method"), message.get("id")
            if request_id is None:
                self.send_response(202)
                self.send_header("Content-Length", "0")
                self.end_headers()
                return
            if method == "initialize":
                return self.send_json(200, {"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "composio-stub", "version": "1"}}})
            if method == "tools/list":
                return self.send_json(200, {"jsonrpc": "2.0", "id": request_id, "result": {"tools": TOOLS}})
            if method == "tools/call":
                name = message["params"]["name"]
                arguments = message["params"].get("arguments") or {}
                if name == "COMPOSIO_MULTI_EXECUTE_TOOL":
                    slugs = [tool.get("tool_slug") for tool in arguments.get("tools", [])]
                    with lock:
                        stats["ran"].append(slugs)
                    text = "ran " + ", ".join(slugs)
                elif name == "COMPOSIO_MANAGE_CONNECTIONS":
                    text = "Open https://app.composio.dev/link/lt_chat to connect " + ", ".join(arguments.get("toolkits", []))
                else:
                    text = "ok " + name
                return self.send_json(200, {"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": text}], "isError": False}})
            return self.send_json(200, {"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "unknown method"}})
        self.send_json(404, {"error": "not found"})


if __name__ == "__main__":
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    print(server.server_address[1], flush=True)
    server.serve_forever()
