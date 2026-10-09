#!/usr/bin/env python3
"""Render the synthetic gate B fixture states for offline guide replay.

Serves Tests/NativeFixtures on 127.0.0.1, drives a headless browser with playwright-cli, and writes one PNG per
state plus manifest.json (state images and element boxes in image pixels) into OUT_DIR. OUT_DIR must be a scratch
directory outside the repository; the images show only the synthetic fixture and are deleted with it.

Usage: scripts/render-guide-fixture.py OUT_DIR
"""
from __future__ import annotations

import functools
import http.server
import json
import subprocess
import sys
import threading
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FIXTURES = ROOT / "Tests" / "NativeFixtures"
DEFINITION = FIXTURES / "workflow-replay.json"
SESSION = "-s=clicky-replay"
VIEWPORT = (1100, 900)

# Each action reproduces the fixture's own handler deterministically (the 2 s Options delay is applied directly).
ACTIONS: dict[str, str] = {
    "new": "document.getElementById('new').click()",
    "q3": "document.getElementById('q3').dispatchEvent(new MouseEvent('dblclick', {bubbles: true}))",
    "options": "document.getElementById('options').click()",
    "optionsLoaded": "document.getElementById('spinner').hidden = true; document.getElementById('optionsPanel').hidden = false",
    "charts": "document.getElementById('charts').click()",
    "summary": "document.getElementById('summary').dispatchEvent(new MouseEvent('dblclick', {bubbles: true}))",
    "publish": "document.getElementById('publish').click()",
}
BOXES_JS = """() => JSON.stringify(Object.fromEntries(
  ['new','archive','delete','q2','q3','options','charts','summary','appendix','publish'].map(id => {
    const element = document.getElementById(id);
    // A checkbox's label is part of its click target.
    const r = (element.closest('label') || element).getBoundingClientRect();
    return ['#' + id, [r.x * devicePixelRatio, r.y * devicePixelRatio, r.width * devicePixelRatio, r.height * devicePixelRatio]];
  })))"""


# playwright-cli writes page snapshots into its working directory; keep them in the scratch OUT_DIR.
WORKDIR: Path = Path.cwd()


def cli(*args: str) -> str:
    result = subprocess.run(["playwright-cli", SESSION, *args], capture_output=True, text=True, timeout=60, cwd=WORKDIR)
    if result.returncode != 0 or "### Error" in result.stdout:
        raise RuntimeError(f"playwright-cli {args[0]} failed: {result.stdout[-400:]} {result.stderr[-400:]}")
    return result.stdout


def eval_json(script: str) -> dict[str, list[float]]:
    output = cli("eval", script)
    start = output.index('"{') if '"{' in output else output.index("{")
    text = output[start:].split("\n", 1)[0].strip()
    return json.loads(json.loads(text) if text.startswith('"') else text)


def main(out_dir: Path) -> None:
    if ROOT in out_dir.resolve().parents or out_dir.resolve() == ROOT:
        sys.exit("OUT_DIR must be outside the repository")
    out_dir.mkdir(parents=True, exist_ok=True)
    global WORKDIR
    WORKDIR = out_dir
    definition = json.loads(DEFINITION.read_text())
    handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=str(FIXTURES))
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    url = f"http://127.0.0.1:{server.server_address[1]}/{definition['fixture']}"
    states: dict[str, dict[str, object]] = {}
    try:
        cli("open", url)
        cli("resize", str(VIEWPORT[0]), str(VIEWPORT[1]))
        for name, state in definition["states"].items():
            cli("goto", url)
            cli("mousemove", "1", "1")
            for action in state["script"]:
                cli("eval", "() => { " + ACTIONS[action] + " }")
            if "hover" in state:
                cli("hover", state["hover"])
            image = out_dir / f"{name}.png"
            cli("screenshot", "--filename", str(image))
            states[name] = {"png": str(image), "boxes": eval_json(BOXES_JS)}
    finally:
        subprocess.run(["playwright-cli", SESSION, "close"], capture_output=True, timeout=60, cwd=WORKDIR)
        server.shutdown()
    manifest = {**definition, "states": states}
    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=1))
    print(f"Rendered {len(states)} states into {out_dir}")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    main(Path(sys.argv[1]))
