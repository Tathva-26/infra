# tathva infra

App repos only **build** images. This repo decides **what runs**.

| Container | Image | Host port | Postgres DB |
|---|---|---|---|
| `tathva-postgres` | `postgres:16-alpine` | none | `tathva` + `hackathon` |
| `tathva-backend` | `ghcr.io/tathva-26/tathva-backend-26:admin-panel` | `127.0.0.1:8000` | `tathva` |
| `hackathon-backend` | `ghcr.io/tathva-26/tathva-26-hackathon-backend:latest` | `127.0.0.1:8080` | `hackathon` |

## First deploy

```bash
cp .env.example .env
cp backend-v2.env.example backend-v2.env
cp hackathon.env.example hackathon.env
# fill in all three, then:
docker login ghcr.io
docker compose pull
docker compose up -d
curl -f http://127.0.0.1:8080/readyz
curl -f http://127.0.0.1:8000/
```

`db-init/` only runs on a **fresh** volume. Otherwise:

```bash
docker exec tathva-postgres psql -U postgres \
  -c "SELECT 'CREATE DATABASE hackathon' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname='hackathon')\gexec"
```

## Updating

```bash
docker compose pull backend-v2 hackathon-backend
docker compose up -d backend-v2 hackathon-backend
```

Order doesn't matter: backends retry until postgres is healthy.

## Backup

```bash
docker exec tathva-postgres pg_dumpall -U postgres > backup-$(date +%F).sql
```

## Nginx

Config lives in `nginx/`, copied onto the host (nginx itself is not
containerized here). Proxy each hostname to its loopback port with TLS.

| File | Host path | Purpose |
|---|---|---|
| `nginx/tathva` | `/etc/nginx/sites-available/tathva` (symlinked into `sites-enabled/`) | Server blocks for `api.tathva.org` and `api-hack.tathva.org`. TLS via Certbot origin cert, proxies to `tathva-backend` (`:8000`) / `hackathon-backend` (`:8080`), `client_max_body_size` per upstream, honeypot `/​.env` routes. |
| `nginx/cloudflare.conf` | `/etc/nginx/conf.d/cloudflare.conf` | `set_real_ip_from` for Cloudflare's IP ranges + `CF-Connecting-IP`, so `$remote_addr` / rate limiting see the real client IP, not Cloudflare's edge IP. |
| `nginx/ratelimit.conf` | `/etc/nginx/conf.d/ratelimit.conf` | Defines the `api` `limit_req_zone` (15r/s, burst 100) referenced by `tathva`. |

`cloudflare.conf` and `ratelimit.conf` must load before `tathva`
references them — `conf.d/*.conf` is included from `nginx.conf`'s `http {}`
block ahead of `sites-enabled/`, which is why they're split out instead of
living inside `tathva` directly.

Deploy/update:

```bash
sudo cp nginx/cloudflare.conf /etc/nginx/conf.d/cloudflare.conf
sudo cp nginx/ratelimit.conf /etc/nginx/conf.d/ratelimit.conf
sudo cp nginx/tathva /etc/nginx/sites-available/tathva
sudo ln -sf /etc/nginx/sites-available/tathva /etc/nginx/sites-enabled/tathva
sudo nginx -t && sudo systemctl reload nginx
```

`client_max_body_size` in `tathva` gates request body size before it
ever reaches the app — a body over the limit gets nginx's own `413` page. 
Keep it comfortably above each app's own upload cap (e.g. `IMAGE_EVENT_MAX_KB` in tathva-backend) to avoid that.
