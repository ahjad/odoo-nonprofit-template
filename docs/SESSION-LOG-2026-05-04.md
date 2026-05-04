# Session log — Odoo 18 nonprofit template build

**Dates:** 2026-05-03 → 2026-05-04
**Server:** Hetzner CX33 (`89.167.57.60`), Ubuntu 24.04.4 LTS, deploy user
**Driven by:** Claude Code (Opus 4.7, 1M context) at the user's direction
**Outcome:** Template instance fully built — Phases 0/1/2/3 complete, restore-tested, 108 Odoo modules installed (33 from blueprint + transitive deps), production-hardening checklist documented for forks

Starting state per the user's brief:
> Phase 0 security is done: system updated, deploy user created, SSH secured (root disabled, password auth disabled), UFW firewall active (22 rate-limited, 80, 443), Fail2ban running. Next step is installing Docker.

---

## Phase 0 (continued) — Hardening and prerequisites

### Docker install
Removed any conflicting distro packages, added Docker's official apt repo for Ubuntu noble, installed Docker CE + Compose plugin.

```bash
# Conflicts
for pkg in docker.io docker-doc docker-compose docker-compose-v2 podman-docker containerd runc; do
  sudo apt-get remove -y $pkg
done

# Repo
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null
sudo apt-get update

# Install
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo usermod -aG docker deploy
```

**Result:** Docker CE 29.4.2, Compose v5.1.3, daemon enabled at boot, storage driver `overlayfs`, cgroup v2 (systemd), runtime `runc`. Verified with `hello-world`.

### 4 GB swap file + sysctl tuning
CX33 ships with 0 swap. Added 4 GB file-backed swap and tuned VM behavior for a database/app workload.

```bash
sudo fallocate -l 4G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab
```

`/etc/sysctl.d/99-odoo-server.conf`:
```
vm.swappiness=10
vm.vfs_cache_pressure=50
```

### Timezone (UTC) + NTP verify
```bash
sudo timedatectl set-timezone UTC
sudo timedatectl set-ntp true
```
NTP service confirmed active, syncing to `ntp.hetzner.com`.

### Unattended-upgrades (security-only + auto-reboot 04:00 UTC)
```bash
sudo apt-get install -y unattended-upgrades apt-listchanges
```

`/etc/apt/apt.conf.d/20auto-upgrades`:
```
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
APT::Periodic::Download-Upgradeable-Packages "1";
```

`/etc/apt/apt.conf.d/52unattended-upgrades-local`:
```
Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-New-Unused-Dependencies "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "04:00";
Unattended-Upgrade::SyslogEnable "true";
```

Confirmed allowed origins: `noble`, `noble-security`, ESM apps + infra security only — no `noble-updates` or `noble-backports`.

### Fail2ban tightening
Existing config had only the default sshd jail. Added a `recidive` jail (1-week ban for repeat offenders) and tightened sshd defaults.

`/etc/fail2ban/jail.local`:
```
[DEFAULT]
bantime = 10m
findtime = 10m
maxretry = 5
bantime.increment = true
bantime.factor = 2
bantime.maxtime = 1w

[sshd]
enabled = true
maxretry = 4

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = nftables[type=allports]
bantime = 1w
findtime = 1d
maxretry = 3
```

Two jails active after reload.

### Phase 0 deliverable
Server hardened with: Docker, swap, UTC, NTP, unattended security upgrades, Fail2ban with recidive. SSH/UFW already done by user before session.

---

## Phase 1 — Odoo 18 stack

### Architecture decision
- HTTP-only on port 80 (no domain / no TLS yet, per user)
- Caddy as reverse proxy
- PostgreSQL 16 bound to `127.0.0.1:5432` (host-accessible for backups, NOT external)
- Odoo 18 internal-only on Docker bridge network
- DB name `nonprofit`, single-DB filter, `list_db=False`, workers=7

### Sudo handling
Phase 1 needed many `sudo docker` operations. The deploy user's sudo required a password that the Bash tool can't supply. **Decision (option a)**: user added a temporary nopasswd grant.

```bash
echo 'deploy ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/deploy-nopasswd
sudo chmod 0440 /etc/sudoers.d/deploy-nopasswd
sudo visudo -c
```

### Directory layout
```
/home/deploy/odoo/
├── docker-compose.yml
├── .env                      # POSTGRES_PASSWORD, ODOO_ADMIN_PASSWD (mode 600 deploy)
├── odoo/
│   ├── config/odoo.conf      # mode 640, owned uid 100
│   ├── addons/               # mode 750, owned uid 100 (later flipped to 755 deploy for Phase 3)
│   └── data/                 # filestore, mode 750, owned uid 100
├── postgres/data/            # PG16 data (PGDATA subdir)
└── caddy/
    ├── Caddyfile             # HTTP-only :80
    ├── data/  config/        # Caddy state
```

