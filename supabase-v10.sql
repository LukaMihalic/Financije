-- =====================================================================
--  Financije v10 – uvoz izvoda, oznake, brzi unosi, ciljevi štednje
--  Pokreni JEDNOM u Supabase -> SQL Editor -> New query -> Run
--  (sigurno ju je pokrenuti i više puta). Treba prije biti pokrenuta v9.
-- =====================================================================

-- trgovac (iz izvoda), oznake i otisak uvezenog reda (za prepoznavanje duplikata)
alter table public.transactions add column if not exists merchant    text;
alter table public.transactions add column if not exists tags        text[];
alter table public.transactions add column if not exists import_hash text;
create index if not exists transactions_import_hash on public.transactions (user_id, import_hash);

-- naučena pravila: trgovac -> kategorija
create table if not exists public.cat_rules (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  pattern     text not null,
  category_id uuid not null references public.categories(id) on delete cascade,
  created_at  timestamptz not null default now(),
  unique (user_id, pattern)
);

-- brzi unosi (favoriti)
create table if not exists public.favorites (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  label       text not null,
  icon        text not null default '⭐',
  kind        text not null default 'expense' check (kind in ('expense','income')),
  amount      numeric(12,2) not null check (amount > 0),
  category_id uuid references public.categories(id) on delete set null,
  account_id  uuid references public.accounts(id) on delete set null,
  note        text,
  sort        int not null default 100,
  created_at  timestamptz not null default now()
);

-- ciljevi štednje
create table if not exists public.goals (
  id          uuid primary key default gen_random_uuid(),
  user_id     uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name        text not null,
  icon        text not null default '🎯',
  target      numeric(12,2) not null check (target > 0),
  saved       numeric(12,2) not null default 0,
  deadline    date,
  account_id  uuid references public.accounts(id) on delete set null,
  done        boolean not null default false,
  created_at  timestamptz not null default now()
);

alter table public.cat_rules enable row level security;
alter table public.favorites enable row level security;
alter table public.goals     enable row level security;
drop policy if exists cat_rules_all on public.cat_rules;
drop policy if exists favorites_all on public.favorites;
drop policy if exists goals_all     on public.goals;
create policy cat_rules_all on public.cat_rules for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy favorites_all on public.favorites for all using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy goals_all     on public.goals     for all using (user_id = auth.uid()) with check (user_id = auth.uid());
