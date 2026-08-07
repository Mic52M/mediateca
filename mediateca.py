#!/usr/bin/env python3
"""
Mediateca — lettore multimediale locale con ripresa automatica.

Uso:
    python3 mediateca.py ~/Movies ~/Downloads --port 8777

Scansiona le cartelle indicate, genera anteprime con ffmpeg e ricorda
il punto esatto in cui hai interrotto ogni video (SQLite in ~/.mediateca).
"""

import argparse
import hashlib
import json
import mimetypes
import os
import re
import shutil
import sqlite3
import subprocess
import threading
import time
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import unquote, urlparse

VIDEO_EXT = {".mp4", ".m4v", ".mov", ".webm", ".mkv", ".avi", ".mpg", ".mpeg", ".ogv", ".ts", ".wmv", ".flv"}
SUB_EXT = [".vtt", ".srt"]
# Formati che il browser non sa decodificare nativamente: li segnaliamo nella UI.
RISKY_EXT = {".mkv", ".avi", ".wmv", ".flv", ".mpg", ".mpeg", ".ts"}

HOME = Path.home() / ".mediateca"
THUMBS = HOME / "thumbs"
DB_PATH = HOME / "library.db"

_db_lock = threading.Lock()
_thumb_locks = {}
_thumb_locks_guard = threading.Lock()

LIBRARY = {}      # id -> dict
LIB_LOCK = threading.Lock()
ROOTS = []


# --------------------------------------------------------------------------- db
def db():
    conn = sqlite3.connect(DB_PATH, timeout=30)
    conn.row_factory = sqlite3.Row
    return conn


def init_db():
    HOME.mkdir(parents=True, exist_ok=True)
    THUMBS.mkdir(parents=True, exist_ok=True)
    with db() as conn:
        conn.executescript("""
            CREATE TABLE IF NOT EXISTS progress (
                id        TEXT PRIMARY KEY,
                path      TEXT,
                position  REAL DEFAULT 0,
                duration  REAL DEFAULT 0,
                finished  INTEGER DEFAULT 0,
                updated   REAL DEFAULT 0
            );
            CREATE TABLE IF NOT EXISTS meta (
                id        TEXT PRIMARY KEY,
                path      TEXT,
                size      INTEGER,
                mtime     REAL,
                duration  REAL,
                width     INTEGER,
                height    INTEGER
            );
        """)


def vid_id(path: str) -> str:
    return hashlib.sha1(os.path.abspath(path).encode("utf-8")).hexdigest()[:16]


# ---------------------------------------------------------------------- ffprobe
def probe(path: str):
    """Durata e risoluzione, con cache su disco per non rilanciare ffprobe."""
    vid = vid_id(path)
    try:
        st = os.stat(path)
    except OSError:
        return None
    with _db_lock, db() as conn:
        row = conn.execute("SELECT * FROM meta WHERE id=?", (vid,)).fetchone()
        if row and row["size"] == st.st_size and abs(row["mtime"] - st.st_mtime) < 1:
            return {"duration": row["duration"], "width": row["width"], "height": row["height"]}

    duration, width, height = 0.0, 0, 0
    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries",
             "format=duration:stream=width,height", "-select_streams", "v:0",
             "-of", "json", path],
            capture_output=True, text=True, timeout=60,
        ).stdout
        data = json.loads(out or "{}")
        duration = float(data.get("format", {}).get("duration") or 0)
        streams = data.get("streams") or [{}]
        width = int(streams[0].get("width") or 0)
        height = int(streams[0].get("height") or 0)
    except Exception:
        pass

    with _db_lock, db() as conn:
        conn.execute(
            "INSERT OR REPLACE INTO meta (id,path,size,mtime,duration,width,height) VALUES (?,?,?,?,?,?,?)",
            (vid, path, st.st_size, st.st_mtime, duration, width, height),
        )
    return {"duration": duration, "width": width, "height": height}


def thumb_path(vid: str) -> Path:
    return THUMBS / f"{vid}.jpg"


