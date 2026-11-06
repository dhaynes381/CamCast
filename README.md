# Draftbit Supabase Backend

Repository-owned Supabase backend for a Draftbit app. Database migrations, Edge Functions, auth
configuration, and storage configuration are versioned here and deployed together by Draftbit.

## Layout

- `supabase/migrations/`: ordered SQL migrations; never edit a migration after it has shipped.
- `supabase/functions/`: Deno Edge Functions, one directory per function.
- `supabase/config.toml`: local and hosted Supabase configuration.

## Development

```sh
yarn install
yarn supabase start
yarn supabase migration new describe_change
yarn supabase db reset
yarn type-check
yarn test
```

Draftbit creates isolated development and staging branches and keeps production on the root project.
Publishing applies this repository's configuration and migrations only to the selected environment.
If the Supabase project is claimed, this app becomes a read-only archive while this repository is
retained for download.

