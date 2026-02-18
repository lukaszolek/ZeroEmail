# ZeroEmail — Wdrożenie na framky-server

## Architektura

Model hybrydowy: backend na Cloudflare Workers, frontend + baza na OVH VPS.

```
Użytkownik
    │
    ▼
┌─ Cloudflare (DNS + Proxy) ─────────────────────────────────┐
│                                                             │
│  mail.framky.com ──▶ OVH VPS (frontend, port 3100)         │
│  mail-api.framky.com ──▶ CF Workers (backend)              │
│                                                             │
└─────────────────────────────────────────────────────────────┘
    │                          │
    ▼                          ▼
┌─ OVH VPS ──────────┐   ┌─ Cloudflare Workers ──────────────┐
│                     │   │                                    │
│  zeroemail.service  │   │  zero-server-framky                │
│  (bun server.js)    │   │  ├── Hono HTTP framework           │
│  port 3100          │   │  ├── 8x Durable Objects            │
│                     │   │  ├── 10x KV Namespaces             │
│  redis-zeroemail    │   │  ├── 3x Queues                     │
│  port 6381          │   │  ├── 2x Vectorize indexes          │
│                     │   │  ├── 1x R2 bucket                  │
│  upstash-proxy      │   │  ├── 2x Workflows                  │
│  (Docker) port 8179 │   │  ├── Hyperdrive → PG               │
│                     │   │  └── AI binding                    │
│  PostgreSQL 18      │   │                                    │
│  DB: zerodotemail   │   │  Połączenie z PG:                  │
│  port 5432          │◀──│──Hyperdrive → Cloudflare Tunnel    │
│                     │   │                                    │
│  cloudflared        │   └────────────────────────────────────┘
│  (CF Tunnel → PG)   │
│                     │
│  Nginx              │
│  (reverse proxy)    │
└─────────────────────┘
```

## Domeny

| Domena | Target | Opis |
|--------|--------|------|
| `mail.framky.com` | OVH VPS (A record, Proxied) | Frontend — React Router app |
| `mail-api.framky.com` | CF Workers (Custom Domain) | Backend API — Hono |
| `pg-tunnel.framky.com` | Cloudflare Tunnel | Wewnętrzne — Hyperdrive → PostgreSQL |

## Komponenty na OVH VPS

### 1. Frontend — systemd

| | |
|---|---|
| **Unit** | `zeroemail.service` |
| **User** | `zeroemail` (system, nologin) |
| **Katalog** | `/srv/zeroemail` |
| **Port** | 3100 |
| **Runtime** | bun |
| **RAM limit** | 2 GB |
| **CPU limit** | 200% |

### 2. PostgreSQL

| | |
|---|---|
| **Baza** | `zerodotemail` |
| **User PG** | `zerodotemail` |
| **Port** | 5432 (localhost) |
| **ORM** | Drizzle |
| **Backup** | pgBackRest (wspólny z resztą baz framky) |

### 3. Redis

| | |
|---|---|
| **Instancja** | `redis-zeroemail` |
| **Port** | 6381 |
| **Policy** | `noeviction` |
| **Persistence** | AOF everysec |
| **Maxmemory** | 512 MB |
| **Konfig** | `/etc/redis/redis-zeroemail.conf` |

### 4. Upstash HTTP Proxy (Docker)

| | |
|---|---|
| **Kontener** | `upstash-proxy` |
| **Port** | 8179 (localhost) |
| **Image** | `hiett/serverless-redis-http:latest` |
| **Cel** | HTTP→Redis bridge (ZeroEmail używa `@upstash/redis`) |

### 5. Cloudflare Tunnel

| | |
|---|---|
| **Binary** | `/usr/local/bin/cloudflared` |
| **Unit** | `cloudflared.service` |
| **Tunnel** | `framky-pg` |
| **Hostname** | `pg-tunnel.framky.com` → `tcp://localhost:5432` |
| **Cel** | Hyperdrive (CF Workers) → PostgreSQL (OVH) bez otwartego portu |

