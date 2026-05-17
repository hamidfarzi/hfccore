# Security

HFCC is a database core and should be treated as part of the application security boundary.

## Supported Reporting Path

For now, report security issues privately to the repository owner. Do not open a public issue for vulnerabilities involving authorization bypass, data leakage, secret exposure, payment data handling, or privilege escalation.

## Security Model

- Row-Level Security is enabled on HFCC tables.
- Browser-facing access should rely on authenticated Supabase roles and RLS policies.
- Privileged processing should run through trusted server code using `service_role`.
- Background jobs and outbox processing are database-driven and should be monitored like application workers.
- Raw card data, provider secrets, service role keys, API keys, and private tokens must not be stored in HFCC tables.

## Areas To Review Carefully

- `SECURITY DEFINER` functions.
- Grants to `anon`, `authenticated`, and `service_role`.
- RLS policies for user-owned rows.
- Webhook/event inbox handling.
- Payment method and payment intent metadata.
- Message recipient resolution and push tokens.
- Audit log retention and access.

## Before Public Release

Run the customization and secret scans in [`release-checklist.md`](release-checklist.md), then review all findings manually. Automated scans are useful, but they do not replace a security review.
