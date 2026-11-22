# Private phone testing: Mac mini over Tailscale

This runs a **fresh clone** of the CMS on the Mac mini. It is reachable only by devices signed in to your tailnet, over HTTPS (Tailscale Serve). It never uses Tailscale Funnel, so nothing is exposed to the public internet. The original checkout (`~/Developer/satima-cms`), the Render service and the Neon database are never modified.

The data is a **copy** of production, restored from the latest encrypted Neon backup the Mac already takes every night. Changes made on the phone stay in this copy. They do not reach the Render/Neon CMS, and production changes do not appear here until you load a newer backup.

## One-time prerequisites
1. Tailscale installed and signed in on the Mac mini and the phone, both on the same tailnet.
2. In the Tailscale admin console → DNS: **MagicDNS** on, and **HTTPS Certificates** enabled.
3. Tailscale CLI available on the Mac (the app's Settings offers "Install CLI"; otherwise the script uses `/Applications/Tailscale.app/Contents/MacOS/Tailscale`).
4. Docker Desktop running, plus `git`, `python3` and Node.js on the Mac.
5. Keep the Mac awake: System Settings → Energy → "Prevent automatic sleeping when the display is off".

## First deploy
```bash
mkdir -p ~/Developer/satima-tailnet && cd ~/Developer/satima-tailnet
git clone https://github.com/satimafarmhouse/satima-cms.git .
git checkout <branch-or-commit-to-test>
scripts/tailnet/deploy-mac.sh deploy \
  --backup "/absolute/path/to/neon_<timestamp>.dump.enc" \
  --key    "/absolute/path/to/backup.key"
```
The backup directory and key path are listed in the Mac's private `data/private/cloud/backup-config.json` (`BACKUP_DIR`, `BACKUP_KEY_FILE`). Pick the newest `.dump.enc`. Its `.sha256` sidecar is checked automatically.

What the script does:
1. Refuses to run in the original checkout, in a modified clone, or with a `.env` that is not this clone's.
2. Creates this clone's private `.env` with new local passwords, Docker project `satima-tailnet`, PostgreSQL on `127.0.0.1:5434`, the app on `127.0.0.1:3100`, `PUBLIC_ORIGIN=https://<mac>.<tailnet>.ts.net` and 7-day sessions. Its own containers and volume sit beside, never on top of, the original stack.
3. Authenticates the whole encrypted archive, then streams it into the empty database. No plaintext dump is written to disk.
4. Applies any newer migrations, then **rebuilds the app role's privileges** from the migrations and verifies them against a freshly migrated reference database. Backups are `--no-acl`, and re-running migration 008 alone leaves the app unable even to create login sessions.
5. Builds and starts the app, publishes it with `tailscale serve --bg --https=443`, and runs a smoke test over the tailnet address.

## On the phone (Samsung S26 Ultra)
1. Open the Tailscale app and make sure it is connected.
2. In Chrome, open `https://<mac>.<tailnet>.ts.net` (the script prints the exact address).
3. Sign in as `admin`. The password is the new local one: on the Mac, run `make copy-password` in the clone to copy it to the clipboard, then send it to the phone through your password manager.
4. Chrome menu → **Add to Home screen** puts an icon on the phone. Until the manifest uses `display: standalone`, it opens as a Chrome tab.

Operations, Registration Viewer and Finance logins are disabled unless their `*_USERNAME` / `*_PASSWORD_HASH` pairs are added to this clone's `.env` (same salted scrypt format as Render). Support email is not configured here, so tickets are not emailed.

## Day to day
| Task | Command (in the clone) |
| --- | --- |
| Status | `scripts/tailnet/deploy-mac.sh status` |
| Deploy newer code, keep data | `git pull && scripts/tailnet/deploy-mac.sh redeploy` |
| Load a newer production backup | `scripts/tailnet/deploy-mac.sh deploy --replace --backup … --key …` (takes a local backup of the current copy first) |
| Backup of this copy | `make backup` (writes to the clone's git-ignored `database/backups/`) |
| Stop (keeps data) | `scripts/tailnet/deploy-mac.sh stop` |

## Security notes
- Anyone on your tailnet can reach the login page. Keep the tailnet to your own devices, or add a Tailscale ACL that limits who can reach the Mac on port 443.
- This copy holds real farmer PII. Treat the Mac's disk, the clone's `.env` and `database/backups/` as sensitive. FileVault should be on.
- Sessions are DB-backed and last 7 days here (`AUTH_SESSION_DAYS`). Changing a password does not end existing sessions. To sign everyone out, run `DELETE FROM auth_sessions;` via `make db-shell` in the clone.
