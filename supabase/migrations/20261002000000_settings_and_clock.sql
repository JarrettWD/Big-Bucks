-- Stage 0: the settings table and the app clock.
--
-- settings holds dated, admin-editable values (deposit cap, inflation rate,
-- feature switches, ...). Like the ledger it is append-only: a change is a new
-- row, never an edit. For most keys the value in force on a date is the newest
-- row effective on or before that date. Two keys are special: is_local_dev and
-- clock_override always use the newest row (highest id), whatever its
-- effective_date, because they describe the environment, not a dated rule.
--
-- app_now() and app_today() are the only clock money logic may use. In local
-- development (newest is_local_dev row = 'true') a non-empty clock_override
-- freezes the clock at that Edmonton date and time, for the time machine.
-- Everywhere else they return the real time.

create table public.settings (
  id             bigint generated always as identity primary key,
  key            text not null check (btrim(key) <> ''),
  value          text not null,
  effective_date date not null,
  note           text,
  changed_by     uuid,
  created_at     timestamptz not null default now()
);

comment on table public.settings is
  'Append-only, dated app settings. Change a value by inserting a new row.';

create index settings_key_id_idx on public.settings (key, id desc);

-- Append-only enforcement, reusable by the ledger and rates tables later.
create function public.reject_append_only_change()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  raise exception '% is append-only: % is not allowed. Add a new row instead.',
    tg_table_name, lower(tg_op)
    using errcode = 'P0001';
end;
$$;

create trigger settings_no_update_delete
  before update or delete on public.settings
  for each row execute function public.reject_append_only_change();

create trigger settings_no_truncate
  before truncate on public.settings
  for each statement execute function public.reject_append_only_change();

-- The clock.
create function public.app_now()
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_local_dev text;
  v_override  text;
begin
  select s.value into v_local_dev
    from public.settings s
   where s.key = 'is_local_dev'
   order by s.id desc
   limit 1;

  if v_local_dev is distinct from 'true' then
    return now();
  end if;

  select btrim(s.value) into v_override
    from public.settings s
   where s.key = 'clock_override'
   order by s.id desc
   limit 1;

  if v_override is null or v_override = '' then
    return now();
  end if;

  if v_override !~ '^\d{4}-\d{2}-\d{2}( \d{2}:\d{2}(:\d{2})?)?$' then
    raise exception 'clock_override "%" is not a valid Edmonton date and time. Use YYYY-MM-DD HH:MI, or an empty value to clear it.',
      v_override;
  end if;

  return v_override::timestamp at time zone 'America/Edmonton';
end;
$$;

comment on function public.app_now() is
  'The app''s current time. Honours clock_override only when is_local_dev is true.';

create function public.app_today()
returns date
language sql
stable
set search_path = ''
as $$
  select (public.app_now() at time zone 'America/Edmonton')::date;
$$;

comment on function public.app_today() is
  'Today''s date in America/Edmonton, from app_now().';

alter table public.settings alter column effective_date set default public.app_today();

-- Security: RLS on, no policies yet (stage 1 adds reads). Nobody but the
-- database owner writes here directly; stage 1 adds the parent's settings
-- function, which must refuse to change is_local_dev or clock_override.
alter table public.settings enable row level security;

revoke all on public.settings from public, anon, authenticated, service_role;
grant select on public.settings to service_role;

revoke all on function public.reject_append_only_change() from public, anon, authenticated, service_role;
revoke all on function public.app_now() from public, anon;
revoke all on function public.app_today() from public, anon;
grant execute on function public.app_now() to authenticated, service_role;
grant execute on function public.app_today() to authenticated, service_role;

-- Production default. Only supabase/seed.sql (local only) sets this to true.
insert into public.settings (key, value, effective_date, note)
values ('is_local_dev', 'false', date '2026-10-02',
        'Production default. The time machine works only when this is true, which only the local seed sets.');
