#!/usr/bin/env bash
# Rebuild satima_app's privileges after a --no-acl restore.
#
# Backups are taken with --no-acl, and migration 008 only re-grants the first nine tables.
# Later migrations (sessions, milk, Collections, reports, ...) grant their own tables, so
# replaying 008 alone leaves the app with "permission denied". Instead, build a throwaway
# reference database from the migrations, copy its exact GRANT/REVOKE state, and verify.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/database/scripts/common.sh"
REF=satima_grants_ref
as_admin() { compose exec -T postgres sh -c 'exec psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$1"' sh "$1"; }
admin_scalar() { compose exec -T postgres sh -c 'exec psql -X -tA -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$1" -c "$2"' sh "$1" "$2"; }

echo 'Building reference privileges from migrations (temporary database)...'
compose exec -T postgres sh -c 'exec psql -X -q -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS '"$REF"'" -c "CREATE DATABASE '"$REF"'"'
drop_ref() { compose exec -T postgres sh -c 'exec psql -X -q -U "$POSTGRES_USER" -d postgres -c "DROP DATABASE IF EXISTS '"$REF"'"' >/dev/null 2>&1 || true; }
trap drop_ref EXIT
python3 database/scripts/migrate.py | as_admin "$REF" >/dev/null

grants="$(compose exec -T postgres sh -c 'exec pg_dump -U "$POSTGRES_USER" -d "$1" --schema-only --no-owner' sh "$REF" | grep -E '^(GRANT|REVOKE) ' || true)"
[[ -n "$grants" ]] || { echo 'No grants found in reference database.' >&2; exit 1; }
db="$(compose exec -T postgres sh -c 'printf %s "$POSTGRES_DB"')"
{ echo 'BEGIN;'; printf '%s\n' "$grants"; echo 'COMMIT;'; } | as_admin "$db"

q="SELECT count(*) FROM information_schema.role_table_grants WHERE grantee='satima_app';"
c="SELECT count(*) FROM information_schema.column_privileges WHERE grantee='satima_app';"
s="SELECT count(*) FROM information_schema.usage_privileges WHERE grantee='satima_app';"
for check in "$q" "$c" "$s"; do
  want="$(admin_scalar "$REF" "$check")"; got="$(admin_scalar "$db" "$check")"
  [[ "$want" == "$got" ]] || { echo "Privilege mismatch ($check): reference=$want restored=$got" >&2; exit 1; }
done
echo "App privileges rebuilt and verified ($(admin_scalar "$db" "$q") table grants)."
