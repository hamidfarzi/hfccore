# Development Guide

Use this guide when extending HFCC with new tables, codes, handlers, or policies.

## Local Workflow

1. Work from a clean branch.
2. Search [`HFCC.sql`](../HFCC.sql) for the closest existing pattern before adding a new object.
3. Add type rows before using a new status, source, category, channel, event, or job code.
4. Keep SQL idempotent where possible.
5. Add or update documentation in [`../HFCC.md`](../HFCC.md) and this `docs/` folder when behavior changes.
6. Run the verification queries in [`GETTING_STARTED.md`](GETTING_STARTED.md).

## Adding A Type Code

Add a row to `hfcc.types` using the namespace format:

```text
schema.entity.field.value
```

For example:

```text
hfcc.jobs.status_code.pending
```

The `schema`, `entity`, and `field` columns must match the code prefix. If a code should dispatch behavior, put handler names in `invoke_functions`.

## Adding A Handler

1. Create a function named `hfcc.handle_<meaningful_name>(p_payload jsonb)`.
2. Return a JSONB result with enough information for audit/debugging.
3. Register the function name in `hfcc.types.invoke_functions` for the relevant type row.
4. Grant execution only to the roles that need it.
5. Document the handler in [`../HFCC.md`](../HFCC.md).

## Adding A JSONB Column

1. Add the column with a default object or array when practical.
2. Add a matching row to `hfcc.json_schemas`.
3. Confirm `hfcc.core_before_write()` validates the target table and column.
4. Include examples in documentation when payload shape matters.

## Adding Tables

Follow existing table conventions:

- UUID primary key with `extensions.gen_random_uuid()`.
- `created_at timestamptz not null default now()`.
- `updated_at` on mutable tables.
- Type-bearing text columns with foreign keys to `hfcc.types(code)` and prefix checks.
- RLS enabled before public use.
- Grants and policies defined near related tables.
- Trigger installation included near shared trigger setup.

## SQL Review Checklist

- No project-specific product customizations are present.
- No raw secrets, API keys, payment card data, or private tokens are stored.
- Every coded value has a corresponding `hfcc.types` row.
- Every JSONB payload has either a clear reason to stay flexible or a schema row.
- Functions have a controlled `search_path`.
- Privileged functions use `SECURITY DEFINER` only when required.
- RLS policies are present for browser-facing tables.
- Comments and docs use the current name: Hamid Farzi Central Core.
