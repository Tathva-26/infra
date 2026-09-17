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

Proxy each hostname to its loopback port with TLS. Razorpay webhook:
`https://<hackathon-api>/api/v1/webhooks/razorpay`.
