-- Extra shim, ONLY for testing docs/orchestrator/dev-apply-pack.sql on a throwaway Postgres (never loaded by run.sh):
-- the demo seed writes real-shaped Supabase auth rows and calls extensions.crypt(), which the minimal shim lacks.
create schema if not exists extensions;
create extension if not exists pgcrypto schema extensions;
alter table auth.users
  add column if not exists instance_id uuid, add column if not exists aud text, add column if not exists role text,
  add column if not exists encrypted_password text, add column if not exists confirmation_token text, add column if not exists recovery_token text,
  add column if not exists email_change_token_new text, add column if not exists email_change text, add column if not exists email_change_token_current text,
  add column if not exists reauthentication_token text, add column if not exists phone_change text, add column if not exists phone_change_token text,
  add column if not exists raw_app_meta_data jsonb default '{}', add column if not exists updated_at timestamptz default now();
create table if not exists auth.identities (id uuid primary key default gen_random_uuid(), user_id uuid references auth.users(id) on delete cascade,
  identity_data jsonb, provider text, provider_id text, last_sign_in_at timestamptz, created_at timestamptz default now(), updated_at timestamptz default now());