def make_thumb(vid: str, path: str, duration: float) -> Path | None:
    dest = thumb_path(vid)
    if dest.exists() and dest.stat().st_size > 0:
        return dest
    with _thumb_locks_guard:
        lock = _thumb_locks.setdefault(vid, threading.Lock())
    with lock:
        if dest.exists() and dest.stat().st_size > 0:
            return dest
        seek = max(1.0, duration * 0.12) if duration else 3.0
        tmp = dest.with_suffix(".tmp.jpg")
        try:
            subprocess.run(
                ["ffmpeg", "-y", "-ss", str(seek), "-i", path, "-frames:v", "1",
                 "-vf", "scale=640:-2", "-q:v", "4", str(tmp)],
                capture_output=True, timeout=120,
            )
            if tmp.exists() and tmp.stat().st_size > 0:
                tmp.replace(dest)
                return dest
            tmp.unlink(missing_ok=True)
        except Exception:
            tmp.unlink(missing_ok=True)
    return None


# ---------------------------------------------------------------------- library
def find_subtitle(path: str):
    base = Path(path).with_suffix("")
    for ext in SUB_EXT:
        for cand in (Path(str(base) + ext), Path(str(base) + ".it" + ext), Path(str(base) + ".en" + ext)):
            if cand.exists():
                return str(cand)
    return None


def scan():
    found = {}
    for root in ROOTS:
        root = Path(root).expanduser()
        if not root.exists():
            continue
        for dirpath, dirnames, filenames in os.walk(root):
            dirnames[:] = [d for d in dirnames if not d.startswith(".") and d != "node_modules"]
            for name in filenames:
                if name.startswith("."):
                    continue
                ext = Path(name).suffix.lower()
                if ext not in VIDEO_EXT:
                    continue
                full = os.path.join(dirpath, name)
                try:
                    st = os.stat(full)
                except OSError:
                    continue
                if st.st_size < 200_000:      # scarta clip/frammenti minuscoli
                    continue
                vid = vid_id(full)
                found[vid] = {
                    "id": vid,
                    "path": full,
                    "title": Path(name).stem.replace("_", " ").replace(".", " ").strip(),
                    "folder": Path(dirpath).name,
                    "ext": ext,
                    "size": st.st_size,
                    "mtime": st.st_mtime,
                    "risky": ext in RISKY_EXT,
                    "subtitle": find_subtitle(full),
                    "duration": 0.0, "width": 0, "height": 0,
                }
    with LIB_LOCK:
        LIBRARY.clear()
        LIBRARY.update(found)

    def enrich():
        for vid, item in list(found.items()):
            info = probe(item["path"])
            if info:
                with LIB_LOCK:
                    if vid in LIBRARY:
                        LIBRARY[vid].update(info)
    threading.Thread(target=enrich, daemon=True).start()
    return len(found)


def library_payload():
    with _db_lock, db() as conn:
        rows = {r["id"]: dict(r) for r in conn.execute("SELECT * FROM progress")}
    with LIB_LOCK:
        items = [dict(v) for v in LIBRARY.values()]
    for it in items:
        p = rows.get(it["id"])
        it["position"] = p["position"] if p else 0.0
        it["finished"] = bool(p["finished"]) if p else False
        it["watched_at"] = p["updated"] if p else 0.0
        if not it["duration"] and p and p["duration"]:
            it["duration"] = p["duration"]
        it["has_subtitle"] = bool(it.pop("subtitle", None))
        it.pop("path", None)
    items.sort(key=lambda x: x["mtime"], reverse=True)
    return items


