#!/usr/bin/env python3
"""Deterministic process fixture for cancellation, login and request routing."""
import json
import sys
import time

for line in sys.stdin:
    request = json.loads(line)
    command = request["command"]
    if command == "login":
        print(json.dumps({"id": request["id"], "type": "pairing", "url": "https://spotify.com/pair?code=TEST", "code": "TEST"}), flush=True)
        time.sleep(0.15)
    data = {"logged_in": command == "login"}
    if command == "request":
        data = {"path": request["path"], "items": []}
    print(json.dumps({"id": request["id"], "type": "response", "status": 200, "data": data, "error": ""}), flush=True)
    if command == "logout":
        break
