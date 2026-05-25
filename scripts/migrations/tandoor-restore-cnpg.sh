#!/usr/bin/env bash
# Restore Tandoor PostgreSQL dump into CNPG homelab-postgres (database: tandoor).
# Usage: ./tandoor-restore-cnpg.sh /path/to/tandoor.dump
set -euo pipefail

DUMP="${1:?usage: $0 /path/to/tandoor.dump}"

kubectl get cluster -n cnpg-system homelab-postgres >/dev/null
kubectl get database -n cnpg-system homelab-postgres-tandoor >/dev/null

USER=$(kubectl get secret -n tandoor homelab-postgres-tandoor -o jsonpath='{.data.username}' | base64 -d)
PASS=$(kubectl get secret -n tandoor homelab-postgres-tandoor -o jsonpath='{.data.password}' | base64 -d)

kubectl port-forward -n cnpg-system svc/homelab-postgres-rw 15432:5432 &
PF_PID=$!
trap 'kill "$PF_PID" 2>/dev/null || true' EXIT
sleep 2

export PGPASSWORD="$PASS"
pg_restore -h 127.0.0.1 -p 15432 -U "$USER" -d tandoor --clean --if-exists --no-owner --no-acl "$DUMP"

echo "Restore finished. Scale tandoor Deployment back up and verify https://rezepte.f4mily.net"
