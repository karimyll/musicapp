# Tunes — şəxsi musiqi app-i

iPhone app (SwiftUI, iOS 26 Liquid Glass) + Hetzner serverində kiçik API.
Axtarış YouTube Music-dən gəlir, seçdiyin mahnı server vasitəsilə telefona yüklənir və offline qalır.

> Yalnız şəxsi istifadə üçündür. YouTube-dan yükləmə onların şərtlərinə ziddir — App Store-a çıxarma, tokeni heç kimlə paylaşma.

```
server/   FastAPI + ytmusicapi + yt-dlp (Docker + Caddy HTTPS)
ios/      SwiftUI app (project.yml → XcodeGen)
```

## 1a. Server — Coolify ilə (tövsiyə)

1. Coolify → Project → **+ New Resource** → **Private Repository (GitHub App)** və ya **Public Repository** → bu repo, branch `main`.
2. **Build Pack:** `Dockerfile`, **Base Directory:** `/server`, **Ports Exposes:** `8000`.
3. **Domains:** öz domenin, ya da Coolify-ın "Generate Domain" düyməsi (sslip.io). `https://` ilə olmalıdır.
4. **Environment Variables:** `API_TOKEN` = `openssl rand -hex 32` çıxışı.
5. **Persistent Storage:** `/data/cache` (istəyə bağlı, keş üçün).
6. **Health Check** path: `/health`. → **Deploy**.
7. Yoxla: `curl https://DOMAIN/health`

Repo olmadan: `server/Dockerfile.coolify` faylını Coolify-ın **Dockerfile** resursuna yapışdırmaq da olar (kodu `server/build-coolify-dockerfile.sh` yaradır).

## 1b. Server — Docker Compose + Caddy ilə (Coolify-siz)

Serverdə Docker olmalıdır (`curl -fsSL https://get.docker.com | sh`).

```bash
# layihəni serverə köçür (Mac-dən):
rsync -av --exclude .venv --exclude cache server/ root@SERVER_IP:/opt/musicapp/

# serverdə:
cd /opt/musicapp
cp .env.example .env
openssl rand -hex 32      # çıxan dəyəri .env-də API_TOKEN-ə yaz
nano .env                 # DOMAIN: domenin yoxdursa 65-21-10-20.sslip.io formatında (IP-dəki nöqtələr → tire)
docker compose up -d --build
```

80 və 443 portları açıq olmalıdır (Hetzner Firewall istifadə edirsənsə).

Yoxlama:

```bash
curl https://DOMAIN/health
curl -H "Authorization: Bearer TOKEN" "https://DOMAIN/search?q=sami+yusuf"
curl -H "Authorization: Bearer TOKEN" -o test.m4a https://DOMAIN/audio/_h08O9s4tyw
```

### YouTube serveri bloklasa

`/audio` "Sign in to confirm you're not a bot" xətası verərsə, sıra ilə:
1. `docker compose restart api` — yt-dlp hər startda yenilənir, çox vaxt bu kifayətdir.
2. Ayrıca (əsas olmayan) YouTube hesabının `cookies.txt` faylını ("Get cookies.txt LOCALLY" brauzer əlavəsi ilə) `server/cookies/cookies.txt`-ə qoy, `.env`-də `COOKIES_FILE=/data/cookies/cookies.txt` aç, `docker compose up -d`.

### Lokal test (Mac)

```bash
cd server
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
API_TOKEN=test CACHE_DIR=./cache .venv/bin/uvicorn app.main:app --port 8765
```

## 2. iPhone app

Lazımdır: Mac-də Xcode 26+, iPhone-da iOS 26+.

```bash
brew install xcodegen
cd ios && xcodegen generate && open MusicApp.xcodeproj
```

1. Xcode → Settings → Accounts → Apple ID ilə daxil ol.
2. MusicApp target → Signing & Capabilities → Team: "(Personal Team)". Bundle ID məşğuldursa dəyiş (məs. `az.adin.musicapp`).
3. iPhone-u kabellə qoş, Developer Mode-u aç (Ayarlar → Məxfilik və Təhlükəsizlik), Xcode-da cihazı seç → ▶︎ Run.
4. Telefonda: Ayarlar → Ümumi → VPN və Cihaz İdarəetməsi → developer-ə "Etibar et".
5. App-də **Settings** bölməsinə server ünvanını və tokeni yaz → "Test Connection".

**Pulsuz Apple ID:** app 7 gündən sonra açılmır — Xcode-dan yenidən ▶︎ Run et (mahnılar və playlistlər silinmir, yalnız app-i telefondan silmə).

## Funksiyalar

- Axtarış (YouTube Music, ehtiyat olaraq adi YouTube), toxun → yüklə
- Offline kitabxana, kitabxanada axtarış, sil
- Playlistlər: yarat, adını dəyiş, mahnı əlavə et/çıxar, sürüşdürərək sırala
- Player: shuffle, repeat, "növbəti çal", arxa fonda çalma, kilid ekranı və qulaqlıq idarəsi
- Apple Music tərzli player: cover rəngli fon, "Playing Next" növbəsi (sürüşdürərək sırala), shuffle/repeat, ulduz (Favorites), səs barı, AirPlay
- iOS 26 Liquid Glass: tab bar-da ayrıca axtarış, tab bar üstündə mini-player
- App interfeysi ingiliscədir
