-- Financije v4 – stanje računa
-- Pokreni JEDNOM u Supabase -> SQL Editor -> New query -> Run
alter table public.profiles add column if not exists opening_balance numeric(12,2);
alter table public.profiles add column if not exists opening_date    date;
grant update (display_name, opening_balance, opening_date) on public.profiles to authenticated;
