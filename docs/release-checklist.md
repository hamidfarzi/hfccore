# Release Checklist

Use this checklist before publishing a GitHub release, tagging a
version, or sharing the repository publicly.

## Documentation

- [ ] README reviewed
- [ ] Architecture docs reviewed
- [ ] Use cases reviewed for accurate positioning
- [ ] Recruiter brief reviewed for precise claims
- [ ] Roadmap updated
- [ ] Existing docs updated if schema behavior changed

## Privacy And Safety

- [ ] No private data
- [ ] No credentials
- [ ] No private client names, project names, or NDA-sensitive details
- [ ] No real API keys, service-role keys, tokens, passwords, or provider secrets
- [ ] No raw card data or sensitive payment data

Suggested scan:

```bash
rg -n -i "secret|password|api[_ -]?key|service_role|token|private key" .
```

Review expected technical matches manually. Words such as `service_role`
and `push_token` can be legitimate schema terminology; real credential
values must not exist.

## Database Verification

- [ ] Schema applies cleanly to a disposable Supabase/PostgreSQL database
- [ ] Required extensions reviewed
- [ ] RLS policies reviewed
- [ ] Grants reviewed for `anon`, `authenticated`, and `service_role`
- [ ] Core functions created
- [ ] Core triggers created
- [ ] Event/job processing reviewed
- [ ] Ledger constraints reviewed
- [ ] Examples verified where examples exist

## Release

- [ ] Docs updated
- [ ] Version tag created
- [ ] GitHub topics reviewed
- [ ] Release notes avoid production or compliance overclaims

Recommended topics:

`postgresql`, `supabase`, `rls`, `backend-architecture`, `event-driven`,
`ledger`, `product-systems`, `saas`, `database-design`,
`platform-engineering`
