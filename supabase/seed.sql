-- Local development only. `supabase db reset` and `supabase start` run this
-- file against the LOCAL database. It never runs against production: production
-- receives migrations only (`supabase db push` does not run seeds by default).
--
-- No personal data here, ever.

-- A last guard (pre-launch audit, 2026-10-08): production is marked for good with
-- select public.mark_production(); right after its first migration push, and this
-- file refuses to run on a marked database, so the time machine can't be switched
-- on there by accident (for example by `supabase db push --include-seed`).
-- `supabase db reset --linked` would wipe production completely, mark included:
-- never run it (docs/RUNBOOK.md).
do $$
begin
  if exists (select 1 from public.settings where key = 'is_production') then
    raise exception 'This database is production. The local seed never runs here.';
  end if;
end;
$$;

-- Turn on the time machine for the local copy.
insert into public.settings (key, value, effective_date, note)
values ('is_local_dev', 'true', date '2026-10-02', 'Local development: time machine enabled.');
