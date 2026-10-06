#!/usr/bin/env python3
"""Generate Insight app-icon candidates through an OpenRouter image model.

The API key is read from $OPENROUTER_API_KEY and is never written to disk or to argv.

    OPENROUTER_API_KEY=... python3 scripts/gen_icon_ai.py <outdir> "<prompt>"
"""
import base64
import json
import os
import sys
import urllib.request


def generate(model: str, prompt: str) -> bytes:
    payload = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "modalities": ["image", "text"],
        "image_config": {"aspect_ratio": "1:1"},
    }
    request = urllib.request.Request(
        "https://openrouter.ai/api/v1/chat/completions",
        data=json.dumps(payload).encode(),
        headers={
            "Authorization": "Bearer " + os.environ["OPENROUTER_API_KEY"],
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(request, timeout=300) as response:
            body = json.load(response)
    except urllib.error.HTTPError as error:
        raise SystemExit("HTTP %d: %s" % (error.code, error.read().decode()[:800]))

    if "error" in body:
        raise SystemExit("API error: " + json.dumps(body["error"], ensure_ascii=False))

    message = body["choices"][0]["message"]
    images = message.get("images") or []
    if not images:
        raise SystemExit("no image returned; text was: " + str(message.get("content"))[:500])

    url = images[0]["image_url"]["url"]
    if url.startswith("data:"):
        return base64.b64decode(url.split(",", 1)[1])
    with urllib.request.urlopen(url, timeout=300) as response:
        return response.read()


if __name__ == "__main__":
    outdir = sys.argv[1]
    prompt = sys.argv[2]
    model = sys.argv[3] if len(sys.argv) > 3 else "google/gemini-3.1-flash-image"
    name = sys.argv[4] if len(sys.argv) > 4 else "icon"

    os.makedirs(outdir, exist_ok=True)
    path = os.path.join(outdir, name + ".png")
    with open(path, "wb") as handle:
        handle.write(generate(model, prompt))
    print(path, os.path.getsize(path), "bytes")