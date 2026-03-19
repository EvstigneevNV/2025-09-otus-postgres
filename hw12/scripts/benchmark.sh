#!/usr/bin/env bash
set -e

echo "[INFO] Benchmark: region-1 count"
time psql -h localhost -p 5432 -U postgres -d shipments_db -c "SELECT count(*) FROM shipments;"

echo "[INFO] Benchmark: region-2 count"
time psql -h localhost -p 5433 -U postgres -d shipments_db -c "SELECT count(*) FROM shipments;"

echo "[INFO] Benchmark: region-1 filter"
time psql -h localhost -p 5432 -U postgres -d shipments_db -c "
SELECT count(*)
FROM shipments
WHERE destination = 'Berlin'
  AND created_at >= '2026-03-01'
  AND created_at < '2026-04-01';"

echo "[INFO] Benchmark: region-2 filter"
time psql -h localhost -p 5433 -U postgres -d shipments_db -c "
SELECT count(*)
FROM shipments
WHERE destination = 'Berlin'
  AND created_at >= '2026-03-01'
  AND created_at < '2026-04-01';"
