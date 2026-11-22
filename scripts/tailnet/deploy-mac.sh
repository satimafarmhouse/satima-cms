#!/usr/bin/env bash
# Run a FRESH CLONE of the CMS on this Mac, reachable only from your tailnet over HTTPS (Tailscale Serve).
#
#   First deploy, restoring the real records from an existing encrypted Neon backup:
#     scripts/tailnet/deploy-mac.sh deploy --backup /abs/neon_....dump.enc --key /abs/backup.key
#   Rebuild the app after pulling new code (keeps the data):
#     scripts/tailnet/deploy-mac.sh redeploy
#   Replace the data with a newer backup (takes a local backup of the current copy first):
#     scripts/tailnet/deploy-mac.sh deploy --replace --backup ... --key ...
#   Status / stop:
#     scripts/tailnet/deploy-mac.sh status | stop
#
# Safety: refuses to run in the original checkout, uses its own Docker project/volume/ports,
# never writes to Neon/Render, and never uses Tailscale Funnel (no public internet exposure).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
PROJECT=satima-tailnet
PG_PORT="${TAILNET_PG_PORT:-5434}"
APP_PORT="${TAILNET_APP_PORT:-3100}"
SESSION_DAYS="${TAILNET_SESSION_DAYS:-7}"
ORIGINAL="${SATIMA_ORIGINAL_CHECKOUT:-$HOME/Developer/satima-cms}"

die() { echo "ERROR: $*" >&2; exit 1; }
say() { printf '\n== %s\n' "$*"; }

action="${1:-}"; shift || true
backup=""; key=""; replace=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backup) backup="${2:?}"; shift 2 ;;
    --key) key="${2:?}"; shift 2 ;;
    --replace) replace=1; shift ;;
    *) die "Unknown option $1" ;;
  esac
done
[[ "$action" =~ ^(deploy|redeploy|status|stop)$ ]] || die 'Usage: deploy-mac.sh deploy|redeploy|status|stop [--backup FILE --key FILE] [--replace]'

# ---- Guards --------------------------------------------------------------------------------
[[ "$(uname)" == Darwin ]] || die 'This script is for the Mac mini (macOS).'
if [[ -d "$ORIGINAL" ]] && [[ "$(cd "$ORIGINAL" && pwd -P)" == "$(pwd -P)" ]]; then
  die "This is the original checkout ($ORIGINAL). Use a fresh clone; the original is never modified."
fi
if [[ -n "$(git status --porcelain --untracked-files=no)" ]]; then
  die 'Tracked files are modified. Deploy only from a clean clone.'
fi
if command -v tailscale >/dev/null 2>&1; then TS="$(command -v tailscale)";
elif [[ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]]; then TS=/Applications/Tailscale.app/Contents/MacOS/Tailscale;
else die 'Tailscale CLI not found. Install Tailscale (and enable its CLI) first.'; fi
command -v python3 >/dev/null || die 'python3 is required.'
source database/scripts/common.sh   # provides DOCKER and compose()

env_get() { python3 - "$1" <<'PY'
import sys, pathlib
p = pathlib.Path('.env')
for line in (p.read_text().splitlines() if p.exists() else []):
    k, sep, v = line.partition('=')
    if sep and k == sys.argv[1]: print(v); break
PY
}
env_set() { python3 - "$1" "$2" <<'PY'
import sys, os, pathlib
k, v = sys.argv[1], sys.argv[2]
p = pathlib.Path('.env'); lines = p.read_text().splitlines(); done = False
for i, line in enumerate(lines):
    if line.partition('=')[0] == k: lines[i] = f'{k}={v}'; done = True
if not done: lines.append(f'{k}={v}')
fd = os.open('.env.tmp', os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, 'w') as f: f.write('\n'.join(lines) + '\n')
os.replace('.env.tmp', '.env')
PY
}

ts_host() {
  "$TS" status --json | python3 -c '
import json, sys
d = json.load(sys.stdin)
if d.get("BackendState") != "Running": sys.exit("Tailscale is not connected on this Mac.")
print(d["Self"]["DNSName"].rstrip("."))'
}

# ---- Configuration (private .env for this clone only) -----------------------------------------
configure() {
  if [[ ! -f .env ]]; then
    python3 scripts/setup-local.py >/dev/null
    env_set COMPOSE_PROJECT_NAME "$PROJECT"
  fi
  [[ "$(env_get COMPOSE_PROJECT_NAME)" == "$PROJECT" ]] \
    || die ".env exists but is not the tailnet clone's ($PROJECT). Refusing, to protect the original stack."
  local host; host="$(ts_host)" || die 'Tailscale is not running/connected on this Mac.'
  [[ "$host" == *.ts.net ]] || die "Unexpected Tailscale DNS name: $host (enable MagicDNS)."
  env_set POSTGRES_PORT "$PG_PORT"
  env_set CMS_PORT "$APP_PORT"
  env_set PUBLIC_ORIGIN "https://$host"
  [[ -n "$(env_get AUTH_SESSION_DAYS)" ]] || env_set AUTH_SESSION_DAYS "$SESSION_DAYS"
  export COMPOSE_PROJECT_NAME="$PROJECT"
  local name; name="$(compose config --format json | python3 -c 'import json,sys;print(json.load(sys.stdin)["name"])')"
  [[ "$name" == "$PROJECT" ]] || die "Compose project resolved to '$name', expected '$PROJECT'."
  HOST="$host"
}

