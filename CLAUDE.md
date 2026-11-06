# AGENTS.md

## Project overview

This repository owns a managed Supabase backend. Database migrations, Edge Functions, auth configuration, and storage policy changes belong here and deploy together through Draftbit. Development, staging, and production are isolated Supabase targets; never hardcode a project ref or credential.

## Conventions

- SQL migrations live in `supabase/migrations/` and are append-only after deployment.
- Edge Functions live in `supabase/functions/<name>/index.ts` and use Deno-compatible dependencies.
- Use `yarn migration:new <name>` to create migrations and `yarn functions:serve` only when a compatible local runtime is available. When the task's `supabase/` changes are all written, call `sync_supabase_dev_instance` once to deploy migrations, Edge Functions, and `config.toml` to the development target the way publishing does.
- Read runtime configuration from environment variables. Never commit `.env`, access tokens, database URLs, service-role keys, or generated credentials.
- Prefer row-level security on exposed tables. Add explicit policies in the same migration that creates or exposes a table.
- Make schema changes additive when possible. Destructive migrations require a data-preservation and rollback plan.
- Run `yarn type-check` and `yarn test` after changes. Validate SQL locally or against the isolated development target before publishing.

## Publishing

Publishing applies committed migrations and deploys Edge Functions to exactly one selected environment target. The repository is the sole schema and deployment authority for its managed Supabase instance.
Publishing discovers only `supabase/migrations/*.sql` and `supabase/functions/<name>/index.ts`. Do not move, rename, or replace those directories; files outside that structure are not deployed.
