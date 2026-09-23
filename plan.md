# Monitoring Plan — Prometheus + Grafana (minimal)

## 0. Goal / scope

Proper monitoring + minimal alerts with only `prom`, `grafana`, and exporters.
Covered: service down, high 5xx rate, high p95 latency, plus host/DB pressure.
Out of scope: Loki/Tempo, Alertmanager (use Grafana Unified Alerting), public Grafana.

Decisions locked:
- Retention: **7 days** for metrics + logs.
- Alerts → **Telegram bot**.
- Grafana **SSH port-forward only** (no public vhost).

## 1. Current state (`infra/`)

- Single VM, one compose network (`infra/docker-compose.yml`):
  - `db` (postgres:16, no host port), `redis` (7)
  - `backend-v2` (`127.0.0.1:8000`, `/healthz` — `backend_v2/src/app.js:96`)
  - `hackathon-backend` (`127.0.0.1:8080`, `/readyz` — `infra/docker-compose.yml:81`)
- Nginx is host-level (`infra/nginx/tathva`), TLS + `limit_req 15r/s burst 100`.
- Gap: **no `/metrics` anywhere**. `backend_v2/package.json` has only `morgan`.

## 2. Architecture

```text
apps (:8000,:8080 /metrics) ──> prometheus (127.0.0.1:9090) ─> grafana (127.0.0.1:3000)
postgres_exporter (:9187) ────┤         ↑
redis_exporter (:9121) ────────┘         └─ Grafana Unified Alerting → Telegram
node_exporter (host :9100) ────┘
blackbox / plain http probe of /healthz /readyz ┘
```

- All monitoring services in the same `docker-compose.yml` (same network).
- Prometheus + Grafana bind **loopback only**. Grafana has **no nginx server block**.
  Access: `ssh -N -L 3000:127.0.0.1:3000 <user>@<vm>` → `http://localhost:3000`.
- Prometheus flags: `--storage.tsdb.retention.time=7d --storage.tsdb.retention.size=3GB`.
- Grafana hardening: `GF_AUTH_ANONYMOUS_ENABLED=false`, `GF_USERS_ALLOW_SIGN_UP=false`,
  admin password from `.env` (`GRAFANA_ADMIN_PASSWORD`), volume `grafana_data`.

## 3. Instrumentation (two tracks)

**Track A — zero app change (do first):**
- Plain Prom scrape / blackbox probe of `/healthz` + `/readyz` → `up==0` alerts work day one.

**Track B — proper RED (needs one PR per backend repo):**
- Add `prom-client`: `http_request_duration_seconds` histogram
  (buckets `0.05,0.1,0.3,0.5,1,2,5`, labels `method,route,status`) +
  `http_requests_total` + default `nodejs_*`/`process_*`.
- `GET /metrics` loopback-only or bearer-token protected; skip in `morgan` like `/healthz`.
- `route` label must be Express route pattern, **never raw URL** (cardinality guard).
- 5xx/p95 alerts query these histograms directly (section 5).

## 4. Files to add in `infra/`

```text
docker-compose.yml                       # append: prometheus, grafana, node/postgres/redis exporters
monitoring/
  prometheus.yml                         # scrape jobs (15s interval, 10s timeout)
  rules.yml                              # recording + alert rules (section 5)
  grafana/provisioning/
    provisioning/datasources/prom.yml    # http://prometheus:9090
    provisioning/dashboards/dash.yml
    provisioning/alerting/contactPoints.yaml  # telegram
    provisioning/alerting/policies.yaml       # all alerts → telegram, repeat 30m
  dashboards/{red,postgres,host-redis}.json
.env.example                             # + GRAFANA_ADMIN_PASSWORD, TELEGRAM_BOT_TOKEN, TELEGRAM_CHAT_ID
/etc/logrotate.d/tathva-nginx            # rotate 7, daily, compress (host)
```

`prometheus.yml` jobs: `backend-v2`, `hackathon`, `postgres`, `redis`,
`node`, `prometheus-self`.

Global compose logging for every service:
```yaml
logging: { driver: json-file, options: { max-size: "10m", max-file: "3" } }
```

## 5. Minimal alert set (`monitoring/rules.yml`, 6 rules)

| # | Alert | Sketch | For |
|---|-------|--------|-----|
| 1 | `ServiceDown` | `up{job=~"backend-v2\|hackathon\|postgres\|redis"} == 0` | 2m |
| 2 | `BackendUnhealthy` | `probe_success{job="blackbox-health"} == 0` | 2m |
| 3 | `High5xxRate` | `sum(rate(http_requests_total{status=~"5.."}[5m])) / sum(rate(http_requests_total[5m])) > 0.02` | 5m |
| 4 | `HighP95Latency` | `histogram_quantile(0.95, sum(rate(http_request_duration_seconds_bucket[5m])) by (le,service)) > 1` | 10m |
| 5 | `PostgresOrRedisDown` | `pg_up == 0` / `redis_up == 0` (plus #1) | 2m |
| 6 | `HostPressure` | `node_filesystem_avail / node_filesystem_size < 0.15` OR `node_memory_MemAvailable / node_memory_MemTotal < 0.1` | 10m |

- Warning-only to start; tune `0.02` / `1s` after 1 week of data.
- Contact point: Telegram (`TELEGRAM_BOT_TOKEN` + `TELEGRAM_CHAT_ID` in `.env`, never committed).
  Test via Grafana → Contact Points → Test before enabling.

## 6. Grafana (3 dashboards max, provisioned as code)

1. **RED**: req/s, 5xx %, top routes, in-flight, p50/p95/p99.
2. **Postgres**: connections, pool usage %, cache-hit, size, transactions/s.
3. **Host+Redis**: CPU/mem/net, Redis mem/keys/evictions (no disk panel).

## 7. Traffic / sizing note

No prod numbers available. Assumed baseline few req/s, spikes 100–300 req/s
(registration/TIQR checkout; limiter is 15r/s per IP so aggregate ≈ concurrent users).
Storage: ~5–10k series × 5760 scrapes/day ≈ 57M samples/day ≈ 100–200MB/day
→ 7d ≈ 0.7–1.4GB, inside the 3GB cap. Request rate only matters if high-cardinality
labels are added — forbidden by section 3. Verify post-deploy with
`prometheus_tsdb_head_series` and `prometheus_tsdb_storage_blocks_bytes`.

## 8. Rollout

1. **Phase 1 — infra-only (~1h):** exporters + Prom + Grafana up;
   `up`-alerts to Telegram test channel. Verify `curl 127.0.0.1:9090/-/healthy`.
2. **Phase 2 — app PRs:** land `/metrics` in both backends; flip 5xx/p95 to histograms.
3. **Phase 3 — verify:** import dashboards; drill `docker stop hackathon-backend` →
   `ServiceDown` in Telegram in <3m; `docker start` → resolve.
4. **Phase 4 — docs:** runbooks (restart cmds, `pg_isready`, `redis-cli ping`,
   `docker compose up -d <svc>`) + extend `README.md` backup section with
   Prom/Grafana volumes.

## 9. Risks

- Prom shares disk with Postgres — retention quotas + disk alert (section 5 #6) are load-bearing.
- Secrets (`POSTGRES_PASSWORD`, `GRAFANA_ADMIN_PASSWORD`, `TELEGRAM_*`) stay in `.env`, never in git (see `.gitignore`).
