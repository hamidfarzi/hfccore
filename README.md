# HFCC - Hamid Farzi Central Core

HFCC is a Supabase/PostgreSQL core schema for applications that need identity-linked user data, event-driven workflows, scheduled jobs, a double-entry ledger, subscriptions, promotions, commerce, messaging, activity logs, audit logs, and Row-Level Security in one database layer.

The project is centered on [`HFCC.sql`](HFCC.sql), an idempotent SQL installation script that creates the `hfcc` schema, type registry, tables, functions, triggers, policies, grants, and scheduler entries.

## What Is Included

- Event-driven runtime with outbox, inbox, jobs, handler dispatch, and `pg_cron`.
- Soft enum/type registry through `hfcc.types` instead of PostgreSQL ENUMs.
- JSONB validation metadata through `hfcc.json_schemas`.
- Supabase Auth integration through `auth.users`, `auth.uid()`, and `auth.role()`.
- Double-entry ledger with wallet accounts, grants, and balance enforcement.
- Commerce tables for products, orders, order items, payment methods, and payment intents.
- Subscription, promotion, loyalty, messaging, activity log, and audit log support.
- RLS policies and API grants for Supabase roles.

## Repository Layout

```text
.
|-- HFCC.sql                         # Main PostgreSQL/Supabase installation script
|-- HFCC.md                          # Detailed schema and function reference
|-- README.md                        # Project overview
|-- LICENSE                          # MIT license
|-- docs/
|   |-- ARCHITECTURE.md              # System design and major flows
|   |-- CONTRIBUTING.md              # Contribution workflow
|   |-- CUSTOMIZATION_AUDIT.md       # Project-specific customization audit notes
|   |-- DEVELOPMENT.md               # Developer workflow and extension patterns
|   |-- GETTING_STARTED.md           # Installation and first-run guide
|   |-- RELEASE_CHECKLIST.md         # GitHub/open-source release checklist
|   `-- SECURITY.md                  # Security model and reporting guidance
```

## Quick Start

1. Create or open a Supabase project with PostgreSQL.
2. Enable `pgcrypto` and `pg_cron` support. `HFCC.sql` includes `create extension` statements, but hosted permissions can vary.
3. Apply [`HFCC.sql`](HFCC.sql) through the Supabase SQL editor, a migration tool, or `psql`.
4. Review [`docs/GETTING_STARTED.md`](docs/GETTING_STARTED.md) for setup notes and verification queries.
5. Read [`HFCC.md`](HFCC.md) before adding tables, type codes, handlers, policies, or business workflows.

## Documentation

- [Getting started](docs/GETTING_STARTED.md)
- [Architecture](docs/ARCHITECTURE.md)
- [Development guide](docs/DEVELOPMENT.md)
- [Contributing](docs/CONTRIBUTING.md)
- [Security](docs/SECURITY.md)
- [Open-source release checklist](docs/RELEASE_CHECKLIST.md)

## License

HFCC is released under the MIT License. See [`LICENSE`](LICENSE).
