# ABOUTME: Local stand-in for the Messages API so the oracle's throwaway-HOME claude can run turns with no login.
# ABOUTME: Keyed on the last user text: SLOWTOOL -> a 30 s Bash call then a reply, SLOWTEXT -> 40 words streamed over 20 s, else "ok". Never logs headers.
import json, sys, time, threading, uuid
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler

LOG = sys.argv[2]
lock = threading.Lock()
# The Bash tool refuses `sleep 30; echo slept` (it points at Monitor), so the
# 30 s call sleeps in python.
SLOW_COMMAND = "python3 -c 'import time; time.sleep(30)'; echo slept"


def log(rec):
    rec["t"] = int(time.time() * 1000)
    with lock, open(LOG, "a") as f:
        f.write(json.dumps(rec) + "\n")


def user_text(msg):
    c = msg.get("content")
    if isinstance(c, str):
        return c, False
    parts, has_result = [], False
    for b in c or []:
        if b.get("type") == "text":
            parts.append(b.get("text", ""))
        elif b.get("type") == "tool_result":
            has_result = True
    # the newest text block only: earlier blocks of a merged user message hold command output
    return (parts[-1] if parts else ""), has_result


def plan(body):
    msgs = body.get("messages") or []
    tools = body.get("tools") or []
    last = next((m for m in reversed(msgs) if m.get("role") == "user"), {})
    text, has_result = user_text(last)
    if not tools:
        return "text", "ok", 0
    # a new prompt can share its user message with an earlier interrupted call's result
    if "SLOWTOOL" in text:
        return "tool", None, 0
    if has_result:
        return "text", "TOOLDONE after the tool.", 0
    if "SLOWTEXT" in text:
        return "text", " ".join(f"word{i}" for i in range(40)), 0.5
    return "text", "ok", 0


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("content-type", "application/json")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        log({"method": "GET", "path": self.path})
        self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": "stub"}})

    def do_POST(self):
        n = int(self.headers.get("content-length", "0"))
        raw = self.rfile.read(n)
        try:
            body = json.loads(raw or b"{}")
        except ValueError:
            body = {}
        path = self.path.split("?")[0]
        if path.endswith("/count_tokens"):
            log({"method": "POST", "path": path})
            return self._json(200, {"input_tokens": 100})
        if not path.endswith("/v1/messages"):
            log({"method": "POST", "path": path})
            return self._json(404, {"type": "error", "error": {"type": "not_found_error", "message": "stub"}})
        kind, text, delay = plan(body)
        msgs = body.get("messages") or []
        last = next((m for m in reversed(msgs) if m.get("role") == "user"), {})
        lt, _ = user_text(last)
        log({"method": "POST", "path": path, "stream": bool(body.get("stream")), "tools": len(body.get("tools") or []),
             "nmsgs": len(msgs), "kind": kind, "last_user": lt[-300:]})
        model = body.get("model", "claude-stub")
        mid = "msg_" + uuid.uuid4().hex[:20]
        usage = {"input_tokens": 100, "output_tokens": 5, "cache_read_input_tokens": 0, "cache_creation_input_tokens": 0}
        if kind == "tool":
            content = [{"type": "tool_use", "id": "toolu_" + uuid.uuid4().hex[:20], "name": "Bash",
                        "input": {"command": SLOW_COMMAND, "description": "Sleep thirty seconds"}}]
            stop = "tool_use"
        else:
            content = [{"type": "text", "text": text}]
            stop = "end_turn"
        if not body.get("stream"):
            return self._json(200, {"id": mid, "type": "message", "role": "assistant", "model": model,
                                    "content": content, "stop_reason": stop, "stop_sequence": None, "usage": usage})
        self.send_response(200)
        self.send_header("content-type", "text/event-stream")
        self.send_header("cache-control", "no-cache")
        self.end_headers()

        def ev(name, data):
            self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()

        try:
            ev("message_start", {"type": "message_start", "message": {"id": mid, "type": "message", "role": "assistant", "model": model,
                                                                       "content": [], "stop_reason": None, "stop_sequence": None, "usage": usage}})
            if kind == "tool":
                b = content[0]
                ev("content_block_start", {"type": "content_block_start", "index": 0,
                                           "content_block": {"type": "tool_use", "id": b["id"], "name": b["name"], "input": {}}})
                ev("content_block_delta", {"type": "content_block_delta", "index": 0,
                                           "delta": {"type": "input_json_delta", "partial_json": json.dumps(b["input"])}})
            else:
                ev("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}})
                words = text.split(" ")
                if delay:
                    for i, w in enumerate(words):
                        ev("content_block_delta", {"type": "content_block_delta", "index": 0,
                                                   "delta": {"type": "text_delta", "text": (w if i == 0 else " " + w)}})
                        time.sleep(delay)
                else:
                    ev("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}})
            ev("content_block_stop", {"type": "content_block_stop", "index": 0})
            ev("message_delta", {"type": "message_delta", "delta": {"stop_reason": stop, "stop_sequence": None}, "usage": {"output_tokens": 5}})
            ev("message_stop", {"type": "message_stop"})
        except (BrokenPipeError, ConnectionResetError):
            log({"note": "client closed stream", "id": mid})


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
