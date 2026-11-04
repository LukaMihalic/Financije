-- Financije v11 – popravak: partner vidi zajedničke račune i unose na njima
-- Pokreni u SQL Editoru (bez begin/rollback). Na kraju ispiše postavljena pravila.

drop policy if exists accounts_partner_select on public.accounts;
create policy accounts_partner_select on public.accounts for select to authenticated
  using (shared and user_id in (select p.partner_id from public.profiles p where p.id = auth.uid()));

drop policy if exists tx_select on public.transactions;
create policy tx_select on public.transactions for select to authenticated
  using (user_id = auth.uid()
    or (user_id in (select p.partner_id from public.profiles p where p.id = auth.uid())
        and (is_shared or public.is_joint_account(account_id) or public.is_joint_account(to_account_id))));

select tablename, policyname, permissive, roles::text, left(qual, 90) as uvjet
from pg_policies where tablename in ('accounts', 'transactions') order by 1, 2;
