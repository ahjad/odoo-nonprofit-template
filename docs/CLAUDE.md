# Odoo 18 Community — Nonprofit template

This file is the canonical project context. Read it first in every session. If anything below is wrong, fix the file rather than working around it.

---

## What this is

A reusable **template** for deploying Odoo 18 Community for nonprofits on a single Hetzner CX33 server. The intent is that this template gets cloned per nonprofit; everything in this repo should be generic. Nonprofit-specific configuration (real domain, real branding, real localization, real legal-entity records) belongs in a fork, not here.

## Server facts (template instance)

- **Host:** Hetzner CX33 (2 vCPU / 8 GB RAM / 75 GB SSD)
- **IP:** `89.167.57.60` (template only — a real deployment gets its own)
- **OS:** Ubuntu 24.04 LTS (noble)
- **Admin user:** `deploy` (sudo, docker), uid 1000
- **Sudo:** password required (passwordless grant was removed)
- **Time:** UTC, NTP via Hetzner

Phase 0 hardening (SSH, UFW, Fail2ban, swap, unattended-upgrades) is documented in `/home/deploy/docs/PRODUCTION-CHECKLIST.md` under "What's already in this template."

## Stack layout

```
/home/deploy/odoo/
├── CLAUDE.md                 # this file
├── docker-compose.yml        # 3 services on internal bridge network
├── .env                      # POSTGRES_PASSWORD, ODOO_ADMIN_PASSWD (mode 600, deploy)
├── odoo/
│   ├── config/odoo.conf      # workers=7, list_db=False, db_filter=^nonprofit$, proxy_mode=True (mode 640, uid 100)
│   ├── addons/               # base custom addons (mounted at /mnt/extra-addons)
│   └── data/                 # filestore + sessions (uid 100:101, mode 750)
├── oca/                      # OCA module repos, each cloned as a subdirectory (planned for Phase 3)
├── postgres/data/            # Postgres 16 data (PGDATA subdir)
└── caddy/
    ├── Caddyfile             # HTTP-only :80, proxies to odoo:8069 + odoo:8072 (websocket/longpolling)
    ├── data/  config/        # Caddy state
```

Backups (separate path):
```
/home/deploy/scripts/
├── backup-odoo.sh            # daily restic backup (root:root, mode 750)
└── RESTORE.md                # restore runbook

/home/deploy/backups/restic-local/        # restic repo (root-only, encrypted)
/home/deploy/.config/restic/password      # 64-char passphrase (root-only)
/etc/systemd/system/odoo-backup.{service,timer}   # daily 03:30 UTC ± 5min jitter
```

## Conventions and gotchas

- **The Odoo container's `odoo` user is uid 100, gid 101** — NOT 101 as the official docs imply. Bind mounts under `./odoo/` must be chowned `100:101`.
- **Postgres superuser is `odoo`, not `postgres`** — `POSTGRES_USER=odoo` at container creation. Every `pg_dump`, `psql`, `pg_restore` call must use `-U odoo`. *(This is itself a production gap; see PRODUCTION-CHECKLIST.md §7 — split into `odoo_app` runtime user vs ops superuser.)*
- **`list_db=False` blocks the web database manager** — including `/web/database/create`. Initialize databases via `odoo -i base --without-demo=all --stop-after-init` from a one-shot `docker compose run --rm`. Never enable the web manager just to "make it easier."
- **Docker bypasses UFW.** Any container port published as `-p host:container` is internet-reachable regardless of UFW. Postgres is bound to `127.0.0.1:5432` for that reason. Only Caddy binds to `0.0.0.0`. *Never* publish a new container port on `0.0.0.0` without thinking — bind to `127.0.0.1` first.
- **Backups run as root** because the filestore is mode 750 owned by uid 100. The systemd service runs root; `restic` repo and password file are root-owned. Deploy needs `sudo` to inspect snapshots.
- **Default admin login is `admin`** in any newly-init'd DB. Production deployments must rename or disable this user (see PRODUCTION-CHECKLIST.md §1).
- **Caddy auto_https is OFF.** When swapping to a real domain, change Caddyfile's `:80 {` block to `your.domain {` and remove the `auto_https off` line — Caddy will then auto-issue Let's Encrypt.