### 6. Nginx

```nginx
server {
    listen 443 ssl http2;
    server_name mail.framky.com;

    ssl_certificate /etc/nginx/ssl/framky-origin.pem;
    ssl_certificate_key /etc/nginx/ssl/framky-origin.key;

    location / {
        proxy_pass http://127.0.0.1:3100;
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_buffering off;
    }
}
```

## Komponenty na Cloudflare Workers

Backend deployowany jako Worker `zero-server-framky` (env `framky` w `wrangler.jsonc`).

### Usługi CF i koszty

| Usługa | Zasoby | Wliczone w $5/mies. | Szacowane użycie (1-5 userów) |
|--------|--------|---------------------|-------------------------------|
| Workers | 10M req/mies. | ~50K req | |
| Durable Objects | 1M req/mies. | ~5K req | |
| KV (10 store'ów) | 10M reads, 1M writes | ~100K reads, ~10K writes | |
| R2 | 10 GB free | <1 GB | |
| Queues (3) | 1M ops/mies. | ~10K ops | |
| Vectorize (2 indexy) | 50M dims/mies. | minimalne | |
| Hyperdrive | unlimited | unlimited | |
| Workflows (2) | shared z Workers | minimalne | |
| AI | 10K neurons/dzień free | minimalne | |
| **Suma** | | | **$5/miesiąc** |

### Zasoby CF — nazwy

| Typ | Nazwa | Binding |
|-----|-------|---------|
| R2 | `threads-framky` | `THREADS_BUCKET` |
| Queue | `thread-queue-framky` | `thread_queue` |
| Queue | `subscribe-queue-framky` | `subscribe_queue` |
| Queue | `send-email-queue-framky` | `send_email_queue` |
| Vectorize | `threads-vector-framky` | `VECTORIZE` |
| Vectorize | `messages-vector-framky` | `VECTORIZE_MESSAGE` |
| Hyperdrive | `zerodotemail-framky` | `HYPERDRIVE` |
| Workflow | `sync-threads-workflow-framky` | `SYNC_THREADS_WORKFLOW` |
| Workflow | `sync-threads-coordinator-workflow-framky` | `SYNC_THREADS_COORDINATOR_WORKFLOW` |
| KV | `gmail_history_id-framky` | `gmail_history_id` |
| KV | `gmail_processing_threads-framky` | `gmail_processing_threads` |
| KV | `subscribed_accounts-framky` | `subscribed_accounts` |
| KV | `connection_labels-framky` | `connection_labels` |
| KV | `prompts_storage-framky` | `prompts_storage` |
| KV | `gmail_sub_age-framky` | `gmail_sub_age` |
| KV | `pending_emails_status-framky` | `pending_emails_status` |
| KV | `pending_emails_payload-framky` | `pending_emails_payload` |
| KV | `scheduled_emails-framky` | `scheduled_emails` |
| KV | `snoozed_emails-framky` | `snoozed_emails` |

## CI/CD — Automatyczny deploy

**Workflow:** `.github/workflows/deploy-framky.yml`

**Trigger:** Push to `main` branch lub manual dispatch.

```
Push to main
    │
    ├──▶ deploy-backend (ubuntu-latest)
    │       └── npx wrangler deploy --env framky
    │
    ├──▶ deploy-frontend (self-hosted, ovh-vps)
    │       ├── pnpm install
    │       ├── pnpm build (apps/mail)
    │       └── sudo deploy-zeroemail.sh
    │
    └──▶ migrate-db (self-hosted, ovh-vps) [after backend]
            └── pnpm db:migrate
```

Backend i frontend deployują się **równolegle**. Migracje DB czekają na backend.

### Wymagane GitHub Secrets

| Secret | Opis |
|--------|------|
| `CF_API_TOKEN` | Cloudflare API token z uprawnieniami Workers, R2, KV, Queues |
| `ZEROEMAIL_DATABASE_URL` | `postgresql://zerodotemail:PASS@localhost:5432/zerodotemail` |

### Wymagane na serwerze

| Element | Ścieżka |
|---------|---------|
| Deploy script | `/usr/local/bin/deploy-zeroemail.sh` |
| Sudoers | `/etc/sudoers.d/gh-runner-zeroemail` |
| GH Runner | Istniejący runner `framky-ovh` (labels: `self-hosted,ovh-vps`) |

**Sudoers:**
```
gh-runner ALL=(ALL) NOPASSWD: /usr/local/bin/deploy-zeroemail.sh
```

## Procedura wdrożenia — krok po kroku

### Krok 1: Zasoby Cloudflare (jednorazowo)

```bash
# Zaloguj się do Cloudflare
npx wrangler login

# Uruchom skrypt setup
./scripts/setup-framky-cf.sh

# Skopiuj ID zasobów do apps/server/wrangler.jsonc → env.framky
# Zastąp PLACEHOLDER_RUN_SETUP_SCRIPT prawdziwymi ID

# Utwórz Hyperdrive (po skonfigurowaniu Cloudflare Tunnel)
npx wrangler hyperdrive create zerodotemail-framky \
  --connection-string="postgresql://zerodotemail:PASS@pg-tunnel.framky.com:5432/zerodotemail"

# Ustaw sekrety
npx wrangler secret put BETTER_AUTH_SECRET --env framky
npx wrangler secret put GOOGLE_CLIENT_ID --env framky
npx wrangler secret put GOOGLE_CLIENT_SECRET --env framky
npx wrangler secret put OPENAI_API_KEY --env framky
npx wrangler secret put RESEND_API_KEY --env framky
npx wrangler secret put JWT_SECRET --env framky
npx wrangler secret put REDIS_URL --env framky
npx wrangler secret put REDIS_TOKEN --env framky
```

### Krok 2: OVH VPS (jednorazowo)

```bash
# 1. User serwisowy
useradd --system --shell /usr/sbin/nologin --home-dir /srv/zeroemail zeroemail
mkdir -p /srv/zeroemail
chown zeroemail:zeroemail /srv/zeroemail

# 2. PostgreSQL
sudo -u postgres psql <<'SQL'
CREATE USER zerodotemail WITH PASSWORD '...' CREATEDB;
CREATE DATABASE zerodotemail OWNER zerodotemail;
SQL
# Dodaj do pg_hba.conf:
# host zerodotemail zerodotemail 127.0.0.1/32 scram-sha-256
sudo systemctl reload postgresql

# 3. Redis
# Skopiuj konfigurację z MIGRATION-PLAN.md sekcja 8.5
sudo systemctl enable --now redis-zeroemail

# 4. Upstash proxy (Docker)
docker run -d \
  --name upstash-proxy \
  --restart unless-stopped \
  -e SRH_MODE=env \
  -e SRH_TOKEN=<TOKEN> \
  -e SRH_CONNECTION_STRING='redis://host.docker.internal:6381' \
  -p 127.0.0.1:8179:80 \
  --add-host=host.docker.internal:host-gateway \
  hiett/serverless-redis-http:latest

# 5. Cloudflare Tunnel
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 \
  -o /usr/local/bin/cloudflared
chmod +x /usr/local/bin/cloudflared
cloudflared tunnel login
cloudflared tunnel create framky-pg
# Skonfiguruj /etc/cloudflared/config.yml (patrz MIGRATION-PLAN.md 8.1)
cloudflared service install
systemctl enable --now cloudflared

# 6. Nginx
# Skopiuj konfigurację z sekcji "Nginx" powyżej
ln -s /etc/nginx/sites-available/zeroemail.conf /etc/nginx/sites-enabled/
nginx -t && systemctl reload nginx

# 7. Systemd
# Skopiuj unit file zeroemail.service (patrz MIGRATION-PLAN.md 8.3)
systemctl daemon-reload
systemctl enable zeroemail

# 8. Deploy script
cp scripts/deploy-zeroemail.sh /usr/local/bin/
chmod +x /usr/local/bin/deploy-zeroemail.sh
echo 'gh-runner ALL=(ALL) NOPASSWD: /usr/local/bin/deploy-zeroemail.sh' > /etc/sudoers.d/gh-runner-zeroemail
chmod 440 /etc/sudoers.d/gh-runner-zeroemail

# 9. Env file
cat > /srv/zeroemail/.env <<'EOF'
VITE_PUBLIC_APP_URL=https://mail.framky.com
VITE_PUBLIC_BACKEND_URL=https://mail-api.framky.com
DATABASE_URL=postgresql://zerodotemail:PASSWORD@localhost:5432/zerodotemail
BETTER_AUTH_SECRET=...
BETTER_AUTH_URL=https://mail.framky.com
COOKIE_DOMAIN=framky.com
GOOGLE_CLIENT_ID=...
GOOGLE_CLIENT_SECRET=...
REDIS_URL=http://localhost:8179
REDIS_TOKEN=...
RESEND_API_KEY=...
OPENAI_API_KEY=...
OPENAI_MODEL=gpt-4o
OPENAI_MINI_MODEL=gpt-4o-mini
NODE_ENV=production
EOF
chown zeroemail:zeroemail /srv/zeroemail/.env
chmod 600 /srv/zeroemail/.env

# 10. DB migration
cd /srv/zeroemail && pnpm db:migrate

# 11. DNS (Cloudflare Dashboard)
# mail.framky.com → A → OVH_IP (Proxied)
# mail-api.framky.com → Custom Domain on Workers
# pg-tunnel.framky.com → Cloudflare Tunnel (automatycznie)
```

### Krok 3: Pierwszy deploy

```bash
# Backend
cd apps/server && npx wrangler deploy --env framky

# Frontend (na serwerze)
cd /srv/zeroemail
git clone <repo> .
pnpm install --frozen-lockfile
cd apps/mail && pnpm build
systemctl start zeroemail
```

### Krok 4: Google OAuth

W Google Cloud Console:
- Authorized redirect URIs: `https://mail.framky.com/api/auth/callback/google`
- Authorized JavaScript origins: `https://mail.framky.com`

### Krok 5: Weryfikacja

- [ ] `mail.framky.com` ładuje się
- [ ] Logowanie Google OAuth działa
- [ ] Synchronizacja Gmail działa
- [ ] Wysyłanie maili działa (Resend)
- [ ] AI features działają
- [ ] WebSocket/real-time updates działają
- [ ] `redis-cli -p 6381 dbsize` rośnie po użyciu
- [ ] `pgbackrest --stanza=frami info` obejmuje zerodotemail

## Zarządzanie

```bash
# Status
systemctl status zeroemail redis-zeroemail cloudflared
docker ps  # upstash-proxy

# Logi
journalctl -u zeroemail -f
journalctl -u redis-zeroemail -f
journalctl -u cloudflared -f

# Redis
redis-cli -p 6381 info memory
redis-cli -p 6381 dbsize

# PostgreSQL
sudo -u postgres psql -d zerodotemail -c "SELECT count(*) FROM information_schema.tables WHERE table_schema='public';"

# CF Workers logi
npx wrangler tail --env framky
```

## Szacowane zasoby

| Komponent | RAM | Koszt/mies. |
|-----------|-----|-------------|
| Frontend (systemd) | 2 GB | $0 (OVH VPS) |
| Redis | 512 MB | $0 (OVH VPS) |
| Upstash proxy (Docker) | 128 MB | $0 (OVH VPS) |
| PostgreSQL | ~1 GB shared | $0 (OVH VPS) |
| Cloudflared | 128 MB | $0 |
| CF Workers (backend) | — | **$5** |
| **Suma** | ~3.8 GB | **$5/miesiąc** |
