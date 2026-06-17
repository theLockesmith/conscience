#!/usr/bin/env python3
"""Room-tail Monitor body.

Loops `coord_wait_for_messages(room_id=...)` against the rag-mcp server
and prints one summary line per new peer message. Each printed line
becomes a `<task-notification>` event in Claude Code via the Monitor
tool. Idle iterations block server-side (Postgres LISTEN/NOTIFY) so they
cost essentially nothing.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import ssl
import sys
import time
import urllib.error
import urllib.request

DEFAULT_MCP_URL = "https://rag-mcp.aegis-hq.xyz/mcp"
DEFAULT_TOKEN_FILE = "~/.config/rag-mcp/token"
PROTO_VERSION = "2025-03-26"
USER_AGENT = "claude-room-listen/1"

HEADER_RE = re.compile(
    r"^###\s+\[(?P<kind>[^\]]+)\]\s+\*\*(?P<subject>.+?)\*\*\s+from\s+`(?P<sender>[^`]+)`"
)


def mcp_call(url, token, session_id, method, params=None, timeout=70.0):
    body = {"jsonrpc": "2.0", "id": int(time.time() * 1000), "method": method}
    if params is not None:
        body["params"] = params
    headers = {
        "Content-Type": "application/json",
        "Accept": "application/json, text/event-stream",
        "Authorization": "Bearer " + token,
        "User-Agent": USER_AGENT,
    }
    if session_id:
        headers["Mcp-Session-Id"] = session_id
    req = urllib.request.Request(
        url, data=json.dumps(body).encode(), headers=headers, method="POST"
    )
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=timeout, context=ctx) as resp:
        resp_sid = resp.headers.get("Mcp-Session-Id")
        raw = resp.read().decode()
        try:
            parsed = json.loads(raw)
        except json.JSONDecodeError:
            parsed = {"raw": raw}
        return parsed, resp_sid


def init_session(url, token):
    parsed, sid = mcp_call(url, token, None, "initialize", {
        "protocolVersion": PROTO_VERSION,
        "capabilities": {},
        "clientInfo": {"name": "room-listen", "version": "1"},
    }, timeout=15.0)
    if not sid:
        raise RuntimeError("server did not return Mcp-Session-Id on initialize")
    if "error" in parsed:
        raise RuntimeError("initialize failed: " + str(parsed["error"]))
    return sid


def parse_messages(text, self_session):
    out = []
    for line in text.splitlines():
        m = HEADER_RE.match(line.strip())
        if not m:
            continue
        sender = m.group("sender")
        if self_session and sender.startswith(self_session):
            continue
        out.append({
            "kind": m.group("kind"),
            "subject": m.group("subject"),
            "sender": sender,
        })
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--room-id", default=os.environ.get("ROOM_ID"))
    ap.add_argument("--mcp-url",
                    default=os.environ.get("RAG_MCP_URL", DEFAULT_MCP_URL))
    ap.add_argument("--token-file",
                    default=os.environ.get("RAG_MCP_TOKEN_FILE",
                                           DEFAULT_TOKEN_FILE))
    ap.add_argument("--self-session",
                    default=os.environ.get("SELF_SESSION"))
    ap.add_argument("--wait-seconds", type=int, default=50,
                    help="server-side LISTEN/NOTIFY wait per iteration")
    args = ap.parse_args()

    if not args.room_id:
        print("ERROR: --room-id or ROOM_ID required", file=sys.stderr)
        return 2

    token_path = os.path.expanduser(args.token_file)
    try:
        token = open(token_path).read().strip()
    except OSError as e:
        print("ERROR: token unreadable at " + token_path + ": " + str(e), file=sys.stderr)
        return 2

    try:
        sid = init_session(args.mcp_url, token)
    except Exception as e:
        print("ERROR: MCP init failed: " + str(e), file=sys.stderr)
        return 2

    consecutive_errors = 0
    while True:
        try:
            parsed, _ = mcp_call(
                args.mcp_url, token, sid, "tools/call",
                {"name": "coord_wait_for_messages",
                 "arguments": {"room_id": args.room_id,
                               "timeout_seconds": args.wait_seconds,
                               "limit": 10}},
                timeout=float(args.wait_seconds + 20),
            )
            consecutive_errors = 0
        except (urllib.error.URLError, TimeoutError) as e:
            consecutive_errors += 1
            print("WARN: transient " + type(e).__name__ + ": " + str(e),
                  file=sys.stderr, flush=True)
            if consecutive_errors >= 5:
                print("ERROR: 5 consecutive failures, giving up",
                      file=sys.stderr, flush=True)
                return 3
            time.sleep(min(30, 5 * consecutive_errors))
            try:
                sid = init_session(args.mcp_url, token)
            except Exception:
                pass
            continue

        if "error" in parsed:
            err = parsed["error"]
            if isinstance(err, dict) and err.get("code") == -32000:
                try:
                    sid = init_session(args.mcp_url, token)
                except Exception as e2:
                    print("WARN: re-init failed: " + str(e2), file=sys.stderr,
                          flush=True)
                    time.sleep(5)
                continue
            print("WARN: tool error: " + str(err), file=sys.stderr, flush=True)
            time.sleep(5)
            continue

        text = (parsed.get("result", {})
                       .get("content", [{}])[0]
                       .get("text", ""))
        if not text or text.startswith("No new messages"):
            continue

        msgs = parse_messages(text, args.self_session)
        if not msgs:
            continue

        for m in msgs:
            sender_short = m["sender"][:8]
            subj = m["subject"]
            if len(subj) > 110:
                subj = subj[:107] + "..."
            print("[room] [" + m["kind"] + "] " + subj + " (from " + sender_short + ")",
                  flush=True)


if __name__ == "__main__":
    sys.exit(main())
