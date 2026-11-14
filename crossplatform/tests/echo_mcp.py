#!/usr/bin/env python3
"""A tiny MCP server over stdio, for proving on a real machine that Claude Code's connectors show up in Theo's Connectors page
(`claude mcp add --scope user theo-echo -- python tests/echo_mcp.py`), and for the connector hub's own tests
(`crates/theo-connectors/tests`). Standard library only.

Tools: `echo` (reads, and says so), `save_note` (changes something), `send_note` (can't be taken back), and `read_setting`
(says back the ECHO_SETTING environment variable, so a test can see a secret setting reach the server)."""
import json, os, sys


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
        text_input = {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}
        send({"jsonrpc": "2.0", "id": request_id, "result": {"tools": [
            {"name": "echo", "description": "Says back what it is given.", "inputSchema": text_input, "annotations": {"readOnlyHint": True}},
            {"name": "save_note", "description": "Pretends to save a note.", "inputSchema": text_input},
            {"name": "send_note", "description": "Pretends to send a note to someone.", "inputSchema": text_input,
             "annotations": {"readOnlyHint": False, "destructiveHint": True}},
            {"name": "read_setting", "description": "Says back ECHO_SETTING.", "inputSchema": {"type": "object", "properties": {}},
             "annotations": {"readOnlyHint": True}}]}})
    elif method == "tools/call":
        params = request.get("params", {})
        name, text = params.get("name"), params.get("arguments", {}).get("text", "")
        if name == "echo":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": "echo: " + text}]}})
        elif name in ("save_note", "send_note"):
            send({"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": name + ": " + text}]}})
        elif name == "read_setting":
            send({"jsonrpc": "2.0", "id": request_id, "result": {"content": [{"type": "text", "text": "setting: " + os.environ.get("ECHO_SETTING", "")}]}})
        else:
            send({"jsonrpc": "2.0", "id": request_id, "result": {"isError": True, "content": [{"type": "text", "text": "no tool " + str(name)}]}})
    else:
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "Method not found"}})
