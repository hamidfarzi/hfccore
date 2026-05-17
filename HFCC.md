# HFCC — Hamid Farzi Central Core

> Authoritative developer reference for `HFCC.sql` (7,436 lines).
> Read this before generating code that touches the `hfcc` schema, designing API
> endpoints around it, or integrating new business logic.

HFCC is a self-contained, **EDA-ready** (Event-Driven Architecture) PostgreSQL/Supabase
schema that bundles four cores into one transactional, audit-friendly platform:

1. **EDA Core** — type registry, JSON schema validation, outbox/inbox, jobs, pg_cron.
2. **Ledger Core** — strict double-entry ledger with multi-currency wallets.
3. **Commerce Core** — products, orders, items, payment methods, payment intents.
4. **Promotion & Loyalty Core** — promotions, usage tracking, subscription lifecycle,
   wallet grants, entitlements.

It is designed to run on Supabase: it relies on `auth.users`, `auth.uid()`,
`auth.role()`, the `service_role` API key, **Row-Level Security**, and the
`pg_cron` and `pgcrypto` extensions.

---

## Table of contents

1. [High-level architecture](#1-high-level-architecture)
2. [Universal conventions](#2-universal-conventions)
3. [Type registry & JSON schemas](#3-type-registry--json-schemas)
4. [Identity, media, settings](#4-identity-media-settings)
5. [EDA: outbox, inbox, jobs](#5-eda-outbox-inbox-jobs)
6. [Ledger Core](#6-ledger-core)
7. [Subscriptions & wallet grants](#7-subscriptions--wallet-grants)
8. [Promotion & Loyalty Core](#8-promotion--loyalty-core)
9. [Commerce Core](#9-commerce-core)
10. [Devices & outgoing messages](#10-devices--outgoing-messages)
11. [Activity & audit logs](#11-activity--audit-logs)
12. [Universal triggers](#12-universal-triggers)
13. [Row-Level Security & grants](#13-row-level-security--grants)
14. [pg_cron schedule](#14-pg_cron-schedule)
15. [End-to-end workflows](#15-end-to-end-workflows)
16. [Function catalog](#16-function-catalog)
17. [Trigger catalog](#17-trigger-catalog)
18. [Integration playbook for AI agents](#18-integration-playbook-for-ai-agents)

---

## 1. High-level architecture

```
                ┌────────────────────────────────────────────────┐
                │                   hfcc.types                   │
                │ scoped, namespaced code registry + handler map │
                └──────────────┬─────────────────────────────────┘
                               │ FK + CHECK on every *_code column
                               ▼
 ┌─────────────────────────────────────────────────────────────────────────┐
 │                            EVERY TABLE                                  │
 │  BEFORE INSERT/UPDATE  →  hfcc.core_before_write()                      │
 │      • bumps updated_at                                                 │
 │      • validates JSONB columns against hfcc.json_schemas                │
 │      • enforces cross-table invariants (ownership, currency, …)         │
 │  AFTER  INSERT/UPDATE  →  hfcc.core_after_type_dispatch()               │
 │      • for jobs/events_outbox/events_inbox: runs registered handlers    │
 │      • for any other table: dispatches per-field type handlers          │
 │  AFTER  INSERT/UPDATE/DELETE on auditable tables → audit_row_change()   │
 └─────────────────────────────────────────────────────────────────────────┘
                               │
            ┌──────────────────┼──────────────────┐
            ▼                  ▼                  ▼
    ┌──────────────┐   ┌──────────────┐   ┌──────────────┐
    │   Ledger     │   │   Commerce   │   │ Promotions   │
    │   Core       │◄─►│    Core      │◄─►│ & Loyalty    │
    └──────────────┘   └──────────────┘   └──────────────┘
                               │
                               ▼
                  ┌────────────────────────┐
                  │  Subscriptions / Jobs  │
                  │  events_outbox / inbox │
                  └────────────────────────┘
                               │
                pg_cron `10 seconds` →  hfcc.process_due_jobs()
                                   →  hfcc.process_due_events_outbox()
```

Three cross-cutting design choices make the system developer-friendly:

* **No native PostgreSQL ENUMs.** Every coded column is `text` with an FK to
  `hfcc.types` plus a `CHECK` ensuring `code` lives under
  `schema.entity.field.…`. Most coded columns are named `*_code` (e.g.
  `status_code`, `event_code`, `channel_code`); a handful are not, the
  notable example being `hfcc.settings.scope_type`. Treat
  "any column whose value is validated against `hfcc.types`" as the rule —
  don't assume the suffix alone. Adding a new status is a single row insert,
  no migration.
* **Single before-write / after-write trigger pair installed on every table.**
  All JSON validation, audit logging, type-dispatch and side-effects flow
  through these two functions, so business rules do not get scattered across
  random per-table triggers.
* **Outbox + jobs + pg_cron** form a fully transactional async runtime that
  needs nothing outside the database.

---

## 2. Universal conventions

### 2.1 Schemas and extensions

| Schema       | Purpose                                                  |
|--------------|----------------------------------------------------------|
| `hfcc`       | All application objects.                                 |
| `extensions` | Hosts `pgcrypto` (and any future extensions).            |
| `auth`       | Supabase-managed user table (referenced, not modified).  |
| `cron`       | Created by `pg_cron`; one job is scheduled here.         |

### 2.2 Naming & primary keys

* Primary keys are `uuid` defaulting to `extensions.gen_random_uuid()`.
* All tables have `created_at timestamptz not null default now()`.
* All mutable tables also have `updated_at`, automatically maintained by
  `hfcc.core_before_write`.
* Money columns are `numeric(19,4)` and always paired with a `currency_code`
  column. Non-ledger tables intentionally **do not FK** to `ledger_currencies`;
  they store the code as plain text so they can carry historical/foreign
  currencies without coupling.
* JSON-shaped columns use `jsonb`, never `json`.
* Most code-typed columns end in `_code` (e.g. `status_code`, `event_code`,
  `channel_code`) and are validated against `hfcc.types` via
  `(code, schema, entity, field)` foreign keys plus a per-column scope
  `CHECK`. A few use shorter names (notably `hfcc.settings.scope_type`); the
  reliable signal is the FK to `hfcc.types`, not the column suffix.

### 2.3 Code namespacing

Every type code follows
`schema.entity.field.value` (≥ 4 dot-separated segments), e.g.
`hfcc.subscriptions.status_code.active`. Two CHECK constraints on
`hfcc.types` enforce the shape:

* `types_code_namespaced_check` — requires at least four lowercase,
  underscore-friendly segments separated by dots.
* `types_code_scoped_name_check` — requires the code to start with the row's
  own `schema.entity.field.` prefix, so the registry cannot drift away from
  the column it describes.

**AI agents must never hand-craft short codes**; always use the full
namespaced string.

### 2.4 Soft enum + handler dispatch

Each row in `hfcc.types` has:

* `invoke_functions jsonb` — ordered list of `handle_*` function names. When
  a row's `*_code` column changes (or the row is inserted), the after-write
  trigger runs every listed handler with the row context.
* `log_audit boolean` / `log_activity boolean` — when true, the dispatcher
  inserts an `audit_logs` / `activity_logs` row automatically.
* `metadata jsonb` — free-form (templates, copy, validation rules, etc.).

This means a backend developer can add a new event/status without writing
PL/pgSQL: insert a `types` row with `invoke_functions = '["handle_my_thing"]'`
and create the matching `hfcc.handle_my_thing(p_payload jsonb)` function.

---

## 3. Type registry & JSON schemas

### 3.1 `hfcc.types`

Central registry for every code-typed value used anywhere in HFCC.

| Column              | Notes                                              |
|---------------------|----------------------------------------------------|
| `code` (PK)         | Full `schema.entity.field.value` path.             |
| `schema`/`entity`/`field` | Indices used by FK targets.                  |
| `label`/`description` | UI strings.                                      |
| `invoke_functions`  | Ordered jsonb array of `handle_*` function names or objects `{function_name, payload_key, payload}`. |
| `log_audit`/`log_activity` | Auto-write to audit/activity_logs.          |
| `metadata`          | Free-form jsonb (templates, business config).      |
| `is_active`         | RLS hides inactive rows from anon/auth.            |
| `sort_order`        | Used for menus.                                    |

Helpers:

* `hfcc.is_valid_type(p_code, p_entity, p_field)` — returns true if the row is
  active and matches the given scope.
* Scoped FKs are added per *_code column with a CHECK constraint such as
  `check (status_code like 'hfcc.subscriptions.status_code.%')`.

### 3.2 `hfcc.json_schemas`

Registry of validation schemas applied to JSONB columns. Lookup key:
`(entity, field, version)`. The latest active row per `(entity, field)` is used
by `hfcc.core_before_write` to validate inserts/updates.

The validator implements a deliberately small subset of JSON Schema:

* root `type` (`object`, `array`, `number`, `boolean`, `string`, `integer`).
* `required` array.
* `properties.<name>.type`.

It is fast, predictable, and sufficient for catching shape errors at write
time.

---

## 4. Identity, media, settings

### 4.1 `hfcc.users`

Mirror of `auth.users` (PK is the same uuid). Holds app-level fields:
`role_code`, `display_name`, `avatar_media_id`, `phone_number`, `locale_code`,
`timezone`, `metadata`.

* The trigger function `hfcc.handle_new_auth_user()` inserts a matching
  `hfcc.users` row whenever a Supabase auth user is created (you must wire it
  to `auth.users` in your Supabase project — the migration only ships the
  function).
* `core_before_write` blocks non-service-role updates of `role_code`, and
  blocks setting `avatar_media_id` to media that the user does not own.

### 4.2 `hfcc.media` & `hfcc.media_relations`

* `media` — generic asset table with polymorphic `owner_type` /`owner_id`
  (`owner_type` is itself a coded value, e.g. `hfcc.media.owner_type.user`).
* `media_relations` — many-to-many "media is attached to entity X" with
  `relation_type_code` and ordering.

Use this for avatars, product imagery, message attachments, etc.

### 4.3 `hfcc.settings`

`(scope_type_code, scope_id, key)`-keyed bag of values. Use for per-user
preferences, per-tenant config, app-level feature flags.
Authenticated users have full CRUD on their own scope rows.

---

## 5. EDA: outbox, inbox, jobs

### 5.1 Tables

| Table             | Purpose                                                |
|-------------------|--------------------------------------------------------|
| `events_outbox`   | Domain events emitted by the DB, awaiting dispatch.    |
| `events_inbox`    | External events ingested from upstream systems.        |
| `jobs`            | Internal scheduled work (`run_at`, `attempt_count`, `max_attempts`). |

All three tables use the standard pattern: `event_code` / `job_code` typed
against `hfcc.types`, `status_code` (`pending` → `processing` → `done` /
`failed`), `payload jsonb`, `attempt_count`, `max_attempts`, `locked_at`,
`processed_at`, `error_message`.

### 5.2 Lifecycle & generic dispatch

The runtime is split between two layers:

1. **Claim helpers** — `hfcc.claim_due_jobs(limit)`,
   `hfcc.claim_due_events_outbox(limit)` atomically flip rows from `pending`
   to `processing`, returning the claimed rows. Runs are **safe for
   concurrent workers** (`for update skip locked`).
2. **Generic dispatcher** — when a row enters `processing`,
   `hfcc.core_after_type_dispatch` reads the matching `hfcc.types` row
   and invokes every `handle_*` function listed in `invoke_functions`. On
   success the row flips to `done`; on failure it is bounced to `pending`
   (or `failed` once `attempt_count >= max_attempts`).

Convenience wrappers:

* `hfcc.process_due_jobs(limit)` and `hfcc.process_due_events_outbox(limit)`
  call the claim helpers and let the dispatcher do the work.
* `hfcc.retry_stuck_jobs(interval)` /
  `hfcc.retry_stuck_events_outbox(interval)` reset rows that have been stuck
  in `processing` longer than the interval.

Producers:

* `hfcc.enqueue_outbox_event(event_code, source_type, source_id, payload,
  metadata, run_at)` — service-role function that inserts a new outbox row.
* Tables can also schedule jobs directly: `hfcc.schedule_subscription_lifecycle_jobs`
  is an example that inserts rows into `hfcc.jobs`.

### 5.3 Built-in job handlers

Defined for the subscription lifecycle:

* `handle_job_subscription_maintenance_daily`
* `handle_job_subscription_expire`
* `handle_job_subscription_activate`
* `handle_job_subscription_renewal_notice`

Add more by creating any `hfcc.handle_<name>(p_payload jsonb)` function and
registering it in the `invoke_functions` array of the relevant `hfcc.types`
row.

---

## 6. Ledger Core

A double-entry ledger keyed on multi-currency accounts. **All ledger writes go
through `create_ledger_transaction`** — direct inserts into `ledger_entries` are
discouraged because the deferred constraint triggers will reject anything
unbalanced at COMMIT time.

### 6.1 Tables

| Table                  | Purpose                                                      |
|------------------------|--------------------------------------------------------------|
| `ledger_currencies`    | Currency master (`code`, `precision`, `is_fiat`, `is_active`). Seeds: `USD`, `POINTS`, `CREDIT`, `TOKEN`, `TIER`. |
| `ledger_accounts`      | One row per `(scope_type_code, scope_id, currency_code, account_type_code)`. `scope_type_code` includes `system` and `user`. |
| `ledger_transactions`  | Header row: `transaction_type_code`, `currency_code`, `metadata`, `source_type`, `source_id`. |
| `ledger_entries`       | `(transaction_id, account_id, direction_code, amount)` — amounts are positive; direction is `debit`/`credit`. |
| `ledger_balances`      | `security_invoker` view summing entries per account.         |

### 6.2 Invariants

* **Per-currency balance trigger.** `validate_ledger_entries_balance_trigger` /
  `validate_ledger_transaction_balance_trigger` are deferred constraint triggers
  ensuring `Σ debits == Σ credits` per currency within every transaction. They
  are `SECURITY DEFINER` so deferred validation still runs under the HFCC owner
  when a browser-facing RPC posts ledger entries through a trusted HFCC helper.
* **System scope must balance.** `assert_non_system_balances_allowed` requires
  that every transaction either debits or credits at least one `system`
  account, so user balances cannot be created out of thin air.
* **No history rewrites.** Once written, ledger rows are immutable from the
  client perspective (RLS allows SELECT only).

### 6.3 Helpers

* `hfcc.ensure_hfcc_user(user_id)` — idempotent insert into `hfcc.users`.
  Use before `ensure_user_ledger_accounts` when the caller may be a pre-HFCC
  user (created before the `on_auth_user_created` trigger was installed).
* `hfcc.ensure_user_ledger_accounts(user_id)` — idempotently provisions the
  per-currency wallet accounts for a user.
* `hfcc.create_ledger_transaction(transaction_type_code, user_id,
  entries jsonb, currency_code, metadata)` — inserts the transaction and the
  paired entries; balance is enforced at commit.
* `hfcc.spend_user_balance(user_id, currency_code, amount, source_type,
  source_id, transaction_type_code, metadata)` — high-level wallet debit used
  by the rest of the system; refuses to spend more than the available
  balance.

---

## 7. Subscriptions & wallet grants

### 7.1 `hfcc.subscriptions`

One row per logical subscription. Key columns:

* `user_id`, `plan_product_id`, `status_code`, `interval_code`,
  `current_period_start`, `current_period_end`,
  `next_renewal_at`, `cancelled_at`, `payment_method_id`, `metadata`.
* `is_immutable boolean` — once a paid period has been delivered, the row is
  frozen. `prevent_immutable_subscription_update` blocks unauthorized changes
  to historical rows.

### 7.2 `hfcc.ledger_wallet_grants`

A wallet grant says "this subscription/order entitles user X to Y of currency
Z, awarded across N periods". Key fields: `subscription_id`, `user_id`,
`currency_code`, `amount`, `granted_at`, `expires_at`, `status_code`,
`source_type`, `source_id`.

Grants are created by:

* `apply_subscription_entitlements(subscription_id, order_id, granted_at,
  is_renewal)` — runs after a paid order, mints credits in the appropriate
  ledger accounts, and writes the grant row.
* Commerce one-shot purchases via `apply_commerce_order_item_entitlements`.

### 7.3 Lifecycle functions

| Function                                        | Role                                                 |
|-------------------------------------------------|------------------------------------------------------|
| `subscription_interval(interval_code)`          | Translates `monthly`, `yearly`, `weekly`, etc., into a PG `interval`. |
| `schedule_subscription_lifecycle_jobs`          | Schedules `expire`, `activate`, `renewal_notice` jobs in `hfcc.jobs`. |
| `activate_scheduled_subscription`               | Flips a `scheduled` subscription to `active`, mints entitlements. |
| `enqueue_subscription_renewal_notice`           | Emits an outbox notice ahead of renewal.            |
| `create_subscription_from_order`                | Creates a fresh subscription on a paid initial order.|
| `create_subscription_renewal_order`             | Drafts the next billing-period order before renewal. |
| `apply_subscription_renewal_order`              | Marks renewal paid, advances the period, mints grants. |
| `apply_subscription_entitlements`               | Generic helper used by initial + renewal flows.     |
| `process_subscription_maintenance`              | Per-user, idempotent sweep that catches up missed lifecycle steps; called daily by the job handler. |
| `after_subscription_activation`                 | Trigger fired after a subscription becomes paid+active that schedules lifecycle jobs. |

### 7.4 Subscription state machine

```
draft ─► scheduled ─► active ─► past_due ─► cancelled
                          │           │
                          └────► expired
```

State transitions are driven by jobs (`expire`, `activate`,
`renewal_notice`) plus ad-hoc service-role updates. Always go through the
helpers — manual `UPDATE` statements break audit logs and lifecycle jobs.

---

## 8. Promotion & Loyalty Core

### 8.1 Tables

* `hfcc.promotions` — promo definitions: `code`, `name`,
  `promotion_type_code` (`coupon`, `referral`, `promo`, `loyalty`, `reward`),
  `value_amount`, `currency_code`, `starts_at`, `ends_at`,
  `usage_limit_global`, `usage_limit_per_user`, `usage_count`,
  `is_active`, `metadata`, `rules`.
* `hfcc.promotion_usages` — one row per accepted use, with polymorphic
  `context_type` / `context_id` (typically a commerce order) for idempotency,
  plus `source_type` / `source_id`; reward flows use `hfcc.promotion_usages.source_type.reward`.

### 8.2 Lifecycle & helpers

* `validate_promotion_for_user(user_id, promotion_code, context_type,
  context_id, source_id)` — read-only check used by clients before
  attempting redemption; returns a structured jsonb result.
* `validate_promotion_usage()` — BEFORE INSERT trigger on `promotion_usages`
  enforcing limits, time windows, and `validate_promotion_for_user` rules.
* `after_promotion_usage_insert()` — increments `promotions.usage_count`.
* `apply_promotion(user_id, promotion_code, context_type, context_id,
  source_type, source_id, actor_user_id)` — atomic helper that validates the
  promo, inserts the usage row, applies discounts/credits, and emits an audit
  trail.

Promotion redemption is **transactional and idempotent**: pass the same
`(context_type, context_id)` twice and the second call is a no-op (the unique
index on usages enforces this).

---

## 9. Commerce Core

### 9.1 Tables

| Table                        | Purpose                                                 |
|------------------------------|---------------------------------------------------------|
| `commerce_products`          | Catalog rows. `product_type_code` distinguishes e.g. one-time vs subscription plan; `attributes jsonb` carries UI display, categorization, and subscription flags; `entitlements jsonb` describes wallet grants; `rules jsonb` carries cart and pricing rules; `payload jsonb` is app-specific. |
| `commerce_orders`            | Order header. `order_type_code` (`one_time`, `subscription_initial`, `subscription_renewal`), `status_code`, `payment_status_code`, `parent_order_id`, all `*_amount` columns, `currency_code`. |
| `commerce_order_items`       | Order line. References `product_id`; carries snapshots of `rules`, `entitlements`, and `payload` so historical orders are immune to product edits. May reference `subscription_id` for renewal items. |
| `commerce_payment_methods`   | Tokenized payment instruments (provider + provider token). Raw card data **must not** be stored. |
| `commerce_payment_intents`   | Per-attempt provider call: `provider_code`, `status_code`, `amount`, `provider_payment_intent_id`, request/response payloads, errors. |

### 9.2 Order lifecycle

```
draft ─► confirmed ─► fulfilling ─► fulfilled
              │
              └────► cancelled / failed / refunded
```

Triggers do most of the heavy lifting:

* `after_commerce_order_confirmed` — when an order moves to `confirmed`,
  calls `process_commerce_order` which:
  1. Validates each item against the snapshotted product rules.
  2. Calls `apply_commerce_order_item_entitlements` for paid items.
  3. Creates a subscription via `create_subscription_from_order` for
     subscription orders.
  4. Emits an outbox event for downstream services.
* `after_commerce_order_item_status_change` — recomputes the parent order's
  `status_code` via `recalculate_commerce_order_status_from_items`.
* `after_commerce_order_item_totals_change` — recalculates
  `subtotal/discount/tax/shipping/total` via
  `recalculate_commerce_order_totals`.
* `after_commerce_payment_intent_status_change` — recomputes
  `commerce_orders.payment_status_code` via
  `recalculate_commerce_order_payment_status`. (`paid` if any intent
  succeeded for `>= total`, `partial` if some, `failed` if all failed,
  `pending` otherwise.)

### 9.3 Cross-table invariants enforced in `core_before_write`

* `commerce_order_items.currency_code` must match the parent order's
  `currency_code`.
* `subscriptions.payment_method_id` must belong to the subscription user.
* `commerce_order_items.subscription_id`, when set, must reference a
  subscription owned by the order user.

---

## 10. Devices & outgoing messages

### 10.1 `hfcc.devices`

Per-user device registrations: `platform_code`, `push_provider_code`,
`push_token`, `device_name`, `app_version`, `last_seen_at`. Owners can fully
manage their own rows.

### 10.2 `hfcc.outgoing_messages`

A single queue for every outbound notification (email, SMS, push, webhook).
Columns include `channel_code`, `recipient`, `template_code`, `subject`,
`body`, `payload`, `provider_code`, `status_code`,
`provider_message_id`, `source_type`, `source_id`, `send_after`, `read_at`,
`sent_at`, `error_message`, and `metadata`.

The trigger `enqueue_outgoing_message_outbox` runs after insert when the
message status is `pending`: it produces an `events_outbox` event of code
`hfcc.events_outbox.event_code.message.send_requested` with the message id and
uses `send_after` as the outbox `run_after`. The registered handler marks
in-app messages sent inside the database and leaves external providers, such
as Firebase, to Edge Function/webhook senders that update the message to
`sent` or `failed`.

Unread escalation is modeled as message payload metadata:
`payload.escalation.steps[]` can list ordered channel/provider steps with
`delay_seconds`. The in-app send handler schedules
`hfcc.events_outbox.event_code.message.escalation_due`; that handler stops if
`read_at` is set, otherwise it creates the next outgoing message channel.

---

## 11. Activity & audit logs

* `hfcc.activity_logs` — human-meaningful actions: `actor_user_id`,
  `action_code`, polymorphic `target_type`/`target_id`, `description`,
  `metadata`.
* `hfcc.audit_logs` — row-level diffs: `actor_user_id`, `action_code`,
  `entity` (table name), `entity_id`, `old_data`, `new_data`,
  `ip_address`, `user_agent`, `metadata`.

The function `hfcc.audit_row_change()` is generic; the helper
`hfcc.install_audit_trigger(p_table regclass)` attaches it to a target table.
The migration installs it on:

`users`, `subscriptions`, `ledger_wallet_grants`, `promotions`,
`promotion_usages`, `commerce_products`, `commerce_orders`,
`commerce_order_items`, `commerce_payment_methods`,
`commerce_payment_intents`, `outgoing_messages`, `ledger_transactions`.

In addition, the after-write dispatcher will write an `activity_logs` row
whenever the matching `hfcc.types.log_activity` is true, so business analysts
can declaratively turn on activity tracking for any coded transition.

---

## 12. Universal triggers

Two functions are installed on every table that participates in the type
system:

### 12.1 `hfcc.core_before_write()` — BEFORE INSERT/UPDATE

* Bumps `updated_at`.
* Validates every JSONB column that has a matching active `hfcc.json_schemas`
  row (root type, `required`, and `properties.*.type`).
* Hard-coded cross-table invariants:
  * `users.role_code` is service-role only.
  * `users.avatar_media_id` must reference media owned by the same user.
  * `subscriptions.payment_method_id` must belong to the subscription's user.
  * `commerce_order_items` currency must equal the parent order's currency.
* Aggregates errors and raises a single `check_violation` (`23514`) with a
  jsonb payload, so callers get one structured error instead of N partial
  ones.

### 12.2 `hfcc.core_after_type_dispatch()` — AFTER INSERT/UPDATE

* For `jobs`, `events_outbox`, `events_inbox` rows entering `processing`,
  invokes the registered handler chain via `hfcc.invoke_type_handler` and
  then transitions the row to `done` / `failed` / back to `pending`.
* For every other table, walks the row's columns and, for any `*_code` column
  whose new value resolves to a `hfcc.types` row with handlers, audit, or
  activity flags, calls `hfcc.invoke_type_handler` so handlers can react to
  the transition.

### 12.3 Other notable triggers

* Ledger: `ledger_entries_balance_check`,
  `ledger_transactions_balance_check` (deferred, ensure double-entry
  balance).
* Subscriptions: `prevent_immutable_subscription_update`,
  `after_subscription_activation`.
* Promotions: `validate_promotion_usage`, `after_promotion_usage_insert`.
* Commerce: `after_commerce_order_confirmed`,
  `after_commerce_order_item_status_change`,
  `after_commerce_order_item_totals_change`,
  `after_commerce_payment_intent_status_change`.
* Messaging: `enqueue_outgoing_message_outbox`.
* Auditing: `audit_row_change` on the 12 tables listed above.

---

## 13. Row-Level Security & grants

RLS is enabled on **every** HFCC table. The patterns are:

| Audience          | Default access                                                |
|-------------------|---------------------------------------------------------------|
| `service_role`    | Full access on all tables and execute on all functions.       |
| `authenticated`   | SELECT on most tables they own (`auth.uid() = user_id`); CRUD on `devices`, `settings`, `commerce_payment_methods`. |
| `anon`            | SELECT on public registries: `types`, `json_schemas`, `ledger_currencies`, `promotions`, `commerce_products`, `settings`. |
| Public            | None (everything else is denied by default).                  |

Sensitive functions (`enqueue_outbox_event`, all `process_*` and `apply_*`
helpers, `claim_due_*`, etc.) are explicitly `revoke`d from public/anon/auth
and `grant`ed only to `service_role`. The only end-user-callable function is
`hfcc.validate_promotion_for_user`, which is read-only.

**RLS is the authorization boundary.** Application servers should connect with
`service_role` for write paths and rely on the per-user JWT for read paths.

---

## 14. pg_cron schedule

A single cron entry is installed:

```text
jobname:  core-process-due-jobs
schedule: 10 seconds
command:  select jsonb_build_object(
            'jobs',   hfcc.process_due_jobs(25),
            'outbox', hfcc.process_due_events_outbox(50)
          );
```

Tune the batch size (`25` / `50`) for higher throughput. There is no separate cron
entry for `events_inbox` — inbox rows are processed by the after-write
dispatcher when they enter `processing`, so dispatch is implicit on insert.

---

## 15. End-to-end workflows

### 15.1 New auth user onboarding

1. Supabase creates a row in `auth.users`.
2. (You wire this) `auth.users` AFTER INSERT trigger calls
   `hfcc.handle_new_auth_user()`.
3. The function inserts `hfcc.users` and provisions ledger accounts via
   `ensure_user_ledger_accounts`.
4. Activity log entry is written through the type registry (when configured).

### 15.2 One-time purchase

1. Client builds a `commerce_orders` row in status `draft` with
   `commerce_order_items`.
2. `core_before_write` validates JSON (e.g. `billing_info`) and currency
   coherence between order and items.
3. Client (service role) updates the order to `confirmed` after collecting
   payment via `commerce_payment_intents`.
4. `after_commerce_payment_intent_status_change` recomputes
   `payment_status_code`.
5. `after_commerce_order_confirmed` calls `process_commerce_order`, which:
   * Marks each item `fulfilled` and snapshots entitlements.
   * Calls `apply_commerce_order_item_entitlements`, creating a
     `ledger_wallet_grants` row and a balanced `ledger_transactions` so the
     buyer's wallet is credited.
   * Emits a `commerce.order.fulfilled` outbox event.

### 15.3 Subscription initial purchase

Same as 15.2 up to `after_commerce_order_confirmed`. Then:

1. `process_commerce_order` notices `order_type_code =
   subscription_initial`.
2. `create_subscription_from_order` inserts a `hfcc.subscriptions` row
   (`status_code = active`), pinned to the buyer's payment method.
3. `after_subscription_activation` fires →
   `schedule_subscription_lifecycle_jobs` inserts:
   * a `subscription_expire` job at `current_period_end`,
   * a `subscription_renewal_notice` job N days before renewal,
   * a `subscription_maintenance_daily` job (recurring per `process_subscription_maintenance`).
4. `apply_subscription_entitlements` mints the first period's wallet grants.

### 15.4 Subscription renewal

1. pg_cron invokes `process_due_jobs`. The renewal-related job picks up
   `process_subscription_maintenance` for the user.
2. The maintenance function calls `create_subscription_renewal_order` which
   creates a `commerce_orders` row of type `subscription_renewal` referencing
   the subscription.
3. Payment is collected exactly as in 15.2; once the order is `confirmed`
   and paid, `apply_subscription_renewal_order` advances
   `subscriptions.current_period_*`, resets `next_renewal_at`, mints new
   wallet grants, and emits an outbox event.
4. If payment fails, the subscription enters `past_due` and an
   `outgoing_messages` row is queued for the dunning email.

### 15.5 Spending balance

1. App calls `hfcc.spend_user_balance(user_id, currency_code, amount,
   source_type, source_id, transaction_type_code, metadata)`.
2. The function reads `ledger_balances` for the user/currency, refuses if
   insufficient, and otherwise creates a balanced `ledger_transactions` debiting
   the user account and crediting the appropriate system account.
3. Audit log is written through the dispatcher.

### 15.6 Sending a notification

1. App inserts a row into `hfcc.outgoing_messages` with `status_code =
   pending`.
2. `enqueue_outgoing_message_outbox` writes an
   `hfcc.events_outbox.event_code.message.send_requested` event into
   `events_outbox`.
3. pg_cron's `process_due_events_outbox` picks it up; the registered
   `handle_*` function marks in-app messages sent or records that an external
   webhook/Edge Function is expected.
4. If the in-app message remains unread, the escalation handler creates the
   next configured outgoing message, for example an FCM push after 10 seconds
   and SMS/email after 60 seconds when recipients are available.

---

## 16. Function catalog

> All functions live in the `hfcc` schema. Argument lists are abbreviated for
> readability; see `HFCC.sql` for full signatures.

### EDA

* `enqueue_outbox_event(event_code, source_type, source_id, payload,
  metadata, run_at)`
* `claim_due_jobs(limit)` / `process_due_jobs(limit)`
* `claim_due_events_outbox(limit)` / `process_due_events_outbox(limit)`
* `retry_stuck_jobs(stale_after)` / `retry_stuck_events_outbox(stale_after)`
* `handle_job_subscription_maintenance_daily(payload)`
* `handle_job_subscription_expire(payload)`
* `handle_job_subscription_activate(payload)`
* `handle_job_subscription_renewal_notice(payload)`
* `invoke_type_handler(entity, field, code, op, table_schema, table_name,
  row_id, old_row, new_row)` — generic dispatcher.

### Auth & users

* `handle_new_auth_user()` — mirrors `auth.users` into `hfcc.users`.
* `ensure_hfcc_user(user_id)` — idempotent `hfcc.users` row creation.
* `ensure_user_ledger_accounts(user_id)`.

### Ledger

* `assert_ledger_transaction_balanced(transaction_id)`
* `assert_non_system_balances_allowed(transaction_id)`
* `validate_ledger_entries_balance_trigger()`
* `validate_ledger_transaction_balance_trigger()`
* `create_ledger_transaction(transaction_type_code, user_id, entries,
  currency_code, metadata)`
* `spend_user_balance(user_id, currency_code, amount, source_type, source_id,
  transaction_type_code, metadata)`

### Subscriptions

* `subscription_interval(interval_code)`
* `prevent_immutable_subscription_update()`
* `schedule_subscription_lifecycle_jobs(subscription_id, replace_existing)`
* `activate_scheduled_subscription(subscription_id, activated_at)`
* `enqueue_subscription_renewal_notice(subscription_id, fire_at)`
* `apply_subscription_entitlements(subscription_id, order_id, granted_at,
  is_renewal)`
* `after_subscription_activation()`
* `process_subscription_maintenance(user_id, run_at)`

### Promotions

* `validate_promotion_for_user(user_id, code, context_type, context_id,
  source_id)`
* `validate_promotion_usage()`
* `after_promotion_usage_insert()`
* `apply_promotion(user_id, code, context_type, context_id, source_type,
  source_id, actor_user_id)`

### Commerce

* `create_subscription_from_order(order_id, granted_at)`
* `create_subscription_renewal_order(subscription_id, fire_at)`
* `apply_subscription_renewal_order(order_id, subscription_id, granted_at)`
* `apply_commerce_order_item_entitlements(order_id, item_id, granted_at)`
* `recalculate_commerce_order_totals(order_id)`
* `recalculate_commerce_order_payment_status(order_id)`
* `recalculate_commerce_order_status_from_items(order_id)`
* `process_commerce_order(order_id, granted_at)`
* `after_commerce_order_confirmed()`
* `after_commerce_order_item_status_change()`
* `after_commerce_order_item_totals_change()`
* `after_commerce_payment_intent_status_change()`

### Messaging & audit

* `enqueue_outgoing_message_outbox()`
* `audit_row_change()`
* `install_audit_trigger(table_oid)`
* `core_before_write()`
* `core_after_type_dispatch()`

---

## 17. Trigger catalog

| Table                         | Trigger                                                | Function                                       |
|-------------------------------|--------------------------------------------------------|------------------------------------------------|
| every type-aware table        | `core_before_write` (BEFORE)                           | `core_before_write`                            |
| every type-aware table        | `core_after_type_dispatch` (AFTER)                     | `core_after_type_dispatch`                     |
| `ledger_entries`              | `ledger_entries_balance_check`                         | `validate_ledger_entries_balance_trigger`      |
| `ledger_transactions`         | `ledger_transactions_balance_check`                    | `validate_ledger_transaction_balance_trigger`  |
| `subscriptions`               | `prevent_immutable_subscription_update`                | `prevent_immutable_subscription_update`        |
| `subscriptions`               | `after_subscription_activation`                        | `after_subscription_activation`                |
| `promotion_usages`            | `validate_promotion_usage` (BEFORE)                    | `validate_promotion_usage`                     |
| `promotion_usages`            | `after_promotion_usage_insert`                         | `after_promotion_usage_insert`                 |
| `commerce_orders`             | `after_commerce_order_confirmed`                       | `after_commerce_order_confirmed`               |
| `commerce_order_items`        | `after_commerce_order_item_status_change`              | `after_commerce_order_item_status_change`      |
| `commerce_order_items`        | `after_commerce_order_item_totals_change`              | `after_commerce_order_item_totals_change`      |
| `commerce_payment_intents`    | `after_commerce_payment_intent_status_change`          | `after_commerce_payment_intent_status_change`  |
| `outgoing_messages`           | `enqueue_outgoing_message_outbox`                      | `enqueue_outgoing_message_outbox`              |
| 12 audited tables             | `audit_row_change`                                     | `audit_row_change`                             |

---

## 18. Integration playbook for AI agents

When wiring a feature into HFCC, follow this checklist:

1. **Use codes, not magic strings.**
   * If you need a new status / event / category, insert a row into
     `hfcc.types` with the full namespaced code
     (`schema.entity.field.value`) and any handler/audit flags.
   * Reference the code from your `*_code` column. Do not bypass the FK and
     CHECK constraints.
2. **Validate JSONB shapes at write time.**
   * For new JSONB columns, register an `hfcc.json_schemas` row keyed on
     `(entity, field, version)`. The before-write trigger picks it up
     automatically.
3. **Never hand-write to ledger tables.**
   * Always go through `create_ledger_transaction` /
     `spend_user_balance`. Direct writes to `ledger_entries` will be
     rejected at COMMIT by the deferred balance triggers.
4. **Make all async work transactional.**
   * To kick off background work, insert a row into `hfcc.events_outbox` (via
     `enqueue_outbox_event`) or `hfcc.jobs`. Both are transactional with the
     producing write.
   * To register a handler, create `hfcc.handle_<name>(p_payload jsonb)` and
     reference it from the type row's `invoke_functions`.
5. **Prefer service-role for backend writes.**
   * The Replit `apps/api-server` should use the Supabase service-role key
     (or direct psql) for write paths. Only read paths should rely on the
     end-user JWT.
6. **Treat order/subscription state as derived.**
   * Don't manually set `commerce_orders.payment_status_code` or
     `commerce_orders.status_code`; mutate the items / payment intents and
     let the recalculation triggers update the parent.
   * Don't manually set `subscriptions.current_period_*`; let
     `apply_subscription_*` helpers move them.
7. **Use the audit log instead of writing your own.**
   * Set `hfcc.types.log_audit = true` for the codes you care about, or call
     `install_audit_trigger` for new tables.
8. **Idempotency lives in `(context_type, context_id)`.**
   * Promotion redemption and outbox processing both rely on these
     polymorphic identifiers. When invoking helpers from API routes, derive
     them deterministically from the request.
9. **Send notifications via `outgoing_messages`.**
   * Inserting a `pending` row triggers an outbox event automatically; do not
     call providers from inside synchronous request handlers.
10. **Don't disable RLS.**
    * If your code paths look like they need to, switch to the service role
      instead — RLS is the only authorization layer in this schema.

When in doubt, search `HFCC.sql` for the relevant function name and read its
body: the SQL is heavily commented and is the single source of truth.
