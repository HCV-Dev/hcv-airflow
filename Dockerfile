# Custom Airflow image with ODBC drivers and data sync dependencies.
#
# Extends the official Airflow image with:
#   - ODBC Driver 18 for SQL Server (pyodbc → ICU)
#   - pandas, sqlalchemy, psycopg2 (data sync scripts)
#
FROM apache/airflow:3.1.1

USER root

# Install ODBC Driver 18 for SQL Server
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl gnupg unixodbc-dev gcc g++ \
    && curl -fsSL https://packages.microsoft.com/keys/microsoft.asc \
        | gpg --dearmor -o /usr/share/keyrings/microsoft.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/microsoft.gpg] \
        https://packages.microsoft.com/debian/12/prod bookworm main" \
        > /etc/apt/sources.list.d/mssql-release.list \
    && apt-get update \
    && ACCEPT_EULA=Y apt-get install -y --no-install-recommends msodbcsql18 \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

USER airflow

# Install Python packages for sync scripts
RUN pip install --no-cache-dir \
    pandas \
    pyodbc \
    psycopg2-binary \
    sqlalchemy>=2.0 \
    apache-airflow-providers-microsoft-mssql
