# Customization Audit

This file records the current public-release audit for project-specific customizations.

## Result

No private-product identifiers, namespaces, seed data, comments, or documentation references were found.

The only lowercase `mirror` matches are generic Supabase Auth synchronization wording:

- `HFCC.md`: describes `hfcc.users` as a mirror of `auth.users`.
- `HFCC.md`: says `handle_new_auth_user()` mirrors `auth.users`.
- `HFCC.sql`: comments that Supabase Auth inserts are mirrored into `hfcc.users`.

These are generic database identity synchronization references and are not private-product customizations.

## Recommended Repeat Scan

Before each public release, run a case-insensitive scan for project-specific terms:

```bash
rg -n -i "private-project-name|customer-name|legacy-brand-name" .
```

Also scan for accidental secrets:

```bash
rg -n -i "secret|password|api[_ -]?key|service_role|token|private key" .
```

Review expected technical terms manually. For example, `service_role` and `push_token` are legitimate Supabase/messaging terms in HFCC, but real key values must never be committed.
