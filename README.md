# HFCC — PostgreSQL/Supabase Core for Event-Driven Product Systems

HFCC is a PostgreSQL/Supabase backend core for product systems that need structured permissions, workflow events, background jobs, ledger-style accounting, audit logs, and extensible domain types.

It is designed as a database-first foundation for applications where business rules, operational history, and workflow correctness matter.

HFCC can be used as a reference architecture, a starting point for backend-heavy products, or a collection of patterns for modeling complex product domains in PostgreSQL.

---

## Core Ideas

HFCC is built around a few backend architecture principles:

* Keep important domain rules close to the data
* Make workflow state explicit
* Use structured events for side effects
* Use background jobs for async work
* Prefer ledger-style records over mutable balance fields
* Make access control visible at the schema level
* Keep operational history through audit and activity logs
* Use extensible domain types instead of hardcoding every product concept

The project is intentionally backend-first. It focuses on data model, workflow model, security model, and operational backend structure rather than frontend UI.

---

## What HFCC Provides

HFCC provides reusable backend patterns for:

* PostgreSQL-first domain modeling
* Supabase-compatible application architecture
* Row-Level Security aware access control
* Type registry based extensibility
* Outbox and inbox event workflows
* Background job processing
* Ledger-style financial or credit movement
* Commerce and subscription lifecycle structures
* Messaging, audit logs, and activity tracking

The goal is not to provide a finished SaaS product. The goal is to provide a structured backend core that can be studied, adapted, and extended for real product systems.

---

## Why This Exists

Many product systems start as simple CRUD applications and become harder to maintain once they need:

* Permissions
* Workflow states
* Background jobs
* Notifications
* Audit logs
* Financial movement
* Subscriptions
* Promotions
* User activity tracking
* Operational visibility
* Cross-system integration

HFCC explores these concerns as database and backend architecture primitives instead of treating them as late-stage patches.

It is useful for backend-heavy products where correctness, traceability, and workflow structure matter from the beginning.

---

## Architecture Overview

```text
Auth Users
   ↓
HFCC Users / Profiles
   ↓
Type Registry + Validation Rules
   ↓
Core Domain Tables
   ↓
Outbox / Inbox / Jobs / Ledger / Commerce / Messaging / Audit
   ↓
Edge Functions / API / Application Layer
```

The architecture is organized around layered responsibility.

Supabase Auth or another authentication provider owns identity authentication.

HFCC users and profiles provide the application-facing identity layer.

The type registry provides extensible domain classification without relying only on hardcoded PostgreSQL enums.

Core domain tables represent reusable product-system concepts.

Outbox, inbox, jobs, ledger, commerce, messaging, and audit tables support operational backend workflows.

The API, Edge Functions, workers, or application layer can then interact with the backend core.

---

## Architecture Patterns

### PostgreSQL-First Domain Modeling

HFCC treats PostgreSQL as more than storage.

The database is used as a domain modeling layer where critical structures, relationships, constraints, and workflow rules can live close to the data.

This is useful when backend correctness matters more than fast UI prototyping.

PostgreSQL-first concerns include:

* Relational integrity
* Domain constraints
* Transactional workflows
* Workflow state
* Auditability
* Ledger movement
* User-scoped access
* Operational history

The goal is not to push every application decision into the database.

The goal is to keep important correctness rules near the data they protect.

---

### Type Registry Instead of Hardcoded Enums

Hardcoded enums can become restrictive as product behavior evolves.

HFCC uses a type registry pattern to represent extensible domain concepts such as statuses, event types, transaction types, workflow types, object categories, and system-defined classifications.

This makes it easier to add or modify product concepts without repeatedly changing the database enum layer.

The trade-off is that naming, validation, documentation, and governance become more important.

This pattern is useful for product systems that need to evolve without turning every new state or category into a schema migration.

---

### RLS-Aware Security Model

HFCC is designed with Supabase-style Row-Level Security in mind.

The schema is structured around user-scoped and profile-scoped data access.

RLS-aware design helps prevent authorization from existing only in API middleware.

This does not replace API-level authorization, but it provides an additional database-level security boundary.

Security-related concerns include:

* User ownership
* Profile-level access
* Scoped reads
* Scoped writes
* Service-role operations
* Internal system workflows
* Public vs private records

Before using HFCC in production, RLS policies should be reviewed and adapted to the exact application requirements.

---

### Event-Driven Runtime

HFCC includes event-driven backend concepts such as:

* Outbox events
* Inbox events
* Background jobs
* Handler dispatch
* Scheduled processing

These patterns are useful when product workflows should not depend only on synchronous request/response logic.

A product system may need to:

