#!/usr/bin/env bash
set -euo pipefail
umask 077

command -v pg_dump >/dev/null 2>&1 || { echo 'pg_dump was not found; install PostgreSQL client tools first.' >&2; exit 1; }
command -v pg_restore >/dev/null 2>&1 || { echo 'pg_restore was not found; install PostgreSQL client tools first.' >&2; exit 1; }

PGHOST_VALUE=${PGHOST:-127.0.0.1}
PGPORT_VALUE=${PGPORT:-5432}
PGDATABASE_VALUE=${PGDATABASE:-}
PGUSER_VALUE=${PGUSER:-}
OUTPUT_DIR=${RCM_BACKUP_OUTPUT_DIR:-./backups}

[[ -n "$PGDATABASE_VALUE" && -n "$PGUSER_VALUE" ]] || {
  echo 'Set PGDATABASE and PGUSER before running the backup.' >&2
  exit 1
}
[[ "$PGPORT_VALUE" =~ ^[0-9]+$ && "$PGPORT_VALUE" -ge 1 && "$PGPORT_VALUE" -le 65535 ]] || {
  echo 'PGPORT must be between 1 and 65535.' >&2
  exit 1
}

safe_database=$(printf '%s' "$PGDATABASE_VALUE" | tr -c 'A-Za-z0-9_.-' '_')
[[ -n "$safe_database" ]] || safe_database=database
timestamp=$(date -u +%Y%m%dT%H%M%SZ)
mkdir -p -- "$OUTPUT_DIR"
destination="$OUTPUT_DIR/rcm-${safe_database}-${timestamp}.dump"
temporary="$destination.$RANDOM.tmp"
cleanup() { rm -f -- "$temporary"; }
trap cleanup EXIT

pg_dump --no-password --format=custom --no-owner --no-acl \
  --host "$PGHOST_VALUE" --port "$PGPORT_VALUE" --username "$PGUSER_VALUE" \
  --dbname "$PGDATABASE_VALUE" --file "$temporary"
pg_restore --list "$temporary" >/dev/null
mv -- "$temporary" "$destination"
hash=$(sha256sum "$destination" | awk '{print $1}')
printf '%s  %s\n' "$hash" "$(basename "$destination")" > "$destination.sha256"
printf '{"generated_at":"%s","database":"%s","format":"custom","bytes":%s,"sha256":"%s"}\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$PGDATABASE_VALUE" "$(stat -c '%s' "$destination")" "$hash" > "$destination.json"
echo "PostgreSQL backup written: $destination"
echo "SHA-256: $hash"
