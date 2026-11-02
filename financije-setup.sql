-- =====================================================================
--  FINANCIJE – postavljanje baze u Supabaseu  (verzija 11)
--  Pokreni CIJELU skriptu u: Supabase -> SQL Editor -> New query -> Run
--  Sigurno ju je pokrenuti više puta – ništa se ne briše i ne duplicira.
--  Usput napravi profil i kategorije za već registrirane korisnike.
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------- PROFILI ----------
create table if not exists public.profiles (
  id           uuid primary key references auth.users(id) on delete cascade,
  display_name text not null default 'Ja',
  invite_code  text unique not null,
  partner_id   uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now()
);

-- stanje računa (v4)
alter table public.profiles add column if not exists opening_balance numeric(12,2);
alter table public.profiles add column if not exists opening_date    date;

-- ---------- RAČUNI (v9) ----------
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

-- ---------- KATEGORIJE ----------
create table if not exists public.categories (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null default auth.uid() references auth.users(id) on delete cascade,
  name       text not null,
  kind       text not null check (kind in ('expense','income')),
  icon       text not null default '📦',
  budget     numeric(12,2),
  sort       int not null default 100,
  created_at timestamptz not null default now()
);

-- ---------- PONAVLJAJUĆI UNOSI ----------
create table if not exists public.recurring (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind         text not null check (kind in ('expense','income')),
  amount       numeric(12,2) not null check (amount > 0),
  category_id  uuid references public.categories(id) on delete set null,
  note         text,
  day_of_month int not null check (day_of_month between 1 and 31),
  is_shared    boolean not null default false,
  last_month   text,
  active       boolean not null default true,
  created_at   timestamptz not null default now()
);

-- ---------- TRANSAKCIJE ----------
create table if not exists public.transactions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null default auth.uid() references auth.users(id) on delete cascade,
  kind         text not null check (kind in ('expense','income','settlement')),
  amount       numeric(12,2) not null check (amount > 0),
  category_id  uuid references public.categories(id) on delete set null,
  date         date not null default current_date,
  note         text,
  is_shared    boolean not null default false,
  recurring_id uuid references public.recurring(id) on delete set null,
  created_at   timestamptz not null default now(),
  unique (recurring_id, date)
);
create index if not exists transactions_user_date on public.transactions (user_id, date);
alter table public.transactions add column if not exists account_id    uuid references public.accounts(id) on delete set null;
alter table public.transactions add column if not exists to_account_id uuid references public.accounts(id) on delete set null;
alter table public.recurring    add column if not exists account_id    uuid references public.accounts(id) on delete set null;
alter table public.transactions drop constraint if exists transactions_kind_check;
alter table public.transactions add constraint transactions_kind_check
  check (kind in ('expense','income','settlement','transfer'));

-- ---------- POMOĆNA FUNKCIJA: tko je moj partner ----------
create or replace function public.my_partner() returns uuid
language sql stable security definer set search_path = public as $$
  select partner_id from public.profiles where id = auth.uid()
$$;

-- ---------- PROFIL + OSNOVNE KATEGORIJE ZA KORISNIKA ----------
create or replace function public.seed_user(p_id uuid, p_email text, p_name text) returns void
language plpgsql security definer set search_path = public as $$
begin
  insert into public.profiles (id, display_name, invite_code)
  values (
    p_id,
    coalesce(nullif(trim(p_name), ''), split_part(p_email, '@', 1), 'Ja'),
    upper(substr(md5(random()::text || p_id::text), 1, 6))
  )
  on conflict (id) do nothing;

  if not exists (select 1 from public.accounts where user_id = p_id) then
    insert into public.accounts (user_id, name, icon, sort) values
      (p_id, 'Tekući račun', '🏦', 1),
      (p_id, 'Gotovina',     '💵', 2);
  end if;

  if not exists (select 1 from public.categories where user_id = p_id) then
    insert into public.categories (user_id, name, kind, icon, sort) values
      (p_id, 'Hrana i namirnice',  'expense', '🛒', 1),
      (p_id, 'Stanovanje',         'expense', '🏠', 2),
      (p_id, 'Režije',             'expense', '💡', 3),
      (p_id, 'Prijevoz',           'expense', '🚗', 4),
      (p_id, 'Kafići i restorani', 'expense', '☕', 5),
      (p_id, 'Izlasci i zabava',   'expense', '🎉', 6),
      (p_id, 'Zdravlje',           'expense', '💊', 7),
      (p_id, 'Odjeća',             'expense', '👕', 8),
      (p_id, 'Pretplate',          'expense', '📱', 9),
      (p_id, 'Ljubimci',           'expense', '🐾', 10),
      (p_id, 'Pokloni',            'expense', '🎁', 11),
      (p_id, 'Putovanja',          'expense', '✈️', 12),
      (p_id, 'Ostalo',             'expense', '📦', 13),
      (p_id, 'Plaća',              'income',  '💼', 1),
      (p_id, 'Dodatni posao',      'income',  '💶', 2),
      (p_id, 'Ostali prihodi',     'income',  '💰', 3);
  end if;
end $$;

revoke execute on function public.seed_user(uuid, text, text) from public, anon, authenticated;

-- Aplikacija ovo poziva ako prijavljenom korisniku nedostaje profil
create or replace function public.ensure_my_profile() returns void
language plpgsql security definer set search_path = public as $$
declare u auth.users;
begin
  select * into u from auth.users where id = auth.uid();
  if u.id is null then raise exception 'Nisi prijavljen.'; end if;
  perform public.seed_user(u.id, u.email, u.raw_user_meta_data->>'display_name');