* Send notifications
* Process payments
* Sync external systems
* Update lifecycle states
* Trigger operational workflows
* Run retries
* Record side effects
* Coordinate async work

The outbox pattern separates durable domain events from later side effects.

The inbox pattern helps track received or processed events.

Jobs provide a structured way to model work that should happen outside the immediate user request.

---

### Ledger-Style Financial Movement

HFCC demonstrates ledger-style modeling for financial, credit, reward, or balance-related workflows.

Instead of treating balance as only a mutable number, a ledger-style model records movement as durable entries.

Balances can then be derived from recorded activity.

This improves:

* Auditability
* Reconciliation
* Traceability
* Transaction-level correctness
* Historical visibility

HFCC is not a regulated financial system and should not be treated as financial, legal, tax, or compliance advice.

It provides architecture patterns that can be adapted for product systems involving credits, wallets, points, rewards, payouts, or settlement-style workflows.

---

### Commerce and Subscription Structures

HFCC includes product-domain structures that can support commerce and subscription-like workflows.

These may include concepts such as:

* Products
* Orders
* Subscriptions
* Promotions
* Credits
* Rewards
* Customer-facing lifecycle states

HFCC is not a storefront and does not provide a complete commerce application.

It provides backend structures that can be extended for SaaS products, marketplaces, loyalty programs, internal commerce tools, and operational platforms.

---

### Messaging, Audit Logs, and Activity Tracking

Operational systems need visibility into what happened and why.

HFCC includes concepts for messaging, audit logs, and activity tracking.

These patterns help answer questions such as:

* What happened?
* Who triggered it?
* When did it happen?
* Which system area was affected?
* Did a background process complete?
* Did a workflow fail or retry?

This is useful in systems where silent failure is expensive and operational traceability matters.

---

## Example Use Cases

HFCC can be adapted as a backend foundation or architecture reference for several product-system scenarios.

These are example use cases, not claims of production deployment.

### SaaS Credit or Wallet Core

Many SaaS products need credits, usage balances, or internal wallet-style accounting.

HFCC provides patterns for:

* Ledger-style movement
* Derived balances
* Audit-friendly transaction records
* User-scoped access
* Extensible transaction types

Application-specific work would still include billing provider integration, product-specific credit rules, admin workflows, and user-facing UI.

---

### Subscription Lifecycle Engine

Subscription systems need lifecycle states such as active, paused, canceled, expired, trialing, renewal pending, or payment failed.

HFCC provides patterns for:

* Type registry based lifecycle states
* Event/job workflows for async renewal logic
* Audit logs for lifecycle changes
* User-scoped subscription records

Application-specific work would still include payment integration, invoice logic, renewal scheduling, customer portal UI, and cancellation flows.

---

### Marketplace Payment and Order Workflow Core

Marketplaces often need order state, payment state, payout logic, customer/provider records, and operational workflows.

HFCC provides patterns for:

* Ledger-style movement
* Event-driven processing
* Audit logs
* Commerce structures
* User/profile modeling
* RLS-aware access control

Application-specific work would still include matching logic, dispatch rules, provider workflows, payment gateway integration, refunds, disputes, and reporting.

---

### Loyalty and Reward System

Loyalty programs need points, rewards, redemptions, expiration rules, and activity tracking.

HFCC provides patterns for:

* Ledger-style reward movement
* Type registry based reward types
* Audit logs
* User profile layer
* Background jobs for expiration or recalculation

Application-specific work would still include campaign rules, reward catalog, admin tools, fraud checks, and customer-facing UI.

---

### Operational Backend Platform

Internal tools and operations platforms often need traceability, workflow state, user actions, and background processing.

HFCC provides patterns for:

* Activity logs
* Audit logs
* Event records
* Jobs
* User-scoped access
* Structured domain types

Application-specific work would still include domain-specific screens, dashboards, reporting views, alerting, and role-specific workflows.

---

### AI-Agent-Friendly Backend Foundation

AI-assisted tools and agents work better when the backend has clear structures, explicit workflow states, and auditable actions.

HFCC provides patterns for:

* Clear domain structure
* Type registry
* Event/job records
* Auditability
* Explicit workflow tables
* Database-first design

Application-specific work would still include agent tools, permissions, guardrails, approval workflows, API boundaries, and human review steps.

---

## Design Goals

HFCC is designed around these goals:

* Make core product concepts explicit in the database
* Reduce hidden workflow state in application code
* Support event-driven side effects through outbox and jobs
* Preserve operational history with activity and audit records
* Use ledger-style movement for balances, credits, points, or rewards
* Keep authorization visible at the schema level through RLS-aware design
* Allow domain concepts to evolve through a type registry
* Keep the system adaptable rather than tied to one specific product vertical

