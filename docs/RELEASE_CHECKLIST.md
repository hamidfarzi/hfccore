# Open-Source Release Checklist

Use this checklist before pushing HFCC to GitHub or publishing a release.

## Repository

- Confirm the project name is Hamid Farzi Central Core in comments and documentation.
- Confirm the license is correct for the intended release.
- Confirm `README.md`, `HFCC.md`, and `docs/` are up to date.
- Confirm `.gitignore` excludes local environment files, dumps, logs, and generated backups.
- Initialize Git if needed:

```bash
git init
git add .
git commit -m "Prepare HFCC for open source release"
```

## Audit

- Scan for private customization names:

```bash
rg -n -i "private-project-name|customer-name|legacy-brand-name" .
```

- Scan for secrets or sensitive values:

```bash
rg -n -i "secret|password|api[_ -]?key|service_role|token|private key" .
```

- Manually review matches. Technical words such as `service_role`, `push_token`, and provider token descriptions can be expected, but real credentials must not exist.

## Database Verification

- Apply `HFCC.sql` to a disposable database.
- Verify `hfcc.types` has seed rows.
- Verify all expected `hfcc` tables exist.
- Verify RLS is enabled for public-facing tables.
- Verify scheduled processing is present when `pg_cron` is available.

## GitHub

- Create a new GitHub repository.
- Add the remote:

```bash
git remote add origin git@github.com:<owner>/<repo>.git
git branch -M main
git push -u origin main
```

- Enable branch protection if accepting contributions.
- Add repository topics such as `postgresql`, `supabase`, `rls`, `event-driven`, `ledger`, and `commerce`.
