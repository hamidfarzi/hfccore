# HFCC Use Cases

HFCC is a public architecture proof project. The examples below describe
practical directions where this database core could be adapted, not
guaranteed production deployments.

## SaaS Credits

**Problem:** SaaS products often need credits, quotas, trial balances,
plan entitlements, expiration rules, and user-visible usage history.

**How HFCC helps:** The ledger model can represent credit grants and
spends as transaction entries. Subscriptions and wallet grants can model
recurring entitlements. RLS policies provide user-scoped reads.

**What still needs to be built:** Product-specific pricing rules, API
endpoints, usage metering integration, billing-provider webhooks,
customer support workflows, tests, and production monitoring.

## Loyalty Points

**Problem:** Loyalty programs need rewards, promotions, redemption
rules, expiration, and auditable user history.

**How HFCC helps:** Promotions, promotion usages, wallet grants, ledger
transactions, and activity logs provide a foundation for reward issuance
and tracking.

**What still needs to be built:** Program-specific rules, fraud
controls, customer-facing redemption flows, admin review tools,
expiration policies, and reporting.

## Subscription Lifecycle

**Problem:** Subscription systems require lifecycle state, activation,
expiration, renewal notices, payment method references, renewal orders,
and entitlement changes.

**How HFCC helps:** The schema includes subscriptions, lifecycle jobs,
renewal order helpers, payment intents, wallet grants, and outgoing
messages for notification workflows.

**What still needs to be built:** Provider-specific billing integration,
webhook verification, retry/dunning rules, invoice presentation, admin
tooling, legal copy, and policy tests.

## Marketplace Settlement

**Problem:** Marketplaces need order state, payment attempts, account
movement, refunds/adjustments, and traceable settlement workflows.

**How HFCC helps:** Commerce orders, order items, payment intents,
ledger transactions, audit logs, and outbox events model the backend
state needed for settlement-style workflows.

**What still needs to be built:** Seller accounts, platform fees, payout
provider integration, dispute/refund flows, tax handling, compliance
review, and operational dashboards.

## Commerce Promotions

**Problem:** Commerce systems need catalog items, orders, payment state,
promotion usage limits, user eligibility, and reward grants.

**How HFCC helps:** Commerce products, orders, order items, promotions,
promotion usage validation, and entitlement snapshots provide a
database-first commerce workflow foundation.

**What still needs to be built:** Cart APIs, price display rules,
checkout UI, payment provider integration, fulfillment workflows,
inventory integration, and promotion administration.

## Internal Operations Platform

**Problem:** Internal tools often need durable workflow state, audit
logs, user ownership, settings, background work, and traceability across
operational actions.

**How HFCC helps:** RLS-aware tables, jobs, events, activity logs, audit
logs, settings, and type-driven state provide a reusable backend core
for operational systems.

**What still needs to be built:** Role-specific admin UI, approval
workflows, organization/team modeling, reporting, alerting, and
deployment-specific access policies.

## AI-Agent-Operated Backend Core

**Problem:** AI-assisted systems need structured backend primitives that
agents can inspect and operate without relying on fragile implicit
application conventions.

**How HFCC helps:** The type registry, schema reference, event/job
tables, explicit functions, and audit logs make the backend state more
discoverable and safer to reason about.

**What still needs to be built:** Agent permission boundaries, tool-call
APIs, validation layers, human approval steps, observability, and misuse
prevention.