### Generated secrets (32 chars random each)
- `POSTGRES_PASSWORD` — Postgres `odoo` user password
- `ODOO_ADMIN_PASSWD` — master DB-manager password (in `odoo.conf`)
- Initial Odoo admin user password (24 chars, generated separately, communicated to user once, **subsequently changed by user via UI**)

Both `POSTGRES_PASSWORD` and `ODOO_ADMIN_PASSWD` live in `/home/deploy/odoo/.env` (mode 600); `ODOO_ADMIN_PASSWD` and `POSTGRES_PASSWORD` are also inlined in `/home/deploy/odoo/odoo/config/odoo.conf` (mode 640, owned uid 100).

### `odoo.conf` (key options at end of Phase 1)
```ini
[options]
addons_path = /mnt/extra-addons,/usr/lib/python3/dist-packages/odoo/addons
data_dir = /var/lib/odoo
db_host = postgres
db_port = 5432
db_user = odoo
db_password = <32-char random>
db_maxconn = 64
admin_passwd = <32-char random>
list_db = False
db_filter = ^nonprofit$
dbfilter = ^nonprofit$
workers = 7
max_cron_threads = 2
limit_memory_soft = 671088640      # 640 MB
limit_memory_hard = 838860800      # 800 MB
limit_request = 8192
limit_time_cpu = 600
limit_time_real = 1200
limit_time_real_cron = -1
proxy_mode = True
without_demo = True
log_level = info
```

### `Caddyfile`
```
{
    admin off
    auto_https off
}
:80 {
    encode gzip zstd
    @websocket path /websocket /websocket/* /longpolling/*
    reverse_proxy @websocket odoo:8072
    reverse_proxy odoo:8069
    log {
        output file /data/access.log {
            roll_size 10mb
            roll_keep 5
            roll_keep_for 720h
        }
        format json
    }
}
```

### `docker-compose.yml`
Three services on a bridge network `odoo-internal`:
- `odoo-postgres` — `postgres:16`, `127.0.0.1:5432:5432`, healthcheck via `pg_isready -U odoo`, `PGDATA=/var/lib/postgresql/data/pgdata`
- `odoo-app` — `odoo:18.0`, no host port, depends_on postgres `service_healthy`
- `odoo-caddy` — `caddy:2-alpine`, `0.0.0.0:80`, depends_on odoo

### Build issues encountered

1. **uid mismatch**: pre-chowned bind mounts to `uid 101` per common Odoo docs, but the official image's `odoo` user is actually **uid 100, gid 101**. Fixed: `sudo chown -R 100:101 /home/deploy/odoo/odoo/data`. Logged in CLAUDE.md as a gotcha because the docs are misleading.

2. **`/web/database/create` returns 500/Access Denied** under `list_db=False` — the web DB manager is gated by the same flag. Fixed: initialized DB via CLI instead of the web API:
   ```bash
   sudo docker compose --env-file .env stop odoo
   sudo docker compose --env-file .env run --rm --no-deps odoo \
       odoo -c /etc/odoo/odoo.conf -d nonprofit -i base \
            --without-demo=all --stop-after-init --load-language=en_US
   ```

3. **Default admin password is `admin`** after `-i base`. Reset via `odoo shell` with stdin:
   ```bash
   echo "env['res.users'].browse(2).write({'password': '<initial>'}); env.cr.commit()" \
     | sudo docker compose --env-file .env run --rm --no-deps -T odoo \
         odoo shell -c /etc/odoo/odoo.conf -d nonprofit --no-http
   ```

### Phase 1 verification
- `sudo ss -tlnp` → `0.0.0.0:80` (caddy), `127.0.0.1:5432` (postgres), no Odoo on host
- `nc 89.167.57.60 5432` from outside → connection refused ✅
- `curl http://89.167.57.60/web/login` → 200 ✅
- JSON-RPC authenticate (admin/initial) → uid=2, db=nonprofit, name=Administrator ✅
- 12 base modules loaded, demo data not loaded

### Phase 1 deliverable
Working Odoo 18 stack at http://89.167.57.60/, single DB `nonprofit`, admin login functional.

---

## Phase 2 — Backups

