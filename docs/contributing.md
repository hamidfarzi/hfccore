# Contributing

Contributions should preserve HFCC as a generic, reusable core schema. Avoid application-specific names, business rules, brands, seed data, or UI assumptions unless they are broadly useful core behavior.

## Contribution Flow

1. Open an issue or describe the change before large schema work.
2. Create a focused branch.
3. Update SQL, reference docs, and developer docs together.
4. Test installation on a disposable Supabase/PostgreSQL database.
5. Include verification notes in the pull request.

## Pull Request Checklist

- The SQL script applies cleanly to a fresh database.
- Existing object names, policies, and grants are not renamed without a migration reason.
- New codes follow the `schema.entity.field.value` convention.
- No customer-specific or private-product customization is introduced.
- No secrets or sensitive generated data are committed.
- Documentation is updated.
- Security implications are described for RLS, grants, triggers, and privileged functions.

## Style

- Prefer explicit SQL over hidden application assumptions.
- Keep behavior close to existing HFCC patterns.
- Use comments for non-obvious invariants, not for restating simple SQL.
- Keep public documentation clear enough for a developer to install and extend the schema without private context.