db_scalar() { compose exec -T postgres sh -c 'exec psql -X -tA -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' sh "$1"; }

restore_backup() {
  [[ -n "$backup" && -n "$key" ]] || die 'deploy needs --backup /abs/archive.dump.enc and --key /abs/backup.key'
  [[ -f "$backup" ]] || die "Backup not found: $backup"
  [[ -f "$key" ]] || die "Key not found: $key"
  command -v node >/dev/null || die 'Node.js is required to decrypt the backup.'
  if [[ -f "$backup.sha256" ]]; then
    [[ "$(shasum -a 256 "$backup" | cut -d' ' -f1)" == "$(tr -d '[:space:]' < "$backup.sha256")" ]] \
      || die 'Backup SHA-256 does not match its sidecar.'
    echo 'SHA-256 sidecar matches.'
  fi
  BACKUP_KEY_FILE="$key" node scripts/tailnet/restore-encrypted.mjs "$backup" "$ROOT" "$DOCKER"
}

serve() {
  local current; current="$("$TS" serve status 2>/dev/null || true)"
  if [[ -n "$current" && "$current" != *"No serve config"* && "$current" != *"127.0.0.1:$APP_PORT"* ]]; then
    echo "$current"; die 'Tailscale Serve already has a different configuration (shown above). Not overwriting it.'
  fi
  "$TS" serve --bg --https=443 "http://127.0.0.1:$APP_PORT" >/dev/null
}

smoke() {
  say 'Smoke test over the tailnet'
  curl -fsS --max-time 20 "https://$HOST/health" >/dev/null && echo "health: ok"
  local code; code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 "https://$HOST/")"
  echo "home page: HTTP $code"
  [[ "$code" =~ ^(200|302|303)$ ]] || die "Home page returned $code (403 usually means the Host header does not match PUBLIC_ORIGIN)."
}

warn_sleep() {
  if pmset -g 2>/dev/null | awk '$1=="sleep"{exit !($2!="0")}'; then
    echo 'NOTE: this Mac is allowed to sleep; the app is unreachable while it sleeps.'
    echo '      To keep it awake: System Settings > Energy > "Prevent automatic sleeping" (or: sudo pmset -a sleep 0).'
  fi
}

case "$action" in
  status)
    export COMPOSE_PROJECT_NAME="$PROJECT"; compose ps; "$TS" serve status || true ;;
  stop)
    export COMPOSE_PROJECT_NAME="$PROJECT"
    "$TS" serve --https=443 off 2>/dev/null || true
    compose stop; echo 'Stopped. Data is kept in the satima-tailnet volume.' ;;
  redeploy)
    configure
    say 'Migrating and rebuilding the app'
    compose up -d --wait postgres
    bash database/scripts/migrate.sh >/dev/null
    bash scripts/tailnet/reapply-grants.sh
    python3 database/scripts/configure-app.py
    compose up -d --build --wait app
    serve; smoke; warn_sleep ;;
  deploy)
    configure
    say "Starting PostgreSQL (project $PROJECT, port $PG_PORT)"
    compose up -d --wait postgres
    tables="$(db_scalar "SELECT count(*) FROM pg_tables WHERE schemaname='public'")"
    if [[ "$tables" != 0 ]]; then
      [[ $replace == 1 ]] || die "The tailnet database already has data ($tables tables). Use 'redeploy', or 'deploy --replace' to load a newer backup."
      say 'Backing up the current tailnet copy before replacing it'
      bash database/scripts/backup.sh
      compose down -v
      compose up -d --wait postgres
    fi
    say 'Restoring the real records from the encrypted backup'
    restore_backup
    say 'Applying any newer migrations and rebuilding app privileges'
    bash database/scripts/migrate.sh >/dev/null
    bash scripts/tailnet/reapply-grants.sh
    python3 database/scripts/configure-app.py
    echo "Farmers restored: $(db_scalar 'SELECT count(*) FROM farmers')"
    say "Building and starting the app (127.0.0.1:$APP_PORT only)"
    compose up -d --build --wait app
    say 'Publishing to the tailnet only (Tailscale Serve, not Funnel)'
    serve; smoke; warn_sleep
    say 'Ready'
    echo "Open on your phone (Tailscale on):  https://$HOST"
    echo 'Admin username: admin   Password: run  make copy-password  in this clone (copies to clipboard).'
    echo 'This is a COPY of production taken from the backup. Changes made here do not reach the Render/Neon CMS.' ;;
esac
