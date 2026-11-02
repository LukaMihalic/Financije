-- =====================================================================
--  Financije v11 – zajednički račun s partnerom
--  Pokreni JEDNOM u Supabase -> SQL Editor -> New query -> Run
--  (sigurno ju je pokrenuti i više puta). Prije toga mora biti pokrenuta v9-v10.
-- =====================================================================

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
