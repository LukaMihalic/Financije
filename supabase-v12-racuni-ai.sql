-- =====================================================================
--  Financije v12 – stavke s računa (Claude) i dnevno ograničenje
--  Pokreni JEDNOM u Supabase -> SQL Editor -> New query -> Run
-- =====================================================================

-- stavke pročitane s računa: [{ name, qty, price, category }]
alter table public.transactions add column if not exists items jsonb;

-- evidencija korištenja (za dnevno ograničenje u funkciji procitaj-racun)
create table if not exists public.ai_usage (
  id         bigint generated always as identity primary key,
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.ai_usage enable row level security;
drop policy if exists ai_usage_all on public.ai_usage;
create policy ai_usage_all on public.ai_usage for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