# ----------------------------------------------------------------------- server
class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    server_version = "Mediateca"

    def log_message(self, fmt, *args):
        pass

    # -- helpers
    def _send(self, code, body=b"", ctype="application/json; charset=utf-8", extra=None):
        if isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        for k, v in (extra or {}).items():
            self.send_header(k, v)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, obj, code=200):
        self._send(code, json.dumps(obj), "application/json; charset=utf-8")

    def _item(self, vid):
        with LIB_LOCK:
            return dict(LIBRARY[vid]) if vid in LIBRARY else None

    # -- routes
    def do_GET(self):
        path = urlparse(self.path).path
        try:
            if path == "/":
                return self._send(200, INDEX_HTML, "text/html; charset=utf-8")
            if path == "/api/library":
                return self._json({"items": library_payload(), "roots": [str(r) for r in ROOTS]})
            if path == "/api/scan":
                n = scan()
                return self._json({"ok": True, "count": n})
            if path.startswith("/thumb/"):
                return self.serve_thumb(unquote(path[len("/thumb/"):]))
            if path.startswith("/video/"):
                return self.serve_video(unquote(path[len("/video/"):]))
            if path.startswith("/sub/"):
                return self.serve_subtitle(unquote(path[len("/sub/"):]))
            return self._send(404, "not found", "text/plain")
        except BrokenPipeError:
            pass
        except ConnectionResetError:
            pass

    do_HEAD = do_GET

    def do_POST(self):
        path = urlparse(self.path).path
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b"{}"
        try:
            data = json.loads(raw or b"{}")
        except Exception:
            data = {}

        if path == "/api/progress":
            vid = data.get("id")
            item = self._item(vid) if vid else None
            if not item:
                return self._json({"ok": False, "error": "unknown id"}, 404)
            pos = float(data.get("position") or 0)
            dur = float(data.get("duration") or 0)
            # "Visto" quando manca meno del 3% (con un minimo di 5s e un tetto di 60s),
            # così i video brevi non vengono archiviati al primo secondo.
            tail = min(60.0, max(5.0, dur * 0.03)) if dur else 0.0
            finished = 1 if (dur and pos >= dur - tail) or data.get("finished") else 0
            with _db_lock, db() as conn:
                conn.execute(
                    "INSERT OR REPLACE INTO progress (id,path,position,duration,finished,updated) VALUES (?,?,?,?,?,?)",
                    (vid, item["path"], pos, dur, finished, time.time()),
                )
            return self._json({"ok": True, "finished": bool(finished)})

        if path == "/api/reset":
            vid = data.get("id")
            with _db_lock, db() as conn:
                conn.execute("DELETE FROM progress WHERE id=?", (vid,))
            return self._json({"ok": True})

        return self._send(404, "not found", "text/plain")

    # -- static-ish
    def serve_thumb(self, name):
        vid = name.split(".")[0]
        item = self._item(vid)
        if not item:
            return self._send(404, b"", "text/plain")
        dest = make_thumb(vid, item["path"], item.get("duration") or 0)
        if not dest:
            return self._send(404, b"", "text/plain")
        body = dest.read_bytes()
        self._send(200, body, "image/jpeg", {"Cache-Control": "public, max-age=604800"})

    def serve_subtitle(self, name):
        vid = name.split(".")[0]
        item = self._item(vid)
        sub = item and find_subtitle(item["path"])
        if not sub:
            return self._send(404, b"", "text/plain")
        text = Path(sub).read_text(encoding="utf-8", errors="replace")
        if sub.lower().endswith(".srt"):
            text = "WEBVTT\n\n" + re.sub(r"(\d{2}:\d{2}:\d{2}),(\d{3})", r"\1.\2", text)
        self._send(200, text, "text/vtt; charset=utf-8")

    def serve_video(self, name):
        vid = name.split("?")[0]
        item = self._item(vid)
        if not item or not os.path.exists(item["path"]):
            return self._send(404, b"", "text/plain")
        path = item["path"]
        size = os.path.getsize(path)
        ctype = mimetypes.guess_type(path)[0] or "video/mp4"
        if path.lower().endswith(".mkv"):
            ctype = "video/x-matroska"

        rng = self.headers.get("Range")
        start, end = 0, size - 1
        status = 200
        if rng:
            m = re.match(r"bytes=(\d*)-(\d*)", rng.strip())
            if m:
                s, e = m.group(1), m.group(2)
                if s:
                    start = int(s)
                    end = int(e) if e else size - 1
                else:                                  # suffix range: bytes=-N
                    start = max(0, size - int(e or 0))
                if start >= size:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{size}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    return
                end = min(end, size - 1)
                status = 206

        length = end - start + 1
        self.send_response(status)
        self.send_header("Content-Type", ctype)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Length", str(length))
        if status == 206:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if self.command == "HEAD":
            return
        with open(path, "rb") as f:
            f.seek(start)
            remaining = length
            while remaining > 0:
                chunk = f.read(min(262144, remaining))
                if not chunk:
                    break
                self.wfile.write(chunk)
                remaining -= len(chunk)


