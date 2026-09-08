# Control Panel

A small local dashboard for starting/stopping/inspecting the `docker-compose` stack (gateway, order-service, payment-service, inventory-service, their databases, Kafka, Consul).

It is intentionally standalone:

- Only dependency is Python 3 (standard library only — no `pip install`).
- It never imports or reads any code from `gateway/`, `order-service/`, `payment-service/`, `inventory-service/`. The only thing it knows about the rest of the repo is the path to `../docker-compose/docker-compose.yml`, which it drives entirely through the `docker compose` CLI (`up`, `down`, `stop`, `restart`, `ps`, `logs`).
- Removing this whole `control-panel/` folder has zero effect on the rest of the repo.

## Run

```bash
cd control-panel
python3 server.py
```

Then open http://127.0.0.1:5151

Binds to `127.0.0.1` only (not exposed on your network) and has no authentication — it's a local dev convenience, not something to expose publicly.

## What it does

- **Start / Stop / Restart stack** — runs `docker compose up -d` / `down` / `restart` for the whole system.
- **Per-service Start / Stop / Restart** — same, scoped to one service (`docker compose up -d <service>`, etc.).
- **Logs** — tails the last N lines of a service via `docker compose logs`.
- Service list and status auto-refresh every 4 seconds.

## Config (optional)

```bash
COMPOSE_DIR=/path/to/docker-compose CONTROL_PANEL_PORT=5151 python3 server.py
```

- `COMPOSE_DIR` — directory containing `docker-compose.yml` (default: `../docker-compose` relative to this folder).
- `CONTROL_PANEL_PORT` — port to listen on (default `5151`).
