# Architecture

HFCC is organized around one PostgreSQL schema, `hfcc`, with a small set of cross-cutting primitives used by every domain area.

## Core Principles

- Runtime codes live in `hfcc.types`; PostgreSQL ENUMs are intentionally avoided.
- JSONB validation rules live in `hfcc.json_schemas`.
- Tables use UUID primary keys and timestamp columns.
- Shared triggers centralize validation, updated timestamps, dispatch, audit, and activity logging.
- RLS policies are enabled across HFCC tables.
- Asynchronous work is modeled transactionally with outbox events and jobs.

## Major Components

| Area | Purpose |
| --- | --- |
| Type registry | Stores namespaced codes, labels, metadata, handler lists, and audit/activity flags. |
| JSON schemas | Declares expected JSONB shape for metadata, payload, and configuration columns. |
| Identity | Mirrors Supabase Auth users into `hfcc.users` and stores app-level profile fields. |
| Media/settings | Provides reusable user media and scoped configuration tables. |
| EDA runtime | Handles outbox, inbox, scheduled jobs, claiming, retries, and handler dispatch. |
| Ledger | Enforces double-entry transactions and user wallet accounts. |
| Subscriptions | Tracks subscription lifecycle, renewals, notices, and entitlements. |
| Promotions | Validates and applies promotion usage and wallet rewards. |
| Commerce | Manages products, orders, order items, payment methods, and payment intents. |
| Messaging | Resolves recipients and dispatches email, SMS, push, in-app, or webhook messages. |
| Logs | Stores activity logs for business events and audit logs for row-level changes. |

## Write Path

Most table writes pass through `hfcc.core_before_write()` before they are stored. This function maintains `updated_at`, validates JSONB columns, and enforces cross-table invariants that cannot be expressed cleanly with simple constraints.

After inserts or updates, `hfcc.core_after_type_dispatch()` can dispatch handlers registered in `hfcc.types.invoke_functions`. For jobs and outbox events, changing a row to a processing status triggers the registered handler chain.

## Event-Driven Runtime

The database stores durable work in:

- `hfcc.jobs` for scheduled or internal background work.
- `hfcc.events_outbox` for integration events and deferred side effects.
- `hfcc.events_inbox` for externally received events.

The `pg_cron` worker calls processing functions that claim due rows. Handler functions are regular SQL/PLpgSQL functions registered through `hfcc.types`, which keeps the runtime extensible without adding bespoke dispatch code for every feature.

## Security Boundary

RLS is enabled on HFCC tables. Browser-facing access should use authenticated Supabase roles and policies. Privileged writes, processing jobs, and sensitive workflow transitions should use trusted server code with `service_role`.
