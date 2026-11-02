-- Financije v11 – popravak: partner vidi zajedničke račune
-- pomoćna funkcija (ponovno postavljena, za svaki slučaj)
create or replace function public.my_partner() returns uuid
language sql stable security definer set search_path = public as $$
  select partner_id from public.profiles where id = auth.uid()
$$;
grant execute on function public.my_partner() to authenticated;

drop policy if exists accounts_partner_select on public.accounts;
create policy accounts_partner_select on public.accounts for select to authenticated
  using (shared and user_id in (select p.partner_id from public.profiles p where p.id = auth.uid()));

-- provjera: što baza vraća Hani (ništa se ne mijenja, rollback na kraju)
begin;
select set_config('request.jwt.claims',
  json_build_object('sub', (select id from profiles where display_name = 'Hana Pospiš'), 'role', 'authenticated')::text, true);
set local role authenticated;
select (select display_name from profiles where id = public.my_partner()) as partner_preko_funkcije,
       name, shared,
       (select display_name from profiles p where p.id = accounts.user_id) as vlasnik
from accounts;
rollback;
