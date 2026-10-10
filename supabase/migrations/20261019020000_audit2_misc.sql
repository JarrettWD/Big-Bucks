-- Stage 4, step 1, second round (second audit, 2026-10-08). The seed's production
-- guard becomes a function, so a test can prove it: supabase/seed.sql calls
-- assert_not_production() before it switches the time machine on.

create function public.assert_not_production()
returns void
language plpgsql
stable
set search_path = ''
as $$
begin
  if exists (select 1 from public.settings where key = 'is_production') then
    raise exception 'This database is production. The local seed never runs here.';
  end if;
end;
$$;
comment on function public.assert_not_production() is
  'Refuses on a database marked as production (mark_production). The local seed calls it first.';

revoke all on function public.assert_not_production() from public, anon, authenticated, service_role;