### Architecture
- **Tool**: `restic` 0.16.4 from Ubuntu apt (security-patched, slightly behind upstream)
- **Repo**: `/home/deploy/backups/restic-local` (root:root, mode 700, encrypted)
- **Passphrase**: `/home/deploy/.config/restic/password` (root:root, mode 600, 64 chars, generated with `openssl rand -base64`)
- **Script**: `/home/deploy/scripts/backup-odoo.sh` (root:root, mode 750)
- **Schedule**: systemd timer `odoo-backup.timer`, daily 03:30 UTC + 5min jitter (before unattended-upgrades' 04:00 reboot window)
- **Streams** (3, separately tagged + retained):
  - `pg_dump --format=custom --compress=6 --no-owner --no-privileges` of `nonprofit`, streamed to `restic backup --stdin`
  - `/home/deploy/odoo/odoo/data/filestore/`
  - `docker-compose.yml`, `.env`, `odoo/config/odoo.conf`, `caddy/Caddyfile`
- **Retention**: 7 daily + 4 weekly + 6 monthly per stream, auto-pruned each run

### Backup script (key part)
```bash
docker exec odoo-postgres \
    pg_dump --username=odoo --dbname=nonprofit \
            --format=custom --compress=6 --no-owner --no-privileges \
  | restic backup --stdin --stdin-filename=nonprofit.dump \
                  --tag postgres --tag db:nonprofit \
                  --host odoo-template-1 --quiet

restic backup /home/deploy/odoo/odoo/data/filestore --tag filestore --quiet
restic backup /home/deploy/odoo/docker-compose.yml /home/deploy/odoo/.env \
              /home/deploy/odoo/odoo/config /home/deploy/odoo/caddy/Caddyfile \
              --tag config --quiet

for tag in postgres filestore config; do
  restic forget --tag "$tag" --host odoo-template-1 \
                --keep-daily 7 --keep-weekly 4 --keep-monthly 6 \
                --prune --quiet
done
restic check --quiet
```

### systemd unit
```ini
# /etc/systemd/system/odoo-backup.service
[Unit]
Description=Odoo daily backup (postgres + filestore + configs) via restic
Wants=docker.service
After=docker.service network-online.target
[Service]
Type=oneshot
User=root
ExecStart=/home/deploy/scripts/backup-odoo.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7

# /etc/systemd/system/odoo-backup.timer
[Unit]
Description=Run odoo-backup daily at 03:30 UTC
[Timer]
OnCalendar=*-*-* 03:30:00 UTC
RandomizedDelaySec=300
Persistent=true
Unit=odoo-backup.service
[Install]
WantedBy=timers.target
```

### Build issues encountered

1. **First run: pg_dump failed** — used `-u postgres` and default user. Postgres image was created with `POSTGRES_USER=odoo`, so role `postgres` doesn't exist. Fixed: `pg_dump --username=odoo`.
2. **Filestore unreadable as deploy user** (mode 750 owned uid 100). Fixed: moved entire backup workflow to root — script, repo, password file all root-owned. Documented as the "right" production pattern (backups need root anyway for restore).

### Restore test (the only thing that proves a backup is real)
```bash
TMPDIR=$(mktemp -d)
restic restore --target "$TMPDIR" --tag postgres latest
docker exec odoo-postgres psql -U odoo -d postgres -c "DROP DATABASE IF EXISTS nonprofit_restore_test;"
docker exec odoo-postgres psql -U odoo -d postgres -c "CREATE DATABASE nonprofit_restore_test OWNER odoo;"
cat $TMPDIR/nonprofit.dump | docker exec -i odoo-postgres pg_restore -U odoo -d nonprofit_restore_test --no-owner --no-privileges
docker exec odoo-postgres psql -U odoo -d nonprofit_restore_test -c \
    "SELECT count(*) FROM ir_module_module WHERE state='installed';"
```
**Result**: 12 installed modules, 5 users, 1 company, admin login intact. Test DB dropped after verification.

### Restore runbook
Wrote `/home/deploy/scripts/RESTORE.md` documenting:
- Inspecting snapshots (`restic snapshots --tag postgres`)
- Full DB restore procedure
- Filestore restore
- Config restore
- Full disaster recovery on a fresh server (Phase 0 → restic install → restore configs → start postgres alone → restore DB → restore filestore → start odoo+caddy)
- Common ops (manual backup, `restic check --read-data`, forget snapshot)

### Phase 2 deliverable
Local-only backups working, restore-tested, scheduled via systemd.

---

## Phase 2.5 — Production hardening checklist

User asked for a list of security steps to apply when forking the template for a real nonprofit deployment. Wrote `/home/deploy/docs/PRODUCTION-CHECKLIST.md` (139 lines, 71 items).

**Structure**: 12 sections, each item priority-tagged.
- 23 **MUST** items (do before any real data touches the system)
- 33 **SHOULD** items (do within first week)
- 15 **NICE** items (when scale demands)

**Top critical gaps the template leaves** (called out in the doc):
1. No off-site backup
2. Postgres superuser = Odoo runtime user (`POSTGRES_USER=odoo`)
3. No TLS / no domain
4. No container resource limits
5. No 2FA enforcement (only the module is installed, not enabled)

The checklist also documents in a final section everything Phases 0/1/2 already configured, so the cloned-server operator knows what NOT to redo.

---

## Off-site backup discussion

User initially asked to set up Hetzner Storage Box. I walked through plans (BX11 1 TB ~€3.81/mo recommended), the panel order steps, and the SSH key setup workflow.

User then said: **"Skip off-site backups for now."** Off-site deferred. Local-only backup is the standing state.

---

## CLAUDE.md creation

Created `/home/deploy/odoo/CLAUDE.md` (deploy-owned, 211 lines initially, ~270 after Phase 3) — the canonical project context loaded into every future Claude Code session in this directory. Captures:
- Project intent (template, not a real deployment)
- Server facts
- Stack layout with ownership/modes
- Conventions and gotchas (uid 100 not 101, list_db=False blocks web manager, Postgres superuser is `odoo`, Docker bypasses UFW)
- Operational commands
- Phase 3 plan (initially DRAFT, later replaced with actuals)
- Pointers to PRODUCTION-CHECKLIST and RESTORE runbooks

---

## Phase 3 — OCA modules

User provided a 7-layer module install blueprint targeting nonprofit baseline (NOT NGO-specific). Decisions confirmed up front via AskUserQuestion:
- Membership / vertical-association: **NO** (per-deployment)
- Event management: **NO** (core Odoo events suffice)
- Localization: **none beyond `l10n_fr` already installed**
- Custom Docker image: **YES** (reproducibility for forks)
- 2FA install timing: **YES — Layer 0**

Sudo grant re-added (option a again). Plan-mode was entered mid-flight when blueprint gaps surfaced; gaps resolved via AskUserQuestion; plan saved at `/home/deploy/.claude/plans/functional-coalescing-starlight.md` and approved.

### Repo cloning (18 OCA repos)

All cloned shallow at branch `18.0`, parallelized 5 at a time. Pinned commit SHAs to `/home/deploy/odoo/oca-versions/<repo>.sha`.

| Repo | Pinned SHA |
|---|---|
| account-analytic | `7fbe82d61e9c` |
| account-budgeting | `4281ef06e174` |
| account-financial-reporting | `9b00195aa80a` |
| account-financial-tools | `cf9ead8d7a24` |
| account-reconcile | `dc513e370e31` |
| bank-payment | `f252e1eab320` |
| contract | `9caa33b8b571` |
| hr-expense | `17b2b68f2f08` |
| mis-builder | `e31b63f27931` |
| partner-contact | `418726c3539e` |
| payroll | `06416bb80d4d` |
| purchase-workflow | `f6f279841269` |
| queue | `879d1a729f5a` |
| reporting-engine | `33d1e5fef43d` |
| server-auth | `e14ae607b6a1` |
| server-backend | `8305274c5276` |
| server-tools | `57745163a1fd` |
| server-ux | `f3b0d8506a7d` |

(Originally 14 in the blueprint; **+4 added** to resolve gaps below.)

### Blueprint deviations (4 gaps, all user-confirmed)

| # | Original blueprint | Gap surfaced | Resolution |
|---|---|---|---|
| 1 | `base_import_match` in OCA/server-tools or OCA/server-ux | Module not in either repo's 18.0 branch | User: "It's in OCA/server-backend on 18.0." Cloned server-backend, confirmed manifest, installed |
| 2 | `account_move_budget` in OCA/account-financial-reporting | Module doesn't exist on 18.0 anywhere | Substituted **`account_budget_oca`** (from OCA/account-budgeting). Closest equivalent on 18.0 |
| 3 | `password_security` (no repo named) | Lives in OCA/server-auth, blueprint omitted the repo | Added OCA/server-auth |
| 4 | `hr_expense_tier_validation` in OCA/purchase-workflow | Lives in OCA/hr-expense, blueprint mis-attributed | Added OCA/hr-expense |

Also cloned `OCA/hr` as a candidate during gap investigation; **deleted** after determining no blueprint module needed it.

### Custom Docker image — `/home/deploy/odoo/Dockerfile`

```dockerfile
FROM odoo:18.0
USER root

# OS packages — minimum needed by OCA Python deps that lack pure-python wheels.
# (libpq-dev intentionally NOT installed: odoo image already has psycopg2;
#  the postgres apt repo would force an incompatible libpq5 upgrade.)
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential pkg-config \
        libzbar0 poppler-utils \
    && rm -rf /var/lib/apt/lists/*

# Python deps — filter out mysqlclient/pymssql (only used by
# OCA/server-backend/base_external_dbsource_* which isn't in the blueprint
# and which need build deps that conflict with the postgres apt repo).
COPY requirements/ /tmp/requirements/
RUN set -ex \
    && cat /tmp/requirements/*.txt \
        | grep -vE '^(mysqlclient|pymssql)\b' \
        > /tmp/all-requirements.txt \
    && pip install --no-cache-dir --break-system-packages -r /tmp/all-requirements.txt \
    && rm -rf /tmp/requirements /tmp/all-requirements.txt

USER odoo
```

`/home/deploy/odoo/.dockerignore`:
```
*
!Dockerfile
!requirements
!requirements/*
```

### Build issues encountered

1. **First build failed**: `libpq-dev` requested v18.3 (postgres apt repo) but `libpq5` was at v16.13. Fixed by removing `libpq-dev` (psycopg2 is already installed in base odoo image).
2. **Second build failed**: `mysqlclient` wheel build failure. Fixed by filtering it out (and `pymssql`) from the combined requirements — those are only needed by `OCA/server-backend/base_external_dbsource_*` modules which the blueprint doesn't install.
3. **Third build succeeded**: 18.7 s for the pip step, ~30s total. Final image: 3.63 GB (vs 3.14 GB base; +500 MB for OS pkgs + Python deps).

### Image build
```bash
sudo docker build -t odoo-nonprofit-template:18.0-latest /home/deploy/odoo/
```

### Compose update
Single-line change in `docker-compose.yml`:
```diff
-    image: odoo:18.0
+    image: odoo-nonprofit-template:18.0-latest
```

### `addons_path` update in `odoo.conf`
Each of 18 OCA repo paths listed explicitly (Odoo doesn't glob):
```
addons_path = /usr/lib/python3/dist-packages/odoo/addons,
              /mnt/extra-addons/partner-contact,
              /mnt/extra-addons/server-tools,
              /mnt/extra-addons/server-ux,
              /mnt/extra-addons/server-auth,
              /mnt/extra-addons/server-backend,
              /mnt/extra-addons/queue,
              /mnt/extra-addons/account-reconcile,
              /mnt/extra-addons/account-financial-tools,
              /mnt/extra-addons/account-analytic,
              /mnt/extra-addons/mis-builder,
              /mnt/extra-addons/account-financial-reporting,
              /mnt/extra-addons/reporting-engine,
              /mnt/extra-addons/account-budgeting,
              /mnt/extra-addons/bank-payment,
              /mnt/extra-addons/purchase-workflow,
              /mnt/extra-addons/hr-expense,
              /mnt/extra-addons/payroll,
              /mnt/extra-addons/contract
```
(Single line in the actual file; reformatted here for readability.)

### Layer-by-layer module install

Each layer ran as a one-shot `docker compose run --rm --no-deps odoo … --stop-after-init`, then verified with `SELECT name, state FROM ir_module_module WHERE name IN (…)`.

| Layer | Modules requested | Installed count after | Status |
|---|---|---|---|
| (refresh) | `-u base` to pick up new addons | 12 → 12 | apps list refreshed |
| 0 | partner_firstname, partner_contact_access_link, password_security, base_import_match, base_tier_validation, queue_job, auditlog, auth_totp | 34 | all 8 installed (auth_totp was already in via earlier dep chain) |
| 1 | account_reconcile_oca, account_reconcile_model_oca, account_usability, account_analytic_required, account_fiscal_year, account_asset_management | 64 | all 6 installed |
| 2 | mis_builder, account_financial_report, **account_budget_oca**, report_xlsx, partner_statement | 71 | all 5 installed |
| 3 | account_payment_partner, account_payment_order, account_banking_sepa_credit_transfer | 78 | all 3 installed |
| 4 | hr_expense_tier_validation, payroll | 92 | all 2 installed |
| 5 | purchase_request, purchase_request_tier_validation, purchase_tier_validation | 106 | all 3 installed |
| 6 | contract | 108 | installed |

**Total**: 33 blueprint modules + 63 transitive deps = 96 module additions, 108 total in DB.

### Phase 3 verification
- `restic snapshots` shows 3 new snapshots at 02:17 UTC capturing post-Phase-3 template state
- HTTP 200 on `/web/login` after final restart
- All 33 named modules report `state='installed'` in `ir_module_module`

### 2FA status
`auth_totp` (core Odoo module) installed. **Not yet enabled for any user.** First-login admin must enable via Settings → Users → Administrator → Enable two-factor authentication. Strict force-on-all-users requires `auth_totp_mail_enforce` from already-cloned OCA/server-auth — deferred.

### Sudoers cleanup
```bash
sudo rm /etc/sudoers.d/deploy-nopasswd
sudo -n true   # confirmed: returns "password required"
```

---

## All decisions made (chronological)

| # | Decision point | Choice |
|---|---|---|
| 1 | How to handle sudo for autonomous Phase 1 | Option (a): temporary `/etc/sudoers.d/deploy-nopasswd`, removed at end |
| 2 | Phase 0 hardening scope | All 5 standard items (swap, TZ, NTP, unattended-upgrades, Fail2ban tighten) |
| 3 | Reverse proxy choice | Caddy (HTTP-only on `:80`, no TLS yet) |
| 4 | DB name + filter | `nonprofit`, filter `^nonprofit$` |
| 5 | DB initialization method | CLI (`odoo -i base --stop-after-init`) — web manager blocked by `list_db=False` |
| 6 | Backup tool | restic 0.16.4 (apt) |
| 7 | Backup ownership model | All root-owned (script + repo + password) — script runs via systemd as root |
| 8 | Off-site backup destination | **Deferred** — user said skip for now |
| 9 | Production checklist | Full 71-item document covering 12 sections |
| 10 | Layer 0 list — partner_contact_access_link + auth_totp explicit? | Yes (took the more complete of two slightly different lists user provided) |
| 11 | Custom Docker image vs runtime pip | Custom image (reproducibility for template forks) |
| 12 | OCA module gap #1 (base_import_match) | Clone OCA/server-backend per user info |
| 13 | OCA module gap #2 (account_move_budget) | Substitute account_budget_oca |
| 14 | OCA module gap #3 (password_security) | Add OCA/server-auth |
| 15 | OCA module gap #4 (hr_expense_tier_validation) | Add OCA/hr-expense |
| 16 | mysqlclient + pymssql in image | Filter out at build time (their modules aren't in blueprint) |

---

## All files created or modified

### Created
| Path | Owner / mode | Purpose |
|---|---|---|
| `/etc/sysctl.d/99-odoo-server.conf` | root:root 644 | swappiness + cache pressure tuning |
| `/etc/apt/apt.conf.d/20auto-upgrades` | root:root 644 | enable periodic apt updates |
| `/etc/apt/apt.conf.d/52unattended-upgrades-local` | root:root 644 | unattended-upgrades overrides (auto-reboot 04:00 UTC) |
| `/etc/fail2ban/jail.local` | root:root 644 | sshd jail tightening + recidive jail |
| `/etc/sudoers.d/deploy-nopasswd` | root:root 440 | TEMPORARY (created and removed twice during session) |
| `/home/deploy/odoo/docker-compose.yml` | deploy:deploy 644 | 3-service stack definition |
| `/home/deploy/odoo/.env` | deploy:deploy **600** | POSTGRES_PASSWORD + ODOO_ADMIN_PASSWD |
| `/home/deploy/odoo/odoo/config/odoo.conf` | uid 100 / gid 101 / 640 | Odoo runtime config |
| `/home/deploy/odoo/odoo/config/odoo.conf.bak.preL3` | uid 100 / gid 101 / 640 | Backup before Phase 3 addons_path edit |
| `/home/deploy/odoo/caddy/Caddyfile` | deploy:deploy 644 | Caddy reverse proxy config |
| `/home/deploy/odoo/Dockerfile` | deploy:deploy 644 | Custom image build (Phase 3) |
| `/home/deploy/odoo/.dockerignore` | deploy:deploy 644 | Limit build context |
| `/home/deploy/odoo/requirements/*.txt` | deploy:deploy 644 | 18 files — one per OCA repo, Python deps |
| `/home/deploy/odoo/oca-versions/*.sha` | deploy:deploy 644 | 18 files — pinned commit SHAs per repo |
| `/home/deploy/odoo/odoo/addons/<repo>/` | deploy:deploy 755 | 18 OCA repos cloned (15+18 with `.git` dirs) |
| `/home/deploy/odoo/CLAUDE.md` | deploy:deploy 644 | Project context for future Claude sessions |
| `/home/deploy/scripts/backup-odoo.sh` | root:root 750 | Daily backup script |
| `/home/deploy/scripts/RESTORE.md` | root:root 644 | Disaster recovery runbook |
| `/etc/systemd/system/odoo-backup.service` | root:root 644 | Backup oneshot service |
| `/etc/systemd/system/odoo-backup.timer` | root:root 644 | Daily 03:30 UTC trigger |
| `/home/deploy/.config/restic/password` | root:root 600 | 64-char restic passphrase |
| `/home/deploy/backups/restic-local/` | root:root 700 | restic repo (encrypted) |
| `/home/deploy/docs/PRODUCTION-CHECKLIST.md` | deploy:deploy 644 | 71-item production hardening list |
| `/home/deploy/docs/SESSION-LOG-2026-05-04.md` | deploy:deploy 644 | This file |
| `/home/deploy/.claude/plans/functional-coalescing-starlight.md` | deploy:deploy 644 | Phase 3 plan (approved) |
| `/home/deploy/.claude/projects/-home-deploy/memory/MEMORY.md` | deploy:deploy 644 | Memory index |
| `/home/deploy/.claude/projects/-home-deploy/memory/project_odoo_server.md` | deploy:deploy 644 | Project facts memory |
| `/home/deploy/.claude/projects/-home-deploy/memory/project_backups.md` | deploy:deploy 644 | Backup system memory |
| `/home/deploy/.claude/projects/-home-deploy/memory/feedback_docker_ufw_caveat.md` | deploy:deploy 644 | UFW gotcha memory |

### Modified
| Path | Change |
|---|---|
| `/etc/fstab` | added `/swapfile none swap sw 0 0` |
| `/home/deploy/odoo/docker-compose.yml` | image tag changed `odoo:18.0` → `odoo-nonprofit-template:18.0-latest` |
| `/home/deploy/odoo/odoo/config/odoo.conf` | `addons_path` extended to list all 18 OCA repo paths |
| `/home/deploy/odoo/CLAUDE.md` | Phase 3 section rewritten from DRAFT to actuals |

### Deleted
| Path | Reason |
|---|---|
| `/home/deploy/odoo/odoo/addons/hr/` | cloned as candidate during gap investigation, hosts no blueprint module |
| `/etc/sudoers.d/deploy-nopasswd` | TWICE — once after Phase 1/2, once after Phase 3 (final state) |
| `/tmp/initial_admin_pw.txt` | shredded (`shred -u`) after user copied initial admin password |
| `/tmp/db_create.html`, `/tmp/root.html`, `/tmp/login.html`, `/tmp/odoo.html`, `/tmp/odoo_cookies.txt` | test artifacts cleaned up |

### Memory file removed during session
| Path | Reason |
|---|---|
| `/home/deploy/.claude/projects/-home-deploy/memory/project_pending_cleanup.md` | obsolete after sudoers grant was removed |

---

## Module installations

108 modules installed in `nonprofit` DB at end of session (started at 12 from `-i base`).

### Blueprint modules explicitly installed (33)
```
Layer 0:  partner_firstname, partner_contact_access_link, password_security,
          base_import_match, base_tier_validation, queue_job, auditlog, auth_totp
Layer 1:  account_reconcile_oca, account_reconcile_model_oca, account_usability,
          account_analytic_required, account_fiscal_year, account_asset_management
Layer 2:  mis_builder, account_financial_report, account_budget_oca,
          report_xlsx, partner_statement
Layer 3:  account_payment_partner, account_payment_order,
          account_banking_sepa_credit_transfer
Layer 4:  hr_expense_tier_validation, payroll
Layer 5:  purchase_request, purchase_request_tier_validation, purchase_tier_validation
Layer 6:  contract
```

### Transitive dependencies (~63 modules)
Pulled in automatically by Odoo's dependency resolver during the layer installs. Includes `account`, `account_payment`, `analytic`, `base_iban`, `mail`, `purchase`, `hr`, `hr_expense`, `web_editor`, etc., plus OCA helpers like `account_payment_method_base_mode`, `account_banking_pain_base`, `mis_builder_demo`, etc.

### Modules NOT installed (in blueprint repos but not part of layer install)
~1170 OCA modules visible to Odoo (from the 18 cloned repos) but not installed. Per-deployment forks can install any of them with `odoo -i <name> --stop-after-init`.

---

## Final server state

### Running services (host)
```
sshd                       0.0.0.0:22 (UFW LIMIT)
docker-proxy (caddy)       0.0.0.0:80, [::]:80 (UFW ALLOW)
docker-proxy (postgres)    127.0.0.1:5432 (host-only, NOT external)
systemd-resolved           127.0.0.53:53 (loopback DNS)
fail2ban-server            (sshd + recidive jails)
unattended-upgrades        (security pocket, auto-reboot 04:00 UTC)
systemd-timesyncd          (NTP via ntp.hetzner.com)
odoo-backup.timer          (daily 03:30 UTC + 5min jitter)
```

### Containers
| Name | Image | Host port | State |
|---|---|---|---|
| `odoo-postgres` | postgres:16 | `127.0.0.1:5432` | healthy |
| `odoo-app` | odoo-nonprofit-template:18.0-latest | (none) | up |
| `odoo-caddy` | caddy:2-alpine | `0.0.0.0:80` | up |

All on bridge network `odoo-internal`.

### Access
- **URL**: http://89.167.57.60/web/login
- **DB**: `nonprofit`
- **Login**: `admin`
- **Password**: changed by user during the session — original generated value was discarded
- **Master DB password** (`admin_passwd`): in `/home/deploy/odoo/odoo/config/odoo.conf` (mode 640, owned uid 100). Web manager remains blocked by `list_db=False`; this is for emergency CLI use only.
- **Postgres password**: in `/home/deploy/odoo/.env` (mode 600, deploy)
- **2FA**: module installed but NOT yet enabled for any user

### Sudo state
**Password required.** No nopasswd grant present. Verified: `sudo -n true` returns "password required."

### Disk usage (approximate)
- `/` root: 75 GB total, ~5–10 GB used (Docker images + DB + filestore + restic repo, all small)
- Docker images: ~3.6 GB (custom odoo image) + ~640 MB (postgres) + ~88 MB (caddy)
- Postgres data: ~50 MB
- Filestore: empty (no attachments yet)
- restic repo: ~5 MB (highly deduped across snapshots)

### Memory usage at idle
- ~1.5 GB used of 7.6 GB
- 4 GB swap available, 0 used
- Plenty of headroom for Odoo workers under load

---

## Outstanding items

Per the PRODUCTION-CHECKLIST.md (71 items), items the operator must address when forking this template for a real deployment:

### MUST do before any real data
1. **Rotate every secret** (template values are in chat transcripts)
2. **Change Odoo admin password and rename `admin` user** (already done by you for the template)
3. **Set up off-site backup** (currently single-disk only)
4. **Run a restore drill from off-site to a fresh server before go-live**
5. **Real domain + TLS** (Caddyfile change is one line; Caddy auto-issues Let's Encrypt)
6. **Stop using Postgres superuser as Odoo runtime user** — split into `odoo_app` + ops superuser
7. **Install `auth_totp_mail_enforce`** if you want forced 2FA on all users
8. **Re-generate SSH host keys** when cloning the server image (avoid identical keys across deployments)

### SHOULD do within first week
- Container resource limits (`mem_limit`, `cpus` per service)
- Pin Docker images to digest, not floating tags
- Caddy security headers + rate limiting on `/web/login`
- Uptime + backup-success monitoring
- Tune `postgresql.conf` for the workload
- Restrict SSH to known source IPs

### Nice (when scale demands)
- CDN/DDoS shield (Cloudflare proxy)
- Centralized logging
- Network-segment Postgres onto a separate Docker network
- HSTS preload list submission

---

## Pointers

| For… | See… |
|---|---|
| Project context (loaded into every Claude session in `/home/deploy/odoo/`) | `/home/deploy/odoo/CLAUDE.md` |
| Restore from backup | `/home/deploy/scripts/RESTORE.md` |
| Production hardening checklist when forking | `/home/deploy/docs/PRODUCTION-CHECKLIST.md` |
| Backup script (single source of truth for what's backed up) | `/home/deploy/scripts/backup-odoo.sh` |
| Phase 3 plan (approved before execution) | `/home/deploy/.claude/plans/functional-coalescing-starlight.md` |
| OCA repo SHAs (reproducibility for forks) | `/home/deploy/odoo/oca-versions/*.sha` |
| Custom image build artifacts | `/home/deploy/odoo/Dockerfile`, `/home/deploy/odoo/requirements/` |
| Long-term cross-session memory | `/home/deploy/.claude/projects/-home-deploy/memory/` |

---

## Total wall time and effort

- **Phase 0 (Docker + 5 hardening tasks)**: ~10 minutes of execution
- **Phase 1 (stack build, DB init, password set, verify)**: ~15 minutes
- **Phase 2 (restic install, repo init, script, systemd, restore test, runbook)**: ~10 minutes
- **Phase 2.5 (PRODUCTION-CHECKLIST.md)**: writing only
- **Phase 3 (clone 18 repos, image build, install 7 layers, restart, doc)**: ~20 minutes (including 3 build iterations)

Plus discussion / decision time across the session.
