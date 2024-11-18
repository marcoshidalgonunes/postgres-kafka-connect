FROM quay.io/debezium/postgres:17
RUN apt-get update && apt-get install -y postgresql-17-wal2json