end $$;

create or replace function public.handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  perform public.seed_user(new.id, new.email, new.raw_user_meta_data->>'display_name');
  return new;
end $$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------- POVEZIVANJE S PARTNEROM ----------
create or replace function public.link_partner(p_code text) returns text
language plpgsql security definer set search_path = public as $$
declare
  me    uuid := auth.uid();
  other uuid;
begin
  if me is null then raise exception 'Nisi prijavljen.'; end if;
  select id into other from profiles where invite_code = upper(trim(p_code));
  if other is null then raise exception 'Taj kod ne postoji.'; end if;
  if other = me then raise exception 'To je tvoj vlastiti kod.'; end if;
  if exists (select 1 from profiles where id in (me, other) and partner_id is not null) then
    raise exception 'Jedan od vas je već povezan s nekim.';
  end if;
  update profiles set partner_id = other where id = me;
  update profiles set partner_id = me    where id = other;
  return (select display_name from profiles where id = other);
end $$;

create or replace function public.unlink_partner() returns void
language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  other uuid;
begin
  select partner_id into other from profiles where id = me;
  update profiles set partner_id = null where id = me;
  if other is not null then
    update profiles set partner_id = null where id = other and partner_id = me;
  end if;
end $$;

-- ---------- SIGURNOST (Row Level Security) ----------
alter table public.profiles     enable row level security;
alter table public.categories   enable row level security;
alter table public.recurring    enable row level security;
alter table public.transactions enable row level security;

drop policy if exists profiles_select on public.profiles;
drop policy if exists profiles_update on public.profiles;
create policy profiles_select on public.profiles for select
  using (id = auth.uid() or id = public.my_partner());
create policy profiles_update on public.profiles for update
  using (id = auth.uid()) with check (id = auth.uid());
revoke update on public.profiles from anon, authenticated;
grant  update (display_name, opening_balance, opening_date) on public.profiles to authenticated;

drop policy if exists categories_select on public.categories;
drop policy if exists categories_insert on public.categories;
drop policy if exists categories_update on public.categories;
drop policy if exists categories_delete on public.categories;
create policy categories_select on public.categories for select
  using (user_id = auth.uid() or user_id = public.my_partner());
create policy categories_insert on public.categories for insert
  with check (user_id = auth.uid());
create policy categories_update on public.categories for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy categories_delete on public.categories for delete
  using (user_id = auth.uid());

alter table public.accounts enable row level security;
drop policy if exists accounts_all on public.accounts;
create policy accounts_all on public.accounts for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists recurring_all on public.recurring;
create policy recurring_all on public.recurring for all
  using (user_id = auth.uid()) with check (user_id = auth.uid());

drop policy if exists tx_select on public.transactions;
drop policy if exists tx_insert on public.transactions;
drop policy if exists tx_update on public.transactions;
drop policy if exists tx_delete on public.transactions;
create policy tx_select on public.transactions for select
  using (user_id = auth.uid() or (is_shared and user_id = public.my_partner()));
create policy tx_insert on public.transactions for insert
  with check (user_id = auth.uid());
create policy tx_update on public.transactions for update
  using (user_id = auth.uid()) with check (user_id = auth.uid());
create policy tx_delete on public.transactions for delete
  using (user_id = auth.uid());

-- ---------- v10: uvoz, oznake, brzi unosi, ciljevi ----------

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

-- ---------- v11: zajednički račun ----------

alter table public.accounts add column if not exists shared boolean not null default false;

-- je li račun zajednički račun mene ili mog partnera
create or replace function public.is_joint_account(a uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select a is not null and exists (
    select 1 from public.accounts x
    where x.id = a and x.shared
      and x.user_id in (auth.uid(), (select partner_id from public.profiles where id = auth.uid())))
$$;

-- smijem li upisati unos na ovaj račun (svoj ili partnerov zajednički)
create or replace function public.can_use_account(a uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select a is null or exists (
    select 1 from public.accounts x
    where x.id = a and (x.user_id = auth.uid()
      or (x.shared and x.user_id = (select partner_id from public.profiles where id = auth.uid()))))
$$;

-- partner vidi moje zajedničke račune
drop policy if exists accounts_partner_select on public.accounts;
create policy accounts_partner_select on public.accounts for select
  using (shared and user_id = public.my_partner());

-- unosi: partner vidi zajedničke troškove i sve unose na zajedničkim računima
drop policy if exists tx_select on public.transactions;
drop policy if exists tx_insert on public.transactions;
drop policy if exists tx_update on public.transactions;
create policy tx_select on public.transactions for select
  using (user_id = auth.uid()
    or (user_id = public.my_partner()
        and (is_shared or public.is_joint_account(account_id) or public.is_joint_account(to_account_id))));
create policy tx_insert on public.transactions for insert
  with check (user_id = auth.uid() and public.can_use_account(account_id) and public.can_use_account(to_account_id));
create policy tx_update on public.transactions for update
  using (user_id = auth.uid())
  with check (user_id = auth.uid() and public.can_use_account(account_id) and public.can_use_account(to_account_id));

-- ---------- PROFILI ZA VEĆ REGISTRIRANE KORISNIKE ----------
select public.seed_user(u.id, u.email, u.raw_user_meta_data->>'display_name')
from auth.users u;
