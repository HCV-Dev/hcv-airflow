# Airflow Installation

https://airflow.apache.org/docs/apache-airflow/stable/howto/docker-compose/index.html

```
mkdir -p ./dags ./logs ./plugins ./config
echo -e "AIRFLOW_UID=$(id -u)" > .env
```

1. Fill in .env file
2. Bring up docker stack
```
docker compose up -d
```