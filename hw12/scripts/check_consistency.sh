#!/usr/bin/env bash
set -e

echo "[INFO] Checking row count on region-1"
psql -h localhost -p 5432 -U postgres -d shipments_db -c "SELECT count(*) FROM shipments;"

echo "[INFO] Checking row count on region-2"
psql -h localhost -p 5433 -U postgres -d shipments_db -c "SELECT count(*) FROM shipments;"

echo "[INFO] Checking checksum sample on region-1"
psql -h localhost -p 5432 -U postgres -d shipments_db -c "
SELECT md5(string_agg(id::text || product_name || quantity::text || destination, '' ORDER BY id))
FROM (
    SELECT id, product_name, quantity, destination
    FROM shipments
    ORDER BY id
    LIMIT 10000
) t;"

echo "[INFO] Checking checksum sample on region-2"
psql -h localhost -p 5433 -U postgres -d shipments_db -c "
SELECT md5(string_agg(id::text || product_name || quantity::text || destination, '' ORDER BY id))
FROM (
    SELECT id, product_name, quantity, destination
    FROM shipments
    ORDER BY id
    LIMIT 10000
) t;"
