# Odoo restore runbook

Backups live in restic repo `/home/deploy/backups/restic-local`.
Passphrase: `/home/deploy/.config/restic/password` (root-only).

All commands assume:
```
export RESTIC_REPOSITORY=/home/deploy/backups/restic-local
export RESTIC_PASSWORD_FILE=/home/deploy/.config/restic/password
```
…and run as root (`sudo -i` or prefix each).

## 1. Inspect what's available

```bash
restic snapshots --compact                    # all snapshots
restic snapshots --tag postgres --compact     # just DB dumps
restic snapshots --tag filestore --compact    # just filestore
restic snapshots --tag config --compact       # just configs
restic stats latest                           # size of the most recent snapshot
restic check                                  # quick repo integrity check
```

## 2. Restore the database (full disaster recovery)

This wipes the running `nonprofit` DB and replaces it with the snapshot.

```bash
# Pick the snapshot — `latest` for most recent, or specific ID from `restic snapshots`
SNAP=latest

# Pull the dump out
TMPDIR=$(mktemp -d)
restic restore --target "$TMPDIR" --tag postgres "$SNAP"

# Stop Odoo so nothing reads/writes during restore
cd /home/deploy/odoo && docker compose --env-file .env stop odoo

# Drop and recreate the DB, then load the dump
docker exec -i odoo-postgres psql -U odoo -d postgres -c "DROP DATABASE IF EXISTS nonprofit;"
docker exec -i odoo-postgres psql -U odoo -d postgres -c "CREATE DATABASE nonprofit OWNER odoo;"
docker exec -i odoo-postgres pg_restore -U odoo -d nonprofit --no-owner --no-privileges < "$TMPDIR/nonprofit.dump"

# Restart Odoo
docker compose --env-file .env start odoo

# Cleanup
rm -rf "$TMPDIR"
```

## 3. Restore the filestore

```bash
SNAP=latest
# Restic restores using absolute paths from the snapshot
restic restore --target / --tag filestore "$SNAP"
# This writes back to /home/deploy/odoo/odoo/data/filestore/
# Ownership is preserved (uid 100:101)
```

To restore to a different location for inspection:
```bash
restic restore --target /tmp/filestore-check --tag filestore "$SNAP"
```

## 4. Restore the configs

```bash
SNAP=latest
restic restore --target / --tag config "$SNAP"
# Restores docker-compose.yml, .env, odoo/config/odoo.conf, caddy/Caddyfile to their original paths
```

## 5. Full disaster recovery on a fresh server

1. Reinstall OS, follow Phase 0 hardening (see project memory).
2. Install Docker, Caddy + Odoo images, **restic**.
3. Restore the restic password file + repo to their original paths.
4. Restore configs (step 4 above).
5. `docker compose --env-file .env up -d postgres` — start postgres alone.
6. Restore database (step 2 above), but skip the "stop odoo" step (it isn't running yet).
7. Restore filestore (step 3 above).
8. `docker compose --env-file .env up -d odoo caddy`.

## 6. Common operations

```bash
# Manual backup outside the daily timer
/home/deploy/scripts/backup-odoo.sh

# Trigger via systemd
systemctl start odoo-backup.service

# View backup history
journalctl -u odoo-backup.service --since "7 days ago"

# Forget specific snapshot
restic forget <ID> --prune

# Full deep integrity check (reads all data — slow, do monthly)
restic check --read-data
```

## 7. Off-site

Currently local-only at `/home/deploy/backups/restic-local`. Disk failure = backup loss.
Add off-site by running the same script with a second `RESTIC_REPOSITORY` (sftp/b2/s3).
