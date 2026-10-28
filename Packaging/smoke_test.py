#!/usr/bin/env python3
"""End-to-end smoke test run on the CI Mac after packaging.

Launches the built app, talks to it through the real native messaging host exactly like
Chrome does (4-byte length + JSON on stdin/stdout), asks it to download a test file and
checks that the file arrives complete with macOS download metadata.
"""
import base64
import http.server
import json
import os
import plistlib
import shutil
import struct
import subprocess
import sys
import threading
import time
from pathlib import Path

APP = Path(sys.argv[1] if len(sys.argv) > 1 else "dist/MDM.app").resolve()
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


def search_test():
    """The torrent search tab's sources, run by the app itself (--search-test)."""
    exe = APP / "Contents/MacOS/IDMMac"
    for q in ["ubuntu", "night of the living dead"]:
        try:
            out = subprocess.run([str(exe), "--search-test", q], capture_output=True, text=True, timeout=150)
        except subprocess.TimeoutExpired:
            fail(f"torrent search '{q}' hung")
        lines = out.stdout.splitlines()
        print(f"search '{q}': exit={out.returncode}, {sum(l.startswith('RESULT') for l in lines)} results")
        for l in lines[:6] + [l for l in lines if l.startswith("ERROR")]:
            print("   ", l[:200])
        sources = {l.split("\t")[1] for l in lines if l.startswith("RESULT")}
        print("    sources:", sources)
        if out.returncode != 0:
            fail(f"torrent search '{q}' found nothing")


class LocalFiles(http.server.BaseHTTPRequestHandler):
    """/forbidden always answers 403; /norange answers 403 to Range requests but sends the file to a plain GET."""
    BODY = os.urandom(300_000)

    def do_GET(self):
        if self.path.startswith("/forbidden") or (self.path.startswith("/norange") and self.headers.get("Range")):
            self.send_response(403)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(len(self.BODY)))
        self.end_headers()
        self.wfile.write(self.BODY)

    def log_message(self, *args):
        pass


