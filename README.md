# HCV Airflow

Apache Airflow deployment for scheduling HCV data sync and reporting tasks.

## Architecture

```
┌─────────────────────────────────────────────┐
│  hcv-airflow (this module)                  │
│                                             │
│  dags/                                      │
│   sync_reporting_tables.py    ← DAG         │
│   hcv/sync/                                 │
│     connections.py            ← Airflow     │
│     risk_versions.py            connection  │
│     collect_detail.py           hooks       │
│         │              │                    │
│         ▼              ▼                    │
│   ICU SQL Server   Reporting PostgreSQL     │
│   (hcv_icu conn)   (hcv_reporting_db conn)  │
└─────────────────────────────────────────────┘
```

The custom Airflow image (`Dockerfile`) includes ODBC drivers and pandas so sync tasks run natively in the worker. DAGs and sync logic live in a separate repository ([hcv-airflow-dags](../hcv-airflow-dags)) that is auto-synced via a `git-sync` sidecar — DAG changes deploy without restarting Airflow.

## Project structure

```
hcv-airflow/                            # Infrastructure + image
├── Dockerfile                          # Custom Airflow image (ODBC + pandas)
├── docker-compose.yaml                 # Production / Portainer deployment
├── docker-compose.dev.yml              # Local development
├── .github/workflows/build-image.yml   # CI: build and push image per branch
├── .env.example                        # Portainer env var template
├── config/airflow.cfg                  # Airflow configuration
└── plugins/                            # Custom Airflow plugins

hcv-airflow-dags/                       # DAGs (separate repo, auto-synced)
├── sync_reporting_tables.py            # DAG definition
└── hcv/sync/                           # Sync modules (run in Airflow worker)
    ├── connections.py
    ├── risk_versions.py
    └── collect_detail.py
```

## DAG: `sync_reporting_tables`

See [hcv-airflow-dags](../hcv-airflow-dags) for full details.

**Schedule:** Daily at 22:00 SAST

**Pipeline:**
```
sync_risk_versions → sync_collect_detail → notify_completion (email)
```

Tasks use `@task` decorators and retrieve connection details from Airflow connections via `BaseHook.get_connection()`.

## Local development

```bash
# 1. Create required directories
mkdir -p ./logs ./plugins ./config

# 2. Ensure the DAGs repo is checked out alongside this repo
ls ../hcv-airflow-dags/  # should exist

# 3. Set your user ID (Linux/WSL)
echo "AIRFLOW_UID=$(id -u)" > .env

# 4. Build and start (first run takes a few minutes to build the image)
docker compose -f docker-compose.dev.yml up --build -d

# 5. Wait for initialization
docker compose -f docker-compose.dev.yml logs -f airflow-init
```

Once running:
- **Airflow UI**: http://localhost:8080 (login: `airflow` / `airflow`)
- **Mailhog UI**: http://localhost:8025 (captures notification emails)

DAGs are mounted from `../hcv-airflow-dags` — changes are picked up live by the scheduler.

### Connecting to local databases

| Connection | Default |
|------------|---------|
| `hcv_reporting_db` | `postgresql://hcv_reporting:hcv_reporting@host.docker.internal:5433/hcv_reporting` |
| `hcv_icu` | Not set — add `HCV_ICU_CONN_STRING` to `.env` if needed |

Start the reporting DB first:
```bash
# In the hcv-reporting-db directory
SEED=true docker compose -f docker-compose.dev.yml up --build -d
```

### Stopping

```bash
docker compose -f docker-compose.dev.yml down
docker compose -f docker-compose.dev.yml down -v  # also remove volumes
```

## Production deployment (Portainer)

Deployed per branch on the shared `hcv-net` network.

| Environment | `STACK_NAME` | `AIRFLOW_PORT` | ICU database |
|-------------|-------------|----------------|-------------|
| Production | `hcv-airflow-prod` | `8080` | `HCVReporting` |
| Training | `hcv-airflow-training` | `8081` | `HCVTrain` |

### Required environment variables

| Variable | Description |
|----------|-------------|
| `STACK_NAME` | Unique prefix for container names |
| `DAGS_REPO_URL` | Git clone URL for hcv-airflow-dags |
| `DAGS_REPO_BRANCH` | Branch to track (`main` or `training`) |
| `HCV_ICU_CONN_STRING` | ICU SQL Server ODBC connection string |
| `HCV_REPORTING_DB_URL` | Reporting PostgreSQL connection string |
| `AIRFLOW_ADMIN_PASSWORD` | Admin UI password |
| `SENDGRID_API_KEY` | SendGrid API key for email notifications |

### Optional environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AIRFLOW_PORT` | `8080` | Host port for the Airflow UI |
| `AIRFLOW_IMAGE_NAME` | `ghcr.io/hcv-dev/hcv-airflow:latest` | Custom Airflow image |
| `DAGS_SYNC_INTERVAL` | `60` | Seconds between git pulls |
| `FERNET_KEY` | (empty) | Encryption key for stored connections |
| `SMTP_HOST` | `smtp.sendgrid.net` | SMTP server for notifications |
| `SMTP_PORT` | `587` | SMTP port |
| `SMTP_USER` | `apikey` | SMTP username (SendGrid requires the literal `apikey`) |
| `SMTP_FROM` | `airflow@hcv.co.za` | From address on notification emails |

### Connections (auto-configured)

| Conn ID | Source env var | Purpose |
|---------|---------------|---------|
| `hcv_icu` | `HCV_ICU_CONN_STRING` | ICU SQL Server |
| `hcv_reporting_db` | `HCV_REPORTING_DB_URL` | Reporting PostgreSQL |

### Custom image

The `Dockerfile` extends the official Airflow image with:
- ODBC Driver 18 for SQL Server
- `pandas`, `pyodbc`, `psycopg2-binary`, `sqlalchemy`, `apache-airflow-providers-microsoft-mssql`, `apache-airflow-providers-ssh`

Built and pushed to GHCR on push to `main` or `training`:
- `ghcr.io/<owner>/hcv-airflow:main`
- `ghcr.io/<owner>/hcv-airflow:training`
