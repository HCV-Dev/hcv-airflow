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
# 1. Create required directories (./share stands in for the SMB reports share)
mkdir -p ./logs ./plugins ./config ./share

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
| `HCV_SFTP_CONN_STRING` | SFTP destination for extracts (SSH connection URI) |
| `AIRFLOW_ADMIN_PASSWORD` | Admin UI password |
| `GMAIL_ADDRESS` | Gmail sender + From address (active email sender) |
| `GMAIL_APP_PASSWORD` | Gmail App Password (16 chars, 2FA required) |
| `HCV_FINANCE_NOTIFY_EMAIL` | Finance report recipient(s) — comma-separated |
| `HCV_CLAIMS_NOTIFY_EMAIL` | Claims report recipient(s) — comma-separated |
| `HCV_FAILURE_NOTIFY_EMAIL` | Task-failure recipient(s) — comma-separated |

### Optional environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `AIRFLOW_PORT` | `8080` | Host port for the Airflow UI |
| `AIRFLOW_IMAGE_NAME` | `ghcr.io/hcv-dev/hcv-airflow:latest` | Custom Airflow image |
| `DAGS_SYNC_INTERVAL` | `60` | Seconds between git pulls |
| `HCV_REPORTS_SHARE_PATH` | `/mnt/hcv-reports` | Host path of the SMB reports share, bind-mounted at `/mnt/reports` |
| `HCV_MONTHLY_EXTRACT_SHARE_DIR` | `/mnt/reports/monthly` | In-container directory the monthly workbook is written to |
| `HCV_SHARE_MARKER_FILE` | `.hcv-share-ok` | File that exists only on the real share, proving the mount is live |
| `HCV_VALUE_DISCREPANCY_EMAIL` | `reporting@hcv.co.za` | Recipient(s) for `compare_vehicle_values` |
| `HCV_VALUE_MARGIN_PCT` | `10` | Value-discrepancy threshold, percent |
| `FERNET_KEY` | (empty) | Encryption key for stored connections |
| `SENDGRID_API_KEY` | (empty) | SendGrid API key — only if reverting email to SendGrid |
| `SMTP_HOST` | `smtp.sendgrid.net` | SMTP server (only used by the disabled SendGrid block) |
| `SMTP_PORT` | `587` | SMTP port (SendGrid block) |
| `SMTP_USER` | `apikey` | SMTP username (SendGrid block; literal `apikey`) |
| `SMTP_FROM` | `airflow@hcv.co.za` | From address (SendGrid block) |

### Connections (auto-configured)

| Conn ID | Source env var | Purpose |
|---------|---------------|---------|
| `hcv_icu` | `HCV_ICU_CONN_STRING` | ICU SQL Server |
| `hcv_reporting_db` | `HCV_REPORTING_DB_URL` | Reporting PostgreSQL |
| `hcv_sftp` | `HCV_SFTP_CONN_STRING` | SFTP destination for monthly/daily extracts |
| `smtp_default` | `GMAIL_ADDRESS` + `GMAIL_APP_PASSWORD` | Default email sender (Gmail) |
| `smtp_gmail` | `GMAIL_ADDRESS` + `GMAIL_APP_PASSWORD` | Explicit Gmail alias (same as `smtp_default`) |

`HCV_SFTP_CONN_STRING` is an Airflow **SSH** connection. Supply it as a URI,
e.g. `ssh://user:password@sftp.example.com:22`, or for key auth use the JSON
form with the key in `extra`:
`{"conn_type": "ssh", "host": "sftp.example.com", "login": "user", "port": 22, "extra": {"private_key": "-----BEGIN OPENSSH PRIVATE KEY-----\n...\n-----END OPENSSH PRIVATE KEY-----"}}`.
Leave it unset to skip transfers (the extract still runs and writes the file locally).

### Notification recipients