def safari_refusal_test():
    """A Safari download the server refuses to give MDM stays with Safari (its partial copy is not deleted)
    and shows in MDM's list as failed with the reason, instead of vanishing. A server that only refuses
    Range requests still gives MDM the file."""
    server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), LocalFiles)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    base = f"http://127.0.0.1:{server.server_port}"

    def safari_download(name, target):
        d = Path.home() / "Downloads" / f"{name}.download"
        d.mkdir(parents=True, exist_ok=True)
        plistlib.dump({"DownloadEntryURL": target, "DownloadEntryPath": str(d)}, open(d / "Info.plist", "wb"))
        return d

    def wait(target, states, seconds=40):
        deadline = time.time() + seconds
        while time.time() < deadline:
            time.sleep(2)
            try:
                rec = next((r for r in json.loads(DB.read_text()) if r.get("url") == target), None)
            except (ValueError, OSError):
                rec = None
            if rec and rec.get("state") in states:
                return rec
        return rec

    refused = f"{base}/forbidden/file.bin"
    rdir = safari_download("refused.bin", refused)
    rec = wait(refused, ("downloading",))
    print("safari refused:", rec and rec.get("state"), rec and rec.get("error"), "bundle left:", rdir.exists())
    if not rec or rec.get("state") != "downloading" or not rec.get("safariMirror"):
        fail("a refused Safari takeover was not mirrored in the list")
    if not rdir.exists():
        fail("Safari's own copy was deleted although MDM could not download the file")
    # Safari finishes: the bundle turns into the finished file and the mirrored row completes.
    (Path.home() / "Downloads" / "refused.bin").write_bytes(b"done")
    shutil.rmtree(rdir)
    rec = wait(refused, ("completed",), 20)
    print("safari mirror finished:", rec and rec.get("state"))
    if not rec or rec.get("state") != "completed":
        fail("a mirrored Safari download did not complete when Safari finished")

    norange = f"{base}/norange/file.bin"
    ndir = safari_download("norange.bin", norange)
    rec = wait(norange, ("completed", "failed"))
    print("server without Range:", rec and rec.get("state"), rec and rec.get("error"), "bundle left:", ndir.exists())
    if not rec or rec.get("state") != "completed" or ndir.exists():
        fail("a server that refuses Range requests was not downloaded with a plain request")
    # Safari reuses the bundle name of a finished download; the second one must be noticed too.
    again = f"{base}/norange/again.bin"
    adir = safari_download("norange.bin", again)
    rec = wait(again, ("completed", "failed"))
    print("same bundle name again:", rec and rec.get("state"))
    if not rec or rec.get("state") != "completed":
        fail("a second Safari download with a reused bundle name was ignored")
    server.shutdown()

    # A YouTube stream (googlevideo.com/videoplayback) Safari downloads from a watch page goes to MDM's
    # video window (yt-dlp) instead of a direct fetch that YouTube refuses; Safari's copy is removed.
    ydir = Path.home() / "Downloads" / "videoplayback.download"
    ydir.mkdir(parents=True, exist_ok=True)
    yurl = "https://rr1---sn-test.googlevideo.com/videoplayback?expire=1&itag=18"
    ypart = ydir / "videoplayback"
    ypart.write_bytes(b"")
    froms = plistlib.dumps([yurl, "https://www.youtube.com/watch?v=jNQXAC9IVRw"], fmt=plistlib.FMT_BINARY).hex()
    subprocess.run(["xattr", "-wx", "com.apple.metadata:kMDItemWhereFroms", froms, str(ypart)], check=True)
    plistlib.dump({"DownloadEntryURL": yurl, "DownloadEntryPath": str(ydir)}, open(ydir / "Info.plist", "wb"))
    log = SUPPORT / "mdm.log"
    deadline = time.time() + 20
    while time.time() < deadline and ydir.exists():
        time.sleep(1)
    time.sleep(1)
    routed = log.exists() and "YouTube akışı, Safari'nin kopyası silindi" in log.read_text(errors="replace")
    print("youtube stream:", "bundle left:", ydir.exists(), "routed to video window:", routed)
    if ydir.exists() or not routed:
        fail("a YouTube stream Safari downloaded was not sent to the video window")

    # A stream from YouTube Studio ("İndir" of the owner's own video) is not a watch page: it is downloaded as
    # a file, never sent to yt-dlp (which would end at the sign-in page), and Safari keeps its copy on failure.
    sdir2 = Path.home() / "Downloads" / "studio-video.download"
    sdir2.mkdir(parents=True, exist_ok=True)
    surl2 = "https://rr2---sn-test.googlevideo.com/videoplayback?expire=1&itag=22&studio=1"
    spart = sdir2 / "studio-video"
    spart.write_bytes(b"")
    froms = plistlib.dumps([surl2, "https://studio.youtube.com/video/abc/edit"], fmt=plistlib.FMT_BINARY).hex()
    subprocess.run(["xattr", "-wx", "com.apple.metadata:kMDItemWhereFroms", froms, str(spart)], check=True)
    plistlib.dump({"DownloadEntryURL": surl2, "DownloadEntryPath": str(sdir2)}, open(sdir2 / "Info.plist", "wb"))
    rec = wait(surl2, ("failed", "completed"), 40)
    text = log.read_text(errors="replace") if log.exists() else ""
    print("studio stream:", rec and rec.get("state"), rec and rec.get("error"), "bundle left:", sdir2.exists())
    if not rec or "izleme sayfasından gelmiyor" not in text or "video penceresi açılıyor: https://studio" in text:
        fail("a YouTube Studio download was sent to the video window instead of being fetched as a file")
    if rec.get("state") == "failed" and not sdir2.exists():
        fail("Safari's copy of a refused Studio download was removed")