INDEX_HTML = r"""<!doctype html>
<html lang="it">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Mediateca</title>
<style>
  *{box-sizing:border-box}
  :root{
    --bg:#0b0c0f; --card:#16181d; --card2:#1e2128; --fg:#f2f3f5; --muted:#8b90a0;
    --accent:#e50914; --radius:10px;
  }
  html,body{margin:0;height:100%}
  body{background:var(--bg);color:var(--fg);
       font:15px/1.5 -apple-system,BlinkMacSystemFont,"SF Pro Text",Inter,system-ui,sans-serif;
       -webkit-font-smoothing:antialiased}
  header{position:sticky;top:0;z-index:20;display:flex;gap:16px;align-items:center;
         padding:14px 28px;background:rgba(11,12,15,.86);backdrop-filter:blur(14px);
         border-bottom:1px solid #ffffff14}
  .logo{font-weight:800;letter-spacing:-.02em;font-size:20px;color:var(--accent)}
  .logo span{color:var(--fg)}
  input[type=search]{flex:1;max-width:380px;padding:9px 14px;border-radius:999px;border:1px solid #ffffff1f;
       background:#ffffff0d;color:var(--fg);outline:none;font-size:14px}
  input[type=search]:focus{border-color:#ffffff3d;background:#ffffff14}
  button.ghost{background:#ffffff0f;border:1px solid #ffffff1f;color:var(--fg);padding:8px 14px;
       border-radius:999px;cursor:pointer;font-size:13px}
  button.ghost:hover{background:#ffffff1f}
  main{padding:24px 28px 80px}
  h2{font-size:19px;margin:34px 0 14px;font-weight:650;letter-spacing:-.01em}
  h2 small{color:var(--muted);font-weight:400;font-size:13px;margin-left:8px}
  .grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(230px,1fr));gap:18px}
  .card{background:var(--card);border-radius:var(--radius);overflow:hidden;cursor:pointer;
        border:1px solid #ffffff0f;transition:transform .16s ease,border-color .16s ease}
  .card:hover{transform:translateY(-3px);border-color:#ffffff33}
  .thumb{position:relative;aspect-ratio:16/9;background:#0f1115 center/cover no-repeat}
  .thumb img{width:100%;height:100%;object-fit:cover;display:block}
  .bar{position:absolute;left:0;bottom:0;height:3px;width:100%;background:#ffffff2b}
  .bar i{display:block;height:100%;background:var(--accent)}
  .badge{position:absolute;top:8px;right:8px;background:#000000b3;border-radius:6px;padding:2px 7px;
         font-size:11px;font-variant-numeric:tabular-nums}
  .warn{position:absolute;top:8px;left:8px;background:#b4530fdd;border-radius:6px;padding:2px 7px;font-size:11px}
  .done{position:absolute;top:8px;left:8px;background:#1a7f37dd;border-radius:6px;padding:2px 7px;font-size:11px}
  .meta{padding:10px 12px}
  .meta .t{font-size:14px;font-weight:550;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .meta .s{font-size:12px;color:var(--muted);margin-top:2px;
           white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .empty{color:var(--muted);padding:60px 0;text-align:center}

  #player{position:fixed;inset:0;background:#000;z-index:50;display:none;flex-direction:column}
  #player.on{display:flex}
  .pbar{display:flex;align-items:center;gap:14px;padding:12px 18px;background:#0b0c0fee;color:var(--fg)}
  .pbar .name{flex:1;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .pbar .hint{color:var(--muted);font-size:12px}
  video{flex:1;width:100%;min-height:0;background:#000}
  .toast{position:fixed;bottom:24px;left:50%;transform:translateX(-50%);background:#1e2128;
         border:1px solid #ffffff24;padding:10px 18px;border-radius:999px;font-size:13px;z-index:60;
         opacity:0;pointer-events:none;transition:opacity .25s}
  .toast.on{opacity:1}
</style>
</head>
<body>
<header>
  <div class="logo">MEDIA<span>TECA</span></div>
  <input type="search" id="q" placeholder="Cerca un video…" autocomplete="off">
  <button class="ghost" id="rescan">Riscansiona</button>
</header>

<main>
  <section id="continue"></section>
  <section id="all"></section>
</main>

<div id="player">
  <div class="pbar">
    <button class="ghost" id="close">← Libreria</button>
    <div class="name" id="pname"></div>
    <div class="hint">spazio = play · ←/→ 10s · ↑/↓ volume · F schermo intero · Esc esci</div>
  </div>
  <video id="v" controls playsinline preload="metadata"></video>
</div>

<div class="toast" id="toast"></div>

<script>
let ITEMS = [], current = null, saveTimer = null;
const $ = s => document.querySelector(s);
const video = $('#v');

const fmt = s => {
  s = Math.max(0, Math.round(s || 0));
  const h = Math.floor(s/3600), m = Math.floor(s%3600/60), x = s%60;
  return h ? `${h}:${String(m).padStart(2,'0')}:${String(x).padStart(2,'0')}`
           : `${m}:${String(x).padStart(2,'0')}`;
};

function toast(msg){
  const t = $('#toast'); t.textContent = msg; t.classList.add('on');
  clearTimeout(t._h); t._h = setTimeout(()=>t.classList.remove('on'), 2200);
}

function card(it){
  const pct = it.duration ? Math.min(100, it.position / it.duration * 100) : 0;
  const left = it.duration && it.position ? `restano ${fmt(it.duration - it.position)}` : fmt(it.duration);
  const el = document.createElement('div');
  el.className = 'card';
  el.innerHTML = `
    <div class="thumb">
      <img loading="lazy" src="/thumb/${it.id}.jpg" alt="" onerror="this.style.opacity=0">
      ${it.finished ? '<div class="done">Visto</div>' : ''}
      ${it.risky && !it.finished ? '<div class="warn">formato</div>' : ''}
      <div class="badge">${fmt(it.duration)}</div>
      ${pct > 0.5 ? `<div class="bar"><i style="width:${pct}%"></i></div>` : ''}
    </div>
    <div class="meta">
      <div class="t" title="${it.title.replace(/"/g,'&quot;')}">${it.title}</div>
      <div class="s">${it.folder} · ${left}</div>
    </div>`;
  el.onclick = () => play(it);
  return el;
}

function section(host, title, sub, items){
  host.innerHTML = '';
  if(!items.length) return;
  const h = document.createElement('h2');
  h.innerHTML = `${title}<small>${sub}</small>`;
  const g = document.createElement('div');
  g.className = 'grid';
  items.forEach(it => g.appendChild(card(it)));
  host.append(h, g);
}

function render(){
  const q = $('#q').value.trim().toLowerCase();
  const match = it => !q || it.title.toLowerCase().includes(q) || it.folder.toLowerCase().includes(q);
  const list = ITEMS.filter(match);
  const started = it => it.position > 15 || (it.duration && it.position > it.duration * 0.05);
  const cont = list.filter(it => !it.finished && started(it))
                   .sort((a,b) => b.watched_at - a.watched_at);
  const rest = list.filter(it => !cont.includes(it));
  section($('#continue'), 'Continua a guardare', `${cont.length} in corso`, cont);
  section($('#all'), q ? 'Risultati' : 'Tutta la libreria', `${rest.length} video`, rest);
  if(!list.length) $('#all').innerHTML = '<div class="empty">Nessun video trovato.</div>';
}

async function load(){
  const r = await fetch('/api/library');
  const d = await r.json();
  ITEMS = d.items;
  render();
}

function save(finished){
  if(!current) return;
  const body = JSON.stringify({
    id: current.id,
    position: video.currentTime,
    duration: video.duration || current.duration || 0,
    finished: !!finished
  });
  current.position = video.currentTime;
  current.duration = video.duration || current.duration;
  current.watched_at = Date.now()/1000;
  if(finished) current.finished = true;
  if(navigator.sendBeacon) navigator.sendBeacon('/api/progress', new Blob([body], {type:'application/json'}));
  else fetch('/api/progress', {method:'POST', body, keepalive:true});
}

function play(it){
  current = it;
  $('#pname').textContent = it.title;
  $('#player').classList.add('on');
  [...video.querySelectorAll('track')].forEach(t => t.remove());
  if(it.has_subtitle){
    const t = document.createElement('track');
    t.kind = 'subtitles'; t.label = 'Sottotitoli'; t.srclang = 'it';
    t.src = `/sub/${it.id}.vtt`; t.default = true;
    video.appendChild(t);
  }
  const resume = it.finished ? 0 : (it.position || 0);
  video.onloadedmetadata = () => {
    const dur = video.duration || it.duration || 0;
    if(resume > 5 && (!dur || resume < dur * 0.98)){
      video.currentTime = resume;
      toast(`Ripreso da ${fmt(resume)}`);
    }
    video.play().catch(()=>{});
  };
  video.src = `/video/${it.id}`;
  video.onerror = () => toast(it.risky
    ? 'Questo formato non è riproducibile dal browser (serve conversione).'
    : 'Impossibile riprodurre il file.');
  clearInterval(saveTimer);
  saveTimer = setInterval(() => { if(!video.paused) save(false); }, 5000);
}

function closePlayer(){
  if(current) save(false);
  clearInterval(saveTimer);
  video.pause(); video.removeAttribute('src'); video.load();
  $('#player').classList.remove('on');
  current = null;
  load();
}

video.addEventListener('pause', () => save(false));
video.addEventListener('ended', () => { save(true); closePlayer(); });
window.addEventListener('beforeunload', () => { if(current) save(false); });
document.addEventListener('visibilitychange', () => { if(document.hidden && current) save(false); });

$('#close').onclick = closePlayer;
$('#q').oninput = render;
$('#rescan').onclick = async () => { toast('Scansione…'); await fetch('/api/scan'); await load(); toast('Libreria aggiornata'); };

document.addEventListener('keydown', e => {
  if(e.target.tagName === 'INPUT') return;
  if(!$('#player').classList.contains('on')) return;
  const k = e.key;
  if(k === ' '){ e.preventDefault(); video.paused ? video.play() : video.pause(); }
  else if(k === 'ArrowRight'){ e.preventDefault(); video.currentTime += 10; }
  else if(k === 'ArrowLeft'){ e.preventDefault(); video.currentTime -= 10; }
  else if(k === 'ArrowUp'){ e.preventDefault(); video.volume = Math.min(1, video.volume + .1); }
  else if(k === 'ArrowDown'){ e.preventDefault(); video.volume = Math.max(0, video.volume - .1); }
  else if(k === 'f' || k === 'F'){ video.requestFullscreen?.(); }
  else if(k === 'Escape'){ closePlayer(); }
});

load();
setInterval(load, 60000);
</script>
</body>
</html>
"""


def main():
    ap = argparse.ArgumentParser(description="Mediateca — lettore locale con ripresa")
    ap.add_argument("roots", nargs="*", default=[str(Path.home() / "Movies")],
                    help="cartelle da scansionare (default: ~/Movies)")
    ap.add_argument("--port", type=int, default=8777)
    ap.add_argument("--no-open", action="store_true", help="non aprire il browser")
    args = ap.parse_args()

    if not shutil.which("ffprobe"):
        print("⚠️  ffmpeg/ffprobe non trovato: niente anteprime né durate. brew install ffmpeg")

    global ROOTS
    ROOTS = [Path(r).expanduser().resolve() for r in (args.roots or [Path.home() / "Movies"])]

    init_db()
    print("Scansione in corso…")
    n = scan()
    url = f"http://localhost:{args.port}/"
    print(f"✓ {n} video trovati in: {', '.join(str(r) for r in ROOTS)}")
    print(f"✓ Mediateca su {url}   (Ctrl+C per fermare)")
    print(f"  progressi salvati in {DB_PATH}")

    server = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    server.daemon_threads = True
    if not args.no_open:
        threading.Timer(1.0, lambda: webbrowser.open(url)).start()
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nChiuso.")


if __name__ == "__main__":
    main()
