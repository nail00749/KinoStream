#!/usr/bin/env python3
"""Validate the client configuration without printing its contents."""
import base64
import json
import sys
from pathlib import Path
from urllib.parse import urlparse

def fail(message):
    raise SystemExit(message)

path = Path(sys.argv[1])
if not path.is_file():
    fail("Missing .env: provide the public Supabase client configuration.")
values = {}
for raw in path.read_text().splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    if "=" not in line:
        fail("Invalid configuration line.")
    name, value = line.split("=", 1)
    name = name.strip()
    if name not in {"SUPABASE_URL", "SUPABASE_PUBLISHABLE_KEY"} or name in values:
        fail("Release configuration must contain only the two public Supabase settings.")
    values[name] = value.strip().strip("\"'")
url = urlparse(values.get("SUPABASE_URL", ""))
if url.scheme != "https" or not url.hostname or url.username or url.password:
    fail("Release requires a public HTTPS Supabase URL.")
key = values.get("SUPABASE_PUBLISHABLE_KEY", "")
if key.startswith("sb_publishable_") and key != "sb_publishable_your_key":
    pass
elif key.count(".") == 2:
    try:
        payload = key.split(".")[1]
        claims = json.loads(base64.urlsafe_b64decode(payload + "=" * (-len(payload) % 4)))
    except Exception:
        fail("Invalid Supabase client key.")
    if claims.get("role") != "anon":
        fail("Only an anon or publishable Supabase key may be distributed.")
else:
    fail("Only an anon or publishable Supabase key may be distributed.")
print("Public client configuration validated; values are hidden.")
