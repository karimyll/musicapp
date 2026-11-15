#!/bin/sh
set -e
# YouTube changes often; keep yt-dlp fresh on every start (failure is not fatal).
pip install --no-cache-dir -q -U "yt-dlp[default]" || echo "yt-dlp update skipped"
exec uvicorn app.main:app --host 0.0.0.0 --port 8000 --workers 1 --proxy-headers