---

## Architecture Decisions

| Decision                           | Reason                                                               |
| ---------------------------------- | -------------------------------------------------------------------- |
| PostgreSQL-first design            | Keeps important domain rules close to the data                       |
| Type registry over hardcoded enums | Makes domain concepts easier to extend                               |
| Ledger-style movement              | Improves auditability and reduces balance drift risk                 |
| Outbox / inbox / jobs              | Supports async workflows and operational reliability                 |
| RLS-aware model                    | Supports user-scoped data access                                     |
| Audit and activity logging         | Improves traceability and operational debugging                      |
| Supabase-compatible design         | Works with Auth, RLS, Edge Functions, and Realtime-oriented patterns |

---

## Repository Structure

The repository structure may evolve over time.

Typical documentation files include:

```text
.
├── README.md
├── docs/
│   ├── architecture.md
│   ├── use-cases.md
│   ├── recruiter-brief.md
│   ├── roadmap.md
│   └── release-checklist.md
└── schema / migration files
```

If your local repository has additional schema, migration, or SQL files, inspect those files directly before applying the system to a Supabase project.

---

## Getting Started

HFCC is intended as an architecture reference and backend core.

Before using it in a real project, review the schema carefully.

### Prerequisites

You should be comfortable with:

* PostgreSQL
* Supabase
* SQL migrations
* Row-Level Security
* Database functions and triggers
* Backend application architecture

### Suggested Review Flow

1. Read this README.
2. Review the architecture documentation.
3. Inspect the schema and migration files.
4. Review RLS policies.
5. Review functions and triggers.
6. Review event, job, and ledger-related tables.
7. Apply to a local or test Supabase project only after review.
8. Adapt the schema to your own product domain.

### Supabase / PostgreSQL Setup

Use your normal Supabase or PostgreSQL workflow.

For example:

```bash
supabase start
```

Then apply migrations or SQL files according to your project setup.

Do not apply this directly to a production database without review.

Adjust commands according to your Supabase project setup.

---

## Verification Queries

The following read-only queries can help inspect a PostgreSQL/Supabase database after applying a schema.

### List Tables

```sql
select
  table_schema,
  table_name
from information_schema.tables
where table_schema not in ('pg_catalog', 'information_schema')
order by table_schema, table_name;
```

### List RLS Policies

```sql
select
  schemaname,
  tablename,
  policyname,
  permissive,
  roles,
  cmd
from pg_policies
order by schemaname, tablename, policyname;
```

### List Functions

```sql
select
  routine_schema,
  routine_name,
  routine_type
from information_schema.routines
where routine_schema not in ('pg_catalog', 'information_schema')
order by routine_schema, routine_name;
```

### List Triggers

```sql
select
  event_object_schema,
  event_object_table,
  trigger_name,
  action_timing,
  event_manipulation
from information_schema.triggers
order by event_object_schema, event_object_table, trigger_name;
```

### List Installed Extensions

```sql
select
  extname,
  extversion
from pg_extension
order by extname;
```

### Find Ledger-Related Objects

```sql
select
  table_schema,
  table_name
from information_schema.tables
where table_name ilike '%ledger%'
   or table_name ilike '%wallet%'
   or table_name ilike '%transaction%'
order by table_schema, table_name;
```

### Find Event or Job Related Objects

```sql
select
  table_schema,
  table_name
from information_schema.tables
where table_name ilike '%event%'
   or table_name ilike '%job%'
   or table_name ilike '%outbox%'
   or table_name ilike '%inbox%'
order by table_schema, table_name;
```

---

## Documentation

Recommended documentation files:

* `docs/architecture.md`
* `docs/use-cases.md`
* `docs/roadmap.md`
* `docs/release-checklist.md`

If a recruiter or hiring-manager summary is useful, keep it separate from the main README, for example in `docs/recruiter-brief.md`.

The main README should stay focused on the project, architecture, and developer-facing usage.

---

## Suggested GitHub Topics

Recommended repository topics:

* postgresql
* supabase
* rls
* backend-architecture
* event-driven
* ledger
* product-systems
* saas
* database-design
* platform-engineering

---

## Scope and Safety

HFCC is a backend architecture reference, not a complete production application.

Before using it in production, review and adapt:

* Schema design
* RLS policies
* Functions
* Triggers
* Migrations
* Security assumptions
* Business rules
* Compliance requirements

Do not apply this directly to a production database without review and testing.

---

## License

License to be added.

If a license file already exists in this repository, that license should be treated as the source of truth.
