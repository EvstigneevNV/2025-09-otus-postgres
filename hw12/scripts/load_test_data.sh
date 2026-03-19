#!/usr/bin/env bash
set -e

echo "[INFO] Loading test data into region-1..."
psql -h localhost -p 5432 -U postgres -d shipments_db -c "
COPY shipments(id, product_name, quantity, destination, region, created_at)
FROM '/data/shipments.csv'
WITH (FORMAT csv, HEADER true);"

echo "[INFO] Exporting initial dump..."
pg_dump -h localhost -p 5432 -U postgres -d shipments_db > shipments_dump.sql

echo "[INFO] Restoring dump into region-2..."
psql -h localhost -p 5433 -U postgres -d shipments_db < shipments_dump.sql

echo "[INFO] Initial load completed."