def torrent_test():
    """A Debian netinst torrent through the native host: rqbit must add it and start downloading."""
    import re
    import urllib.request
    base = "https://cdimage.debian.org/debian-cd/current/amd64/bt-cd/"
    html = urllib.request.urlopen(base, timeout=30).read().decode()
    names = re.findall(r'href="([^"]*netinst\.iso\.torrent)"', html)
    if not names:
        fail("no Debian netinst torrent found")
    turl = base + names[0]
    print("torrent:", turl)
    print("torrent reply:", talk([{"type": "url", "id": "t1", "url": turl, "userAgent": "Mozilla/5.0", "cookies": []}]))
    deadline = time.time() + 150
    rec = None
    while time.time() < deadline:
        time.sleep(4)
        try:
            rec = next((d for d in json.loads(DB.read_text()) if d.get("kind") == "torrent"), None)
        except (ValueError, OSError):
            continue
        if rec:
            print(f"  torrent state={rec['state']} {rec['receivedBytes']}/{rec['totalBytes']} peers={rec.get('connections')} "
                  f"hash={rec.get('torrentHash')} err={rec.get('error')}")
            if rec["state"] == "failed" or (rec.get("torrentHash") and rec["receivedBytes"] > 0):
                break
    log = SUPPORT / "rqbit.log"
    if log.exists():
        print("rqbit.log tail:", log.read_text()[-1500:])
    if not rec or rec["state"] == "failed" or not rec.get("torrentHash"):
        fail("torrent was not added to rqbit")
    if rec["receivedBytes"] <= 0:
        print("WARNING: no torrent data arrived in time (peers may be unreachable from CI)")


def archive_torrent_test():
    """An archive.org torrent (the one from the in-app search that stalled on a Mac): nobody seeds it over
    BitTorrent, so MDM must notice the stall and fetch it from the web seeds listed in the .torrent."""
    turl = "https://archive.org/download/RareTitanicFilm/RareTitanicFilm_archive.torrent"
    print("archive torrent reply:", talk([{"type": "url", "id": "t2", "url": turl, "userAgent": "Mozilla/5.0", "cookies": []}]))
    deadline = time.time() + 240
    rec = None
    while time.time() < deadline:
        time.sleep(5)
        try:
            rec = next((d for d in json.loads(DB.read_text()) if d.get("url") == turl), None)
        except (ValueError, OSError):
            continue
        if rec:
            print(f"  archive torrent state={rec['state']} {rec['receivedBytes']}/{rec['totalBytes']} "
                  f"peers={rec.get('connections')} webSeed={rec.get('torrentWebSeed')} note={rec.get('note')} err={rec.get('error')}")
            if rec["state"] in ("failed", "completed") or rec["receivedBytes"] > 0:
                break
    log = SUPPORT / "mdm.log"
    if log.exists():
        print("torrent log:", "\n".join(l for l in log.read_text(errors="replace").splitlines() if "[torrent]" in l)[-4000:])
    if not rec or rec["state"] == "failed" or rec["receivedBytes"] <= 0:
        fail("archive.org torrent got no data (neither peers nor web seeds)")


