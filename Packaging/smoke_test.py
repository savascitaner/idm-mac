#!/usr/bin/env python3
"""End-to-end smoke test run on the CI Mac after packaging.

Launches the built app, talks to it through the real native messaging host exactly like
Chrome does (4-byte length + JSON on stdin/stdout), asks it to download a test file and
checks that the file arrives complete with macOS download metadata.
"""
import base64
import json
import os
import plistlib
import struct
import subprocess
import sys
import time
from pathlib import Path

APP = Path(sys.argv[1] if len(sys.argv) > 1 else "dist/IDM Mac.app").resolve()
HOST = APP / "Contents/MacOS/IDMMacHost"
SUPPORT = Path.home() / "Library/Application Support/IDMMac"
DB = SUPPORT / "downloads.json"
URLS = [
    "https://proof.ovh.net/files/10Mb.dat",
    "https://ash-speed.hetzner.com/100MB.bin",
    "https://speed.cloudflare.com/__down?bytes=20000000",
]


def frame(obj):
    data = json.dumps(obj).encode()
    return struct.pack("<I", len(data)) + data


def read_frame(stream):
    header = stream.read(4)
    if len(header) < 4:
        return None
    (n,) = struct.unpack("<I", header)
    return json.loads(stream.read(n))


def talk(messages):
    """Starts the host like Chrome would, sends messages and returns the replies."""
    p = subprocess.Popen([str(HOST), "chrome-extension://test/"], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    replies = []
    for m in messages:
        p.stdin.write(frame(m))
        p.stdin.flush()
        replies.append(read_frame(p.stdout))
    p.stdin.close()
    p.wait(timeout=10)
    return replies


def fail(msg):
    print("SMOKE FAIL:", msg)
    if DB.exists():
        print(DB.read_text()[:4000])
    sys.exit(1)


def main():
    print("ping before launch:", talk([{"type": "ping", "id": "p0"}]))

    # The host must launch the app by itself when a real request comes in.
    url = None
    for u in URLS:
        try:
            subprocess.run(["curl", "-fsI", "--max-time", "10", u], check=True, capture_output=True)
            url = u
            break
        except subprocess.CalledProcessError:
            continue
    if not url:
        fail("no reachable test URL")
    print("test url:", url)

    replies = talk([{"type": "download", "id": "d1", "url": url, "filename": "", "referrer": "https://example.com/",
                     "userAgent": "Mozilla/5.0", "cookies": [{"name": "a", "value": "b", "domain": "example.com",
                                                               "path": "/", "secure": False, "httpOnly": False,
                                                               "hostOnly": True, "expirationDate": 0}]}])
    print("download reply:", replies)
    if not replies or not replies[0] or replies[0].get("type") != "accepted":
        fail("app did not accept the download")

    print("ping after launch:", talk([{"type": "ping", "id": "p1"}]))

    deadline = time.time() + 240
    rec = None
    while time.time() < deadline:
        time.sleep(3)
        if not DB.exists():
            continue
        try:
            items = json.loads(DB.read_text())
        except ValueError:
            continue
        rec = next((d for d in items if d.get("url", "").startswith(url.split("?")[0])), None) or (items[0] if items else None)
        if rec:
            print(f"  state={rec['state']} {rec['receivedBytes']}/{rec['totalBytes']} conns={rec.get('connections')}")
            if rec["state"] in ("completed", "failed"):
                break
    if not rec or rec["state"] != "completed":
        fail("download did not complete")

    path = Path(rec["finalPath"])
    size = path.stat().st_size
    print("file:", path, size)
    if rec["totalBytes"] > 0 and size != rec["totalBytes"]:
        fail(f"size mismatch {size} != {rec['totalBytes']}")
    xattrs = subprocess.run(["xattr", str(path)], capture_output=True, text=True).stdout
    print("xattrs:", xattrs.strip().replace("\n", ", "))
    if "com.apple.quarantine" not in xattrs:
        fail("quarantine attribute missing")
    if list(path.parent.glob("*.idmpart")):
        fail("leftover .idmpart file")

    # A server that answers with a web page instead of the file must be handed back to Chrome.
    p = subprocess.Popen([str(HOST)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    p.stdin.write(frame({"type": "download", "id": "h1", "url": "https://example.com/", "originalUrl": "https://example.com/",
                         "filename": "file.zip", "mime": "application/zip", "userAgent": "Mozilla/5.0", "cookies": []}))
    p.stdin.flush()
    got = []
    t0 = time.time()
    while time.time() - t0 < 60:
        m = read_frame(p.stdout)
        if m is None:
            break
        got.append(m)
        if m.get("type") == "fallback":
            break
    p.stdin.close()
    p.kill()
    print("html fallback:", got)
    if not any(m.get("type") == "fallback" for m in got):
        fail("HTML response was not handed back to the browser")

    # Safari extension: bundled and signed, and the idmmac:// bridge it uses reaches the app.
    appex = APP / "Contents/PlugIns/IDMMacSafari.appex"
    if not (appex / "Contents/Resources/manifest.json").exists():
        fail("Safari extension is not in the bundle")
    ent = subprocess.run(["codesign", "-d", "--entitlements", "-", "--xml", str(appex)], capture_output=True, text=True)
    print("appex entitlements:", ent.stdout.strip()[-300:])
    if "app-sandbox" not in ent.stdout:
        fail("Safari extension is not sandboxed")
    pk = subprocess.run(["pluginkit", "-m", "-v", "-i", "com.savascitaner.idmmac.Extension"], capture_output=True, text=True)
    print("pluginkit:", pk.stdout.strip() or pk.stderr.strip() or "(not listed)")

    token = plistlib.load(open(APP / "Contents/Info.plist", "rb"))["IDMBridgeToken"]
    if token != plistlib.load(open(appex / "Contents/Info.plist", "rb"))["IDMBridgeToken"]:
        fail("app and Safari extension have different bridge tokens")

    def bridge(tok, target):
        msg = {"type": "download", "id": "s1", "url": target, "filename": "", "referrer": "https://example.com/",
               "userAgent": "Mozilla/5.0 Safari", "cookies": []}
        d = base64.urlsafe_b64encode(json.dumps(msg).encode()).decode().rstrip("=")
        subprocess.run(["open", "-g", f"idmmac://message?t={tok}&d={d}"], check=True, timeout=30)

    def record_for(target):
        try:
            return next((r for r in json.loads(DB.read_text()) if r.get("url") == target), None)
        except (OSError, ValueError):
            return None

    sep = "&" if "?" in url else "?"
    bad = url + sep + "src=forged"
    bridge("wrongtoken", bad)
    good = url + sep + "src=safari"
    bridge(token, good)
    rec = None
    deadline = time.time() + 180
    while time.time() < deadline:
        time.sleep(3)
        rec = record_for(good)
        if rec and rec["state"] in ("completed", "failed"):
            break
    print("safari bridge:", rec and rec["state"])
    if not rec or rec["state"] != "completed":
        fail("download sent through the Safari bridge did not complete")
    if record_for(bad):
        fail("bridge accepted a message with a wrong token")

    ytdlp = SUPPORT / "bin/yt-dlp"
    if not ytdlp.exists():
        fail("yt-dlp was not installed into Application Support")
    out = subprocess.run([str(ytdlp), "--version"], capture_output=True, text=True, timeout=120)
    print("yt-dlp version:", out.stdout.strip(), out.stderr.strip()[-300:])
    if out.returncode != 0:
        fail("yt-dlp does not run")
    ff = APP / "Contents/Resources/bin/ffmpeg"
    out = subprocess.run([str(ff), "-version"], capture_output=True, text=True, timeout=60)
    print("ffmpeg:", out.stdout.splitlines()[0] if out.stdout else out.stderr[-300:])
    if out.returncode != 0:
        fail("ffmpeg does not run")

    deno = APP / "Contents/Resources/bin/deno"
    out = subprocess.run([str(ytdlp), "-v", "--simulate", "--no-playlist", "--js-runtimes", f"deno:{deno}",
                          "https://www.youtube.com/watch?v=jNQXAC9IVRw"], capture_output=True, text=True, timeout=180)
    runtimes = next((l for l in out.stderr.splitlines() if "JS runtimes" in l), "")
    print(runtimes)
    print("youtube probe exit:", out.returncode, out.stderr.strip().splitlines()[-1] if out.stderr.strip() else "")
    if not runtimes or "none" in runtimes:
        fail("yt-dlp does not see the bundled deno runtime")

    # Screenshot of the main window with sample downloads, for visual review (best effort).
    try:
        subprocess.run(["osascript", "-e", 'quit app "IDM Mac"'], timeout=30)
        time.sleep(3)
        subprocess.run(["open", "-n", str(APP), "--args", "--demo"], timeout=30)
        time.sleep(10)
        subprocess.run(["osascript", "-e", 'tell application "IDM Mac" to activate'], timeout=20)
        time.sleep(3)
        subprocess.run(["screencapture", "-x", "dist/screenshot.png"], timeout=30)
    except Exception as e:  # noqa: BLE001
        print("screenshot failed:", e)

    print("SMOKE OK")


if __name__ == "__main__":
    main()
