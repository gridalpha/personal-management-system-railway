#!/usr/bin/env python3
"""Rewrite the two build-time values the SPA bakes in, on every container start.

Vite inlines both, so they are built against placeholder tokens and replaced here:

  __PMS_BACKEND_URL__      the API origin, which does not exist when the image is built
  __PMS_JWT_PUBLIC_KEY__   the key the SPA verifies every JWT signature against

The key is inserted as a JSON/JS string literal - real newlines escaped to \\n - because
that is how the bundler stored the original PEM. Doing this in Python rather than sed
keeps base64's '/' and the backslashes out of the replacement-escaping rules.
"""
import os
import pathlib
import sys

ROOT = pathlib.Path(sys.argv[1])
SUFFIXES = {".js", ".html", ".css", ".json", ".mjs"}


def replace(token: str, value: str) -> int:
    hits = 0
    for path in ROOT.rglob("*"):
        if not path.is_file() or path.suffix not in SUFFIXES:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        if token not in text:
            continue
        path.write_text(text.replace(token, value), encoding="utf-8")
        hits += 1
    return hits


backend = os.environ["PMS_BACKEND_URL"].rstrip("/")
print(f"[substitute] backend url -> {backend} ({replace('__PMS_BACKEND_URL__', backend)} file(s))")

pem = os.environ.get("PMS_JWT_PUBLIC_KEY", "").strip()
if pem:
    escaped = pem.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n")
    print(f"[substitute] jwt public key -> {replace('__PMS_JWT_PUBLIC_KEY__', escaped)} file(s)")
else:
    print("[substitute] no jwt public key supplied yet")