def main():
    search_test()
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

    # Hover menu: a "probe" is answered later with the video's choices (not with "accepted").
    p = subprocess.Popen([str(HOST)], stdin=subprocess.PIPE, stdout=subprocess.PIPE)
    p.stdin.write(frame({"type": "probe", "id": "q1", "pageUrl": url, "mediaUrl": "", "userAgent": "Mozilla/5.0", "cookies": []}))
    p.stdin.flush()
    m = read_frame(p.stdout)
    p.stdin.close()
    p.kill()
    print("probe reply:", json.dumps(m)[:600] if m else m)
    if not m or m.get("type") != "info" or m.get("id") != "q1":
        fail("hover menu probe got no answer")

    # A download Safari started by itself ("name.download" with Info.plist) is taken over by the app.
    sdir = Path.home() / "Downloads" / "safari-test.bin.download"
    sdir.mkdir(parents=True, exist_ok=True)
    surl = url + ("&" if "?" in url else "?") + "safari=1"
    # Safari tags its partial file with [download URL, page URL]; the page becomes the Referer.
    part = sdir / "safari-test.bin"
    part.write_bytes(b"")
    froms = plistlib.dumps([surl, "https://example.com/page"], fmt=plistlib.FMT_BINARY).hex()
    subprocess.run(["xattr", "-wx", "com.apple.metadata:kMDItemWhereFroms", froms, str(part)], check=True)
    plistlib.dump({"DownloadEntryURL": surl, "DownloadEntryPath": str(sdir)}, open(sdir / "Info.plist", "wb"))
    deadline = time.time() + 30
    taken = None
    while time.time() < deadline and (not taken or sdir.exists()):
        time.sleep(2)
        try:
            taken = next((d for d in json.loads(DB.read_text()) if d.get("url") == surl), None)
        except (ValueError, OSError):
            pass
    print("safari takeover:", taken and taken.get("state"), "bundle left:", sdir.exists(),
          "headers:", taken and taken.get("headers"))
    if not taken or sdir.exists():
        fail("Safari's own download was not taken over")
    h = taken.get("headers") or {}
    if h.get("Referer") != "https://example.com/page" or "Safari/" not in h.get("User-Agent", ""):
        fail("Safari takeover did not carry Safari's user agent and the page as Referer")

    safari_refusal_test()

    torrent_test()
    archive_torrent_test()

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
        subprocess.run(["osascript", "-e", 'quit app "MDM"'], timeout=30)
        time.sleep(3)
        subprocess.run(["open", "-n", str(APP), "--args", "--demo"], timeout=30)
        time.sleep(10)
        subprocess.run(["osascript", "-e", 'tell application "MDM" to activate'], timeout=20)
        time.sleep(3)
        subprocess.run(["screencapture", "-x", "dist/screenshot.png"], timeout=30)
    except Exception as e:  # noqa: BLE001
        print("screenshot failed:", e)

    # Dock click: the running app must answer a "reopen" event by fronting its main window.
    reopen_ok = None
    try:
        log = SUPPORT / "mdm.log"
        before = log.read_text(errors="ignore") if log.exists() else ""
        subprocess.run(["osascript", "-e", 'tell application "MDM" to reopen'], timeout=20)
        time.sleep(3)
        text = log.read_text(errors="ignore") if log.exists() else ""
        new = text[len(before):] if text.startswith(before) else text
        print("reopen log:", new.strip().splitlines()[-3:])
        reopen_ok = "dock reopen" in new
    except Exception as e:  # noqa: BLE001
        print("reopen check skipped:", e)
    if reopen_ok is False:
        fail("Dock reopen event did not reach the app (no 'dock reopen' line in mdm.log)")

    # Pictures of the other windows for the installation guide (best effort).
    try:
        subprocess.run(["osascript", "-e", 'quit app "MDM"'], timeout=30)
        time.sleep(3)
        shots = (Path.cwd() / "dist/shots").resolve()
        subprocess.run(["open", "-n", str(APP), "--args", "--demo", "--snapshots", str(shots)], timeout=30)
        for _ in range(60):
            if (shots / "done").exists():
                break
            time.sleep(2)
        print("snapshots:", sorted(p.name for p in shots.glob("*.png")))
        subprocess.run(["osascript", "-e", 'quit app "MDM"'], timeout=30)
        if list(shots.glob("*.png")):
            subprocess.run(["zip", "-qr", str((Path.cwd() / "dist/shots.zip").resolve()), "."], cwd=shots, timeout=60)
    except Exception as e:  # noqa: BLE001
        print("snapshots failed:", e)

    print("SMOKE OK")


if __name__ == "__main__":
    main()
