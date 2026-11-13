#!/usr/bin/env python3
"""A tiny MCP server over stdio with one tool, `echo`, for proving on a real machine that Claude Code's connectors show up in
Theo's Connectors page (`claude mcp add --scope user theo-echo -- python tests/echo_mcp.py`). Standard library only."""
import json, sys


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    try:
        request = json.loads(line)
    except ValueError:
        continue
    method, request_id = request.get("method"), request.get("id")
    if request_id is None:
        continue  # a notification, such as notifications/initialized
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": request.get("params", {}).get("protocolVersion", "2025-06-18"),
                                                              "capabilities": {"tools": {}}, "serverInfo": {"name": "theo-echo", "version": "1.0.0"}}})
    elif method == "tools/list":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"tools": [{"name": "echo", "description": "Says back what it is given.",
                                                                         "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}}]}})
    elif method == "tools/call":
        text = request.get("params", {}).get("arguments", {}).get("text", "")
        send({"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": "echo: " + text}]}})
    else:
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}})