## Operational commands

All `docker compose` commands assume cwd = `/home/deploy/odoo/` and the `--env-file .env` flag.

```bash
cd /home/deploy/odoo

# Status
sudo docker compose ps
sudo docker compose --env-file .env config

# Start/stop
sudo docker compose --env-file .env up -d
sudo docker compose --env-file .env down                  # keeps volumes
sudo docker compose --env-file .env restart odoo

# Logs (live)
sudo docker compose logs -f odoo
sudo docker compose logs -f --tail 100 caddy postgres

# One-shot Odoo CLI (without disturbing running workers)
sudo docker compose --env-file .env run --rm --no-deps odoo \
    odoo -c /etc/odoo/odoo.conf -d nonprofit -u <module> --stop-after-init

# Odoo shell (Python REPL into the live registry)
sudo docker compose --env-file .env run --rm --no-deps -T odoo \
    odoo shell -c /etc/odoo/odoo.conf -d nonprofit --no-http

# Postgres CLI
sudo docker exec -it odoo-postgres psql -U odoo -d nonprofit

# Trigger a manual backup
sudo systemctl start odoo-backup.service
sudo journalctl -u odoo-backup.service -f

# List restic snapshots
sudo bash -c 'export RESTIC_REPOSITORY=/home/deploy/backups/restic-local; \
              export RESTIC_PASSWORD_FILE=/home/deploy/.config/restic/password; \
              restic snapshots --compact'
```

For full restore, see `/home/deploy/scripts/RESTORE.md`.

---

## Phase 3 — OCA modules (INSTALLED 2026-05-04)

### What's installed

108 modules total in `nonprofit` DB (12 from base init + 96 from blueprint installs and their transitive deps). The blueprint's 33 named modules all show `state='installed'`.

### Layout

OCA repos live as subdirectories of `/home/deploy/odoo/odoo/addons/` (NOT a separate `oca/` dir as the original draft proposed) and are exposed inside the container at `/mnt/extra-addons/<repo>/`. The bind mount is unchanged from Phase 1 — the existing `./odoo/addons:/mnt/extra-addons` volume covers everything.

