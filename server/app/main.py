"""Personal music API: search YouTube Music, fetch audio as m4a for the iOS app."""

import os
import re
import secrets
import shutil
import subprocess
import threading
import time
from pathlib import Path

import yt_dlp
from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.responses import FileResponse
from ytmusicapi import YTMusic

API_TOKEN = os.environ.get("API_TOKEN", "")
CACHE_DIR = Path(os.environ.get("CACHE_DIR", "/data/cache"))
CACHE_MAX_BYTES = int(float(os.environ.get("CACHE_MAX_GB", "2")) * 1024**3)
CACHE_TTL_SECONDS = int(float(os.environ.get("CACHE_TTL_HOURS", "24")) * 3600)
COOKIES_FILE = os.environ.get("COOKIES_FILE", "")

if not API_TOKEN:
    raise RuntimeError("API_TOKEN env var is required")

if not shutil.which("ffmpeg"):
    # Without ffmpeg yt-dlp can't fix YouTube's DASH m4a container (wrong duration/seeking on iOS).
    print("WARNING: ffmpeg not found; downloaded m4a files will not be fixed up", flush=True)

CACHE_DIR.mkdir(parents=True, exist_ok=True)
VIDEO_ID_RE = re.compile(r"^[A-Za-z0-9_-]{11}$")

app = FastAPI(title="musicapp", docs_url=None, redoc_url=None)
ytmusic = YTMusic()

_locks: dict[str, threading.Lock] = {}
_locks_guard = threading.Lock()


def require_token(authorization: str = Header(default="")) -> None:
    expected = f"Bearer {API_TOKEN}"
    if not secrets.compare_digest(authorization.encode(), expected.encode()):
        raise HTTPException(status_code=401, detail="unauthorized")


def _best_thumb(thumbs: list[dict] | None) -> str | None:
    if not thumbs:
        return None
    url = max(thumbs, key=lambda t: t.get("width", 0)).get("url")
    # Ask Google's image CDN for a larger square cover when possible.
    if url and "googleusercontent.com" in url:
        url = re.sub(r"=w\d+-h\d+.*$", "=w544-h544-l90-rj", url)
    return url


def _search_ytmusic(q: str, limit: int) -> list[dict]:
    results = ytmusic.search(q, filter="songs", limit=limit)
    out = []
    for r in results:
        vid = r.get("videoId")
        if not vid:
            continue
        out.append(
            {
                "id": vid,
                "title": r.get("title") or "",
                "artist": ", ".join(a["name"] for a in r.get("artists") or [] if a.get("name")),
                "album": (r.get("album") or {}).get("name"),
                "duration": r.get("duration_seconds"),
                "thumbnail": _best_thumb(r.get("thumbnails")),
            }
        )
    return out[:limit]


def _search_youtube(q: str, limit: int) -> list[dict]:
    opts = {"quiet": True, "extract_flat": True, "skip_download": True}
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"ytsearch{limit}:{q}", download=False)
    out = []
    for e in info.get("entries") or []:
        vid = e.get("id")
        if not vid or not VIDEO_ID_RE.match(vid):
            continue
        out.append(
            {
                "id": vid,
                "title": e.get("title") or "",
                "artist": e.get("channel") or e.get("uploader") or "",
                "album": None,
                "duration": int(e["duration"]) if e.get("duration") else None,
                "thumbnail": f"https://i.ytimg.com/vi/{vid}/hqdefault.jpg",
            }
        )
    return out


@app.get("/health")
def health() -> dict:
    return {"ok": True, "yt_dlp": yt_dlp.version.__version__}


@app.get("/search", dependencies=[Depends(require_token)])
def search(q: str = Query(min_length=1, max_length=200), limit: int = Query(20, ge=1, le=50)) -> list[dict]:
    try:
        results = _search_ytmusic(q, limit)
    except Exception:
        results = []
    if not results:
        try:
            results = _search_youtube(q, min(limit, 15))
        except Exception as e:
            raise HTTPException(status_code=502, detail=f"search failed: {e}") from e
    return results


def _lock_for(video_id: str) -> threading.Lock:
    with _locks_guard:
        return _locks.setdefault(video_id, threading.Lock())


def _cleanup_cache() -> None:
    now = time.time()
    files = []
    for p in CACHE_DIR.iterdir():
        if not p.is_file():
            continue
        st = p.stat()
        # Stale partial downloads and expired files go first.
        if now - st.st_mtime > CACHE_TTL_SECONDS or (p.suffix == ".part" and now - st.st_mtime > 3600):
            p.unlink(missing_ok=True)
            continue
        files.append((st.st_mtime, st.st_size, p))
    total = sum(s for _, s, _ in files)
    for _, size, p in sorted(files):
        if total <= CACHE_MAX_BYTES:
            break
        p.unlink(missing_ok=True)
        total -= size


def _download(video_id: str) -> Path:
    target = CACHE_DIR / f"{video_id}.m4a"
    if target.exists():
        target.touch()
        return target
    opts = {
        "quiet": True,
        "no_warnings": True,
        "noprogress": True,
        "noplaylist": True,
        # Prefer native AAC/m4a so no transcoding is needed on a small server.
        "format": "bestaudio[ext=m4a]/bestaudio",
        "outtmpl": str(CACHE_DIR / f"{video_id}.%(ext)s"),
    }
    if COOKIES_FILE and Path(COOKIES_FILE).exists():
        opts["cookiefile"] = COOKIES_FILE
    with yt_dlp.YoutubeDL(opts) as ydl:
        info = ydl.extract_info(f"https://www.youtube.com/watch?v={video_id}", download=True)
        downloaded = Path(ydl.prepare_filename(info))
    if downloaded != target:
        # Rare: no m4a stream (e.g. opus/webm only). iOS can't play webm, so convert to AAC.
        tmp = target.with_suffix(".tmp.m4a")
        subprocess.run(
            ["ffmpeg", "-y", "-loglevel", "error", "-i", str(downloaded), "-vn", "-c:a", "aac", "-b:a", "160k", str(tmp)],
            check=True,
        )
        tmp.rename(target)
        downloaded.unlink(missing_ok=True)
    if not target.exists():
        raise RuntimeError("download finished but m4a file is missing")
    return target


@app.get("/audio/{video_id}", dependencies=[Depends(require_token)])
def audio(video_id: str) -> FileResponse:
    if not VIDEO_ID_RE.match(video_id):
        raise HTTPException(status_code=400, detail="bad video id")
    with _lock_for(video_id):
        try:
            path = _download(video_id)
        except Exception as e:
            raise HTTPException(status_code=502, detail=f"download failed: {e}") from e
    try:
        _cleanup_cache()
    except Exception:
        pass
    return FileResponse(path, media_type="audio/mp4", filename=f"{video_id}.m4a")
