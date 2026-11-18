"""A stand-in for the Anthropic Messages API, for local runs and CI without an API key or credit.

It answers POST /v1/messages in the real wire format (server-sent events when `stream` is true) with a
deterministic suggestion built from the last transcript line in the prompt. It is not a model and says
nothing about suggestion quality; it only proves the plumbing: backend -> SSE -> gateways -> browser.
"""
import json
import re
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

VAGUE_WORDS = ("some ", "stuff", "things", "a lot", "you know", "kind of", "cuts", "here and there")


def reply_for(prompt: str) -> str:
    lines = re.findall(r"^(\d+) \| (.*?) \| (.*)$", prompt, flags=re.M)
    if not lines:
        return ""
    seq, _speaker, text = lines[-1]
    words = text.split()
    if len(words) < 4:
        return ""
    quote = " ".join(words[:6]).rstrip(".,;")
    if any(w in text.lower() for w in VAGUE_WORDS):
        kind, line = "vague", f"Can you give one specific example of \"{quote}\"?"
    else:
        kind, line = "follow_up", f"What happened next after \"{quote}\"?"
    return json.dumps({"type": kind, "line": int(seq), "quote": quote, "text": line}) + "\n"


def sse(event: str, data: dict) -> bytes:
    return f"event: {event}\ndata: {json.dumps(data)}\n\n".encode()


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        print(fmt % args, flush=True)

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        prompt = "".join(m["content"] if isinstance(m["content"], str) else "".join(
            b.get("text", "") for b in m["content"]) for m in body.get("messages", []))
        is_summary = "New lines to fold in" in prompt
        text = "Summary: the interviewee discussed budget cuts." if is_summary else reply_for(prompt)
        message = {"id": "msg_fake", "type": "message", "role": "assistant", "model": body.get("model", "fake"),
                   "content": [], "stop_reason": None, "stop_sequence": None,
                   "usage": {"input_tokens": 1, "output_tokens": 1}}
        if not body.get("stream"):
            message.update(content=[{"type": "text", "text": text}], stop_reason="end_turn")
            payload = json.dumps(message).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Transfer-Encoding", "chunked")
        self.end_headers()

        def chunk(data: bytes):
            self.wfile.write(f"{len(data):x}\r\n".encode() + data + b"\r\n")
            self.wfile.flush()

        chunk(sse("message_start", {"type": "message_start", "message": message}))
        chunk(sse("content_block_start", {"type": "content_block_start", "index": 0,
                                          "content_block": {"type": "text", "text": ""}}))
        for i in range(0, len(text), 24):
            time.sleep(0.02)
            chunk(sse("content_block_delta", {"type": "content_block_delta", "index": 0,
                                              "delta": {"type": "text_delta", "text": text[i:i + 24]}}))
        chunk(sse("content_block_stop", {"type": "content_block_stop", "index": 0}))
        chunk(sse("message_delta", {"type": "message_delta",
                                    "delta": {"stop_reason": "end_turn", "stop_sequence": None},
                                    "usage": {"output_tokens": 20}}))
        chunk(sse("message_stop", {"type": "message_stop"}))
        self.wfile.write(b"0\r\n\r\n")
        self.wfile.flush()


if __name__ == "__main__":
    ThreadingHTTPServer(("0.0.0.0", 8080), Handler).serve_forever()
