#!/usr/bin/env python3
"""Drives one scripted interview through the edge gateway and prints what it measured.

Usage: suggestion_flow.py FRONTEND_URL TOKEN OTHER_USER_TOKEN
Exit codes: 0 all good, 1 a check failed. Output lines are `key=value`.
"""
import http.client
import json
import sys
import threading
import time
import urllib.parse

base, token, other = sys.argv[1], sys.argv[2], sys.argv[3]
u = urllib.parse.urlparse(base)


def call(method, path, body=None, tok=token):
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=15)
    headers = {"Authorization": f"Bearer {tok}"}
    data = None
    if body is not None:
        data = json.dumps(body)
        headers["Content-Type"] = "application/json"
    conn.request(method, path, data, headers)
    r = conn.getresponse()
    raw = r.read()
    return r.status, (json.loads(raw) if raw and r.getheader("Content-Type", "").startswith("application/") else raw)


status, session = call("POST", "/api/v1/sessions", {"title": "Smoke interview", "angle": "Budget cuts"})
assert status == 201, f"create session -> {status}"
sid = session["id"]
print(f"session={sid}")

# A second user must not see this session in any way.
for method, path in [("GET", f"/api/v1/sessions/{sid}/suggestions"),
                     ("POST", f"/api/v1/sessions/{sid}/utterances")]:
    code, _ = call(method, path, {"text": "intruder line here now", "startMs": 0, "endMs": 1} if method == "POST" else None, tok=other)
    print(f"other_user_{method.lower()}={code}")
    if code != 404:
        sys.exit(1)

received = []   # (monotonic time, event name, data)
opened = threading.Event()


def listen():
    conn = http.client.HTTPConnection(u.hostname, u.port, timeout=30)
    conn.request("GET", f"/api/v1/sessions/{sid}/suggestions/stream",
                 headers={"Authorization": f"Bearer {token}", "Accept": "text/event-stream"})
    r = conn.getresponse()
    print(f"stream_status={r.status} content_type={r.getheader('Content-Type')}")
    opened.set()
    event = None
    while True:
        line = r.readline()
        if not line:
            return
        line = line.decode().rstrip("\r\n")
        if line.startswith("event:"):
            event = line[6:].strip()
        elif line.startswith("data:") and event:
            received.append((time.monotonic(), event, json.loads(line[5:].strip())))
            event = None


threading.Thread(target=listen, daemon=True).start()
if not opened.wait(10):
    print("stream_open=timeout")
    sys.exit(1)
time.sleep(0.3)

sent = time.monotonic()
status, utterance = call("POST", f"/api/v1/sessions/{sid}/utterances", {
    "text": "Well, we had to make some cuts, you know, here and there, to keep things running.",
    "startMs": 0, "endMs": 6000})
assert status == 201 and utterance["seq"] == 1, f"utterance -> {status} {utterance}"

deadline = time.monotonic() + 15
while not received and time.monotonic() < deadline:
    time.sleep(0.02)
if not received:
    print("first_suggestion_ms=none")
    sys.exit(1)
first = received[0]
print(f"first_suggestion_ms={round((first[0] - sent) * 1000)}")
suggestion = first[2]
print(f"type={suggestion['type']} status={suggestion['status']}")

status, updated = call("PATCH", f"/api/v1/suggestions/{suggestion['id']}", {"status": "asked"})
print(f"patch_asked={status} now={updated.get('status') if isinstance(updated, dict) else updated}")
if status != 200 or updated.get("status") != "asked":
    sys.exit(1)
status, listed = call("GET", f"/api/v1/sessions/{sid}/suggestions")
if status != 200 or [s["status"] for s in listed] != ["asked"]:
    print(f"list={status} {listed}")
    sys.exit(1)
status, _ = call("PATCH", f"/api/v1/suggestions/{suggestion['id']}", {"status": "bogus"})
print(f"patch_bogus={status}")
if status != 400:
    sys.exit(1)
status, _ = call("PATCH", f"/api/v1/suggestions/{suggestion['id']}", {"status": "dismissed"}, tok=other)
print(f"other_user_patch={status}")
if status != 404:
    sys.exit(1)
