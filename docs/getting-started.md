# Getting Started

This guide explains how to install HFCC in a Supabase/PostgreSQL project and run the first verification checks.

## Requirements

- Supabase project or PostgreSQL database compatible with Supabase Auth conventions.
- Permission to create the `hfcc` and `extensions` schemas.
- Permission to enable `pgcrypto`.
- Permission to enable `pg_cron` if scheduled job processing should run inside the database.
- A deployment path for SQL, such as Supabase SQL editor, Supabase migrations, `psql`, or a migration runner.

HFCC references Supabase-managed objects such as `auth.users`, `auth.uid()`, and `auth.role()`. It is intended for Supabase-style deployments, not a plain PostgreSQL database without compatible auth helpers.

## Install

Apply the root [`HFCC.sql`](../HFCC.sql) file to the database:

```sql
-- In Supabase SQL editor, paste and run HFCC.sql.
```

Or with `psql`:

```bash
psql "$DATABASE_URL" -f HFCC.sql
```

The script is written with `create ... if not exists` and `create or replace function` patterns where practical. Review changes carefully before running it against an existing production database.

## Verify

Run these checks after installation:

```sql
select schema_name
from information_schema.schemata
where schema_name = 'hfcc';

select count(*) as type_count
from hfcc.types;

select table_name
from information_schema.tables
where table_schema = 'hfcc'
order by table_name;
```

If `pg_cron` is available, verify the scheduled HFCC worker:

```sql
select jobname, schedule, command
from cron.job
where jobname = 'hfcc_process_due_work';
```

## First Integration Steps

1. Read [`../HFCC.md`](../HFCC.md) for the full schema and function reference.
2. Use `hfcc.types` for every new status, category, channel, event, or job code.
3. Add JSONB validation metadata to `hfcc.json_schemas` when introducing JSONB payloads.
4. Keep application writes behind RLS-aware APIs or trusted `service_role` workflows.
5. Never store raw card data, secrets, service role keys, or provider credentials in HFCC tables.

## Hosted Supabase Notes

Hosted Supabase can restrict ownership operations on `auth.users`. HFCC avoids replacing the auth trigger when it already exists. If trigger creation fails, inspect permissions and create the auth trigger with an owner role that can modify auth metadata.
