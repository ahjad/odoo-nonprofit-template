# Odoo 18 Community — Nonprofit template

A reusable, production-leaning template for deploying Odoo 18 Community on a single small VPS for nonprofit / NGO use. Designed to be cloned per organization, then customized.

**Stack:**

- [Odoo 18.0](https://github.com/odoo/odoo) Community Edition (Docker)
- [PostgreSQL 16](https://www.postgresql.org/) (Docker)
- [Caddy 2](https://caddyserver.com/) reverse proxy (HTTP-only by default; one-line switch to HTTPS with auto Let's Encrypt when you add a domain)
- [restic](https://restic.net/) for daily encrypted backups
- 18 [OCA](https://odoo-community.org/) module repos pinned to specific commit SHAs
- 33 OCA modules installed across 7 dependency-ordered layers (foundation, accounting, reporting, payments, HR, procurement, CRM)

**Designed for:** Hetzner CX33-class VPS (2 vCPU / 8 GB / 75 GB SSD) running Ubuntu 24.04 LTS. Will work on any Linux host with Docker.

---

## Quick start

```bash
# 1. Clone
git clone https://github.com/ahjad/odoo-nonprofit-template.git
cd odoo-nonprofit-template

# 2. Bootstrap (generates secrets, clones OCA repos at pinned SHAs, sets ownership)
./bin/init.sh

# 3. Build the custom image (~5-10 min first time)
sudo docker build -t odoo-nonprofit-template:18.0-latest .

# 4. Start the stack
sudo docker compose --env-file .env up -d

# 5. Initialize the 'nonprofit' database (~30 s)
sudo docker compose --env-file .env stop odoo
sudo docker compose --env-file .env run --rm --no-deps odoo \
    odoo -c /etc/odoo/odoo.conf -d nonprofit -i base \
         --without-demo=all --stop-after-init --load-language=en_US
sudo docker compose --env-file .env start odoo

# 6. Open http://YOUR_SERVER_IP/web/login — login: admin / admin
#    CHANGE THE PASSWORD IMMEDIATELY.
```

Then install the OCA module layers — see [docs/CLAUDE.md](docs/CLAUDE.md) section "Modules installed by layer" for the canonical install order.

---

## What's in the box

```
.
├── README.md                         # this file
├── CLAUDE.md                         # canonical project context (loaded by Claude Code)
├── Dockerfile                        # custom image extending odoo:18.0 with OCA Python deps
├── docker-compose.yml                # 3-service stack on internal bridge network
├── caddy/Caddyfile                   # HTTP-only :80, websocket route on /websocket*
├── .env.template                     # POSTGRES_PASSWORD + ODOO_ADMIN_PASSWD placeholders
├── odoo/
│   ├── config/odoo.conf.template     # Odoo runtime config with secret placeholders
│   └── addons/.gitkeep               # OCA repos cloned here per deployment
├── oca-versions/*.sha                # 18 pinned commit SHAs for reproducibility
├── requirements/*.txt                # 18 per-OCA-repo Python requirements
├── bin/init.sh                       # bootstrap script (run once after clone)
└── docs/
    ├── CLAUDE.md → ../CLAUDE.md      # symlink, single source of truth
    ├── PRODUCTION-CHECKLIST.md       # 71 items to harden when going live (23 MUST)
    ├── RESTORE.md                    # disaster recovery runbook
    └── SESSION-LOG-2026-05-04.md     # full record of how this template was built
```

---

## Pre-installed OCA module baseline (33 modules across 7 layers)

| Layer | Purpose | Modules |
|---|---|---|
| 0 | Foundation + 2FA | `partner_firstname`, `partner_contact_access_link`, `password_security`, `base_import_match`, `base_tier_validation`, `queue_job`, `auditlog`, `auth_totp` |
| 1 | Accounting core | `account_reconcile_oca`, `account_reconcile_model_oca`, `account_usability`, `account_analytic_required`, `account_fiscal_year`, `account_asset_management` |
| 2 | Reporting | `mis_builder`, `account_financial_report`, `account_budget_oca`, `report_xlsx`, `partner_statement` |
| 3 | Payments | `account_payment_partner`, `account_payment_order`, `account_banking_sepa_credit_transfer` |
| 4 | HR | `hr_expense_tier_validation`, `payroll` |
| 5 | Procurement | `purchase_request`, `purchase_request_tier_validation`, `purchase_tier_validation` |
| 6 | CRM | `contract` |

Each OCA repo is pinned to a specific commit SHA (see `oca-versions/*.sha`). `bin/init.sh` re-clones at exactly those SHAs so any clone of this template builds identical addons.

---

## Per-deployment additions (NOT in template baseline)

These are **deliberately excluded** from the template — each NGO adds what it needs:

- Country-specific localizations beyond `l10n_fr` (already installed)
- Donation modules — depends on NGO type (try `OCA/donation`)
- Event management — try `OCA/event`
- Membership / association — try `OCA/vertical-association`
- Custom org modules (grants, cases, volunteer management, etc.)

---

## Documentation

| File | Purpose |
|---|---|
| [docs/CLAUDE.md](docs/CLAUDE.md) | Canonical project context — stack layout, conventions, gotchas, operational commands |
| [docs/PRODUCTION-CHECKLIST.md](docs/PRODUCTION-CHECKLIST.md) | 71-item hardening checklist (23 MUST / 33 SHOULD / 15 NICE) for going live |
| [docs/RESTORE.md](docs/RESTORE.md) | Disaster recovery runbook for restic backups |
| [docs/SESSION-LOG-2026-05-04.md](docs/SESSION-LOG-2026-05-04.md) | Full record of how this template was built — every phase, decision, file, and gotcha |

---

## Critical operational gotchas

These bit us during the original build; they're documented in CLAUDE.md but worth flagging up-front:

1. **Odoo container user is uid 100, gid 101** — NOT 101 as the official docs imply. Bind mounts under `odoo/` must be chowned to `100:101`. `bin/init.sh` handles this.
2. **`POSTGRES_USER=odoo` makes `odoo` a Postgres superuser.** Every `pg_dump` / `psql` / `pg_restore` call must use `-U odoo`. (For real production, split into a non-superuser runtime user — see PRODUCTION-CHECKLIST.md §7.)
3. **`list_db=False` blocks the web database manager**, including `/web/database/create`. Initialize databases via the Odoo CLI, not the web API.
4. **Docker bypasses UFW.** Postgres is bound to `127.0.0.1:5432` for that reason. Only Caddy publishes to `0.0.0.0`. Never publish a new container port on `0.0.0.0` without thinking.

---

## Status

This template is the output of a focused build session (2026-05-03 → 2026-05-04). Phases 0 (host hardening), 1 (Odoo stack), 2 (backups), and 3 (OCA module install) are complete. The full session log is in [docs/SESSION-LOG-2026-05-04.md](docs/SESSION-LOG-2026-05-04.md).

**Not in the template** but explicitly recommended before going live (see PRODUCTION-CHECKLIST.md):

- Off-site backup destination
- Real domain + TLS (Caddyfile change is one line)
- Container resource limits in compose
- Postgres runtime user split (non-superuser)
- 2FA enforcement (the module is installed; enabling it is a per-user step)

---

## License

The template scaffolding (Dockerfile, compose, Caddyfile, init script, docs) is offered as-is for nonprofit and commercial use. Each OCA module retains its own license (typically AGPL-3.0 or LGPL-3.0); see the individual repo `LICENSE` files after running `bin/init.sh`. Odoo Community Edition itself is [LGPL-3.0](https://github.com/odoo/odoo/blob/18.0/LICENSE).