Each repo path is listed explicitly in `odoo.conf` `addons_path` (Odoo doesn't glob).

### Custom image

`odoo-nonprofit-template:18.0-latest` (built from `/home/deploy/odoo/Dockerfile`).

The image extends `odoo:18.0` with:
- OS packages: `build-essential`, `pkg-config`, `libzbar0`, `poppler-utils` (runtime deps for pyzbar + pdf2image, build tools for any wheel without binary)
- All OCA Python deps from each repo's `requirements.txt`, except `mysqlclient` and `pymssql` (filtered out — they're only used by `OCA/server-backend/base_external_dbsource_*` which isn't in the blueprint, and they need build deps that conflict with the postgres apt repo in the base image)

`/home/deploy/odoo/.dockerignore` excludes everything except the `Dockerfile` and `requirements/` so the build context stays small.

To rebuild after changing requirements:
```bash
cd /home/deploy/odoo && sudo docker build -t odoo-nonprofit-template:18.0-latest .
sudo docker compose --env-file .env up -d odoo  # recreate container with new image
```

### OCA repo set (18 repos, pinned to commit SHAs in `/home/deploy/odoo/oca-versions/`)

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

Production deployments should re-fetch each repo at the recorded SHA, not track `18.0` (the branch moves).

### Modules installed by layer

```
Layer 0 (foundation + 2FA):
    partner_firstname, partner_contact_access_link, password_security,
    base_import_match, base_tier_validation, queue_job, auditlog, auth_totp

Layer 1 (accounting core):
    account_reconcile_oca, account_reconcile_model_oca, account_usability,
    account_analytic_required, account_fiscal_year, account_asset_management

Layer 2 (reporting):
    mis_builder, account_financial_report, account_budget_oca,
    report_xlsx, partner_statement

Layer 3 (payments):
    account_payment_partner, account_payment_order,
    account_banking_sepa_credit_transfer

Layer 4 (HR):
    hr_expense_tier_validation, payroll

Layer 5 (procurement):
    purchase_request, purchase_request_tier_validation, purchase_tier_validation

Layer 6 (CRM):
    contract
```

### Blueprint deviations (resolved with user)

| Original blueprint | Issue | Resolved as |
|---|---|---|
| `base_import_match` in OCA/server-tools or OCA/server-ux | Not in either; lives in **OCA/server-backend** | Cloned OCA/server-backend, installed from there |
| `account_move_budget` | Doesn't exist on Odoo 18 | Substituted **`account_budget_oca`** from OCA/account-budgeting |
| `password_security` (no repo named) | Lives in OCA/server-auth, not in blueprint repo list | Added OCA/server-auth |
| `hr_expense_tier_validation` in OCA/purchase-workflow | Lives in OCA/hr-expense, blueprint mis-attributed it | Added OCA/hr-expense |

### 2FA (`auth_totp`)

Installed as part of Layer 0 (it came in as a transitive dep earlier and was confirmed `installed`). **Not yet enabled for any user.**

**Admin must enable on first login:**
1. Log into Odoo at http://89.167.57.60/web/login
2. Settings → Users & Companies → Users → Administrator
3. Click "Enable two-factor authentication"
4. Scan the QR with an authenticator app (Aegis, 2FAS, 1Password, Authy)
5. Enter the 6-digit code to confirm
6. Repeat for every other admin or staff user added later

**Strict force-on-all-users** is not yet configured. To enforce: install `auth_totp_mail_enforce` from OCA/server-auth (already cloned). Defer until org policy is settled.

### Per-repo install commands (for adding more modules later)

```bash
cd /home/deploy/odoo

# 1. Refresh apps list (after pulling new code into a repo)
sudo docker compose --env-file .env run --rm --no-deps odoo \
    odoo -c /etc/odoo/odoo.conf -d nonprofit -u base --stop-after-init

# 2. Install one or more modules
sudo docker compose --env-file .env run --rm --no-deps odoo \
    odoo -c /etc/odoo/odoo.conf -d nonprofit \
    -i module1,module2,module3 --stop-after-init

# 3. Restart workers so the running container picks up the new state
sudo docker compose --env-file .env restart odoo

# 4. Verify in DB
sudo docker exec odoo-postgres psql -U odoo -d nonprofit -c \
    "SELECT name, state FROM ir_module_module WHERE name IN ('module1','module2','module3');"
```

### Per-deployment additions (NOT in template baseline)

- Country-specific localizations beyond `l10n_fr` (already installed)
- Donation modules (NGO-specific — `OCA/donation`)
- Event management (`OCA/event`)
- Membership / association (`OCA/vertical-association`)
- ngo_grants, ngo_cases, ngo_reporting, ngo_advocacy, ngo_volunteers (custom NGO modules, built separately)

---

## Memory and other persistent context

This project also has Claude memory files at `/home/deploy/.claude/projects/-home-deploy/memory/`. Those capture user preferences and cross-session facts; they are LESS authoritative than this CLAUDE.md when there's a conflict. **CLAUDE.md is the single source of truth for project state** — fix it if memory says something different.

## Where to look for more

- `/home/deploy/docs/PRODUCTION-CHECKLIST.md` — what to harden when forking this template for a real nonprofit (71 items, 23 MUST / 33 SHOULD / 15 NICE)
- `/home/deploy/scripts/RESTORE.md` — disaster recovery runbook
- `/home/deploy/scripts/backup-odoo.sh` — the actual backup logic, single source of truth for what's backed up
