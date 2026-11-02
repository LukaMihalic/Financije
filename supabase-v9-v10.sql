-- Financije: v9 (računi) + v10 (uvoz, oznake, brzi unosi, ciljevi) – pokreni JEDNOM, sigurno i više puta

-- =====================================================================
--  Financije v9 – računi (PBZ, Revolut, Gotovina) i prijenosi
--  Pokreni JEDNOM u Supabase -> SQL Editor -> New query -> Run
--  (sigurno ju je pokrenuti i više puta)
-- =====================================================================

create table if not exists public.accounts (
  id              uuid primary key default gen_random_uuid(),
  user_id         uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name            text not null,
  icon            text not null default '🏦',
  opening_balance numeric(12,2) not null default 0,
  opening_date    date not null default current_date,
  sort            int not null default 100,
  archived        boolean not null default false,
  created_at      timestamptz not null default now()
);
alter table public.accounts enable row level security;
drop policy if exists accounts_all on public.accounts;
create policy accounts_all on public.accounts for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

-- račun uz svaki unos; kod prijenosa i račun na koji ide novac
alter table public.transactions add column if not exists account_id    uuid references public.accounts(id) on delete set null;
alter table public.transactions add column if not exists to_account_id uuid references public.accounts(id) on delete set null;
alter table public.recurring    add column if not exists account_id    uuid references public.accounts(id) on delete set null;

-- nova vrsta unosa: prijenos između računa (nije ni trošak ni prihod)
alter table public.transactions drop constraint if exists transactions_kind_check;
alter table public.transactions add constraint transactions_kind_check
  check (kind in ('expense','income','settlement','transfer'));

-- početni računi; PBZ preuzima dosadašnje stanje računa
insert into public.accounts (user_id, name, icon, opening_balance, opening_date, sort)
select p.id, a.name, a.icon,
       case when a.sort = 1 then coalesce(p.opening_balance, 0) else 0 end,
       case when a.sort = 1 then coalesce(p.opening_date, current_date) else current_date end,
       a.sort
from public.profiles p
cross join (values ('PBZ', '🏦', 1), ('Revolut', '💳', 2), ('Gotovina', '💵', 3)) as a(name, icon, sort)
where not exists (select 1 from public.accounts x where x.user_id = p.id);

-- dosadašnji unosi idu na glavni račun (PBZ)
update public.transactions t
set account_id = (select a.id from public.accounts a where a.user_id = t.user_id order by a.sort, a.created_at limit 1)
where t.account_id is null and t.kind in ('expense','income','settlement');

update public.recurring r
set account_id = (select a.id from public.accounts a where a.user_id = r.user_id order by a.sort, a.created_at limit 1)
where r.account_id is null;

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
