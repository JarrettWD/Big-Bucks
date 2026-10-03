-- Local development only. `supabase db reset` and `supabase start` run this
-- file against the LOCAL database. It never runs against production: production
-- receives migrations only (`supabase db push` does not run seeds by default).
--
-- No personal data here, ever.

-- Turn on the time machine for the local copy.
insert into public.settings (key, value, effective_date, note)
values ('is_local_dev', 'true', date '2026-10-02', 'Local development: time machine enabled.');