Report recipients are set per business area in the deployment and exposed to DAGs
as Airflow Variables (`AIRFLOW_VAR_*` values take precedence over anything in
Admin → Variables, so the stack's env vars always win):

| Env var | Airflow Variable | Used by |
|---------|-----------------|---------|
| `HCV_FINANCE_NOTIFY_EMAIL` | `HCV_FINANCE_NOTIFY_EMAIL` | `extract_monthly` — monthly Movement extract summary |
| `HCV_CLAIMS_NOTIFY_EMAIL` | `HCV_CLAIMS_NOTIFY_EMAIL` | `check_claim_capture` — capture check + month-end location audit |
| `HCV_FAILURE_NOTIFY_EMAIL` | `HCV_FAILURE_NOTIFY_EMAIL` | task-failure callbacks in all DAGs |

Each accepts one address or a comma-separated list. All three default to
`reporting@hcv.co.za` if unset, so a fresh stack still delivers. Do not set them
to an empty string in Portainer — for `HCV_CLAIMS_NOTIFY_EMAIL` the DAG template
would then resolve to no recipient at all.

Airflow only reads env vars prefixed `AIRFLOW_VAR_`, so setting a bare
`HCV_*` variable in the stack env has no effect on its own — the mapping in
`docker-compose.yaml` is what exposes it. A DAG silently falling back to its
default (or a `Variable not found` 404 in the worker log) means the
`AIRFLOW_VAR_*` line is missing, or the stack was restarted rather than
recreated after the compose file changed.

`HCV_CLAIMS_NOTIFY_EMAIL` replaces the old `HCV_CLAIMS_MANAGEMENT_NOTIFY`
Variable, which the DAG no longer reads — delete it from Admin → Variables if it
is still there, to avoid the impression that it controls anything.

### Reports share (SMB/CIFS)

`extract_monthly` delivers its workbook by copying it onto a mounted share
rather than over SFTP. The share is mounted **on the host** and bind-mounted
into every Airflow container at `/mnt/reports`:

```
${HCV_REPORTS_SHARE_PATH:-/mnt/hcv-reports}:/mnt/reports
```

Mount it on the host with a uid matching `AIRFLOW_UID` (the containers run as
`50000:0`), e.g. in `/etc/fstab`:

```
//fileserver/Reports /mnt/hcv-reports cifs credentials=/etc/cifs-hcv-reports,uid=50000,gid=0,file_mode=0664,dir_mode=0775,vers=3.0,_netdev,nofail 0 0
```

`hcv/extract/share.py` in the DAGs repo refuses to write when the target sits on
the container root filesystem, and copies via a hidden `.partial` file that is
renamed into place, so a Windows-side poller never picks up a half-written
workbook. One gap the device check cannot see: with `nofail`, a dead CIFS mount
leaves an ordinary empty host directory that Docker still binds happily. Put a
`.hcv-share-ok` file on the real share so `HCV_SHARE_MARKER_FILE` can catch that
case and fail the task.

In local dev the share is stood in for by `./share` (gitignored, mounted at the
same path) and `HCV_SHARE_MARKER_FILE` is empty, which skips the marker check.

#### Email sender (Gmail — active)

Email notifications send through **Gmail** by default: the `[smtp]` transport, the
`smtp_default` connection, and the `smtp_gmail` alias are all configured for Gmail.
SendGrid config is kept commented out in `docker-compose.yaml` and `airflow.cfg`
for easy rollback. Gmail rejects plain-password SMTP auth, so it needs an
**App Password**:

1. Enable 2-Step Verification on the Google account.
2. Create an App Password at <https://myaccount.google.com/apppasswords> (16
   characters, no spaces).
3. Add to `.env`:
   ```bash
   GMAIL_ADDRESS=you@gmail.com          # also used as the From address
   GMAIL_APP_PASSWORD=abcdefghijklmnop  # the 16-char App Password, not your login password
   ```

The connections are defined as JSON (not a URI) in `docker-compose.yaml`, so the
`@` in the address and any password characters pass through verbatim — avoiding the
URI-encoding pitfalls that previously affected the SendGrid `smtp_default` URI.
Port 587 with STARTTLS.

No DAG changes are needed: `EmailOperator`s already use `smtp_default` (now Gmail),
and the legacy `send_email` path (failure callbacks) takes its transport from the
Gmail `[smtp]` / `AIRFLOW__SMTP__*` config and its credentials from the Gmail
`smtp_default` connection. Because both paths now point at Gmail consistently, all
notifications send from the Gmail account.

**To revert to SendGrid:** in `docker-compose.yaml`, comment the Gmail SMTP block
and uncomment the SendGrid block; in `config/airflow.cfg`, restore the commented
`smtp_host`/`smtp_user` SendGrid lines. Then set `SENDGRID_API_KEY` in `.env` and
recreate the stack.

### Custom image

The `Dockerfile` extends the official Airflow image with:
- ODBC Driver 18 for SQL Server
- `pandas`, `pyodbc`, `psycopg2-binary`, `sqlalchemy`, `apache-airflow-providers-microsoft-mssql`, `apache-airflow-providers-ssh`

Built and pushed to GHCR on push to `main` or `training`:
- `ghcr.io/<owner>/hcv-airflow:main`
- `ghcr.io/<owner>/hcv-airflow:training`
