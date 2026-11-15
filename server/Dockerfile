FROM python:3.12-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# yt-dlp needs a JavaScript runtime to solve YouTube's player challenges.
COPY --from=denoland/deno:bin /deno /usr/local/bin/deno

WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app ./app
COPY entrypoint.sh .
RUN chmod +x entrypoint.sh \
    && useradd -m -u 1000 app \
    && mkdir -p /data/cache && chown -R app:app /data /srv /usr/local/lib/python3.12/site-packages /usr/local/bin

USER app
EXPOSE 8000
ENTRYPOINT ["./entrypoint.sh"]
