#!/usr/bin/env bash
set -e

echo "[INFO] Starting failover test"
echo "[INFO] Stopping primary node pg-region1"
docker stop pg-region1

echo "[INFO] Checking HAProxy availability"
nc -zv localhost 5000 || true

echo "[INFO] Failover test finished"
