-- Stage 1: helper functions used by RLS policies and, later, by every money function.
--
-- They are SECURITY DEFINER so they can read profiles and settings without
-- tripping over RLS (a policy on profiles that called a function reading
-- profiles would otherwise recurse).

-- The calling kid's account, or null for a parent or an anonymous caller.
create function public.my_account_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select p.account_id
    from public.profiles p
   where p.user_id = auth.uid();
$$;

comment on function public.my_account_id() is
  'The signed-in kid''s account id; null for a parent or anyone else.';

-- True only for a parent who has passed the second factor (aal2). A parent
-- signed in with a password alone is not treated as a parent.
create function public.is_parent()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (select p.role = 'parent'
       from public.profiles p
      where p.user_id = auth.uid())
    and coalesce(auth.jwt() ->> 'aal', '') = 'aal2',
    false);
$$;

comment on function public.is_parent() is
  'True when the caller is a parent signed in with MFA (aal2).';

-- Is a feature switched on for this account today? The switch is the settings
-- key 'feature:<name>', using the newest row effective on or before app_today():
--   off       nobody (also the answer when there is no row, or an unknown value)
--   test      test accounts only
--   everyone  every account
-- A kid may only ask about her own account.
create function public.feature_enabled(p_feature text, p_account_id uuid)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_value text;
begin
  if auth.uid() is not null
     and not public.is_parent()
     and p_account_id is distinct from public.my_account_id() then
    raise exception 'You can only check features for your own account.'
      using errcode = '42501';
  end if;

  select btrim(s.value) into v_value
    from public.settings s
   where s.key = 'feature:' || p_feature
     and s.effective_date <= public.app_today()
   order by s.effective_date desc, s.id desc
   limit 1;

  return case v_value
    when 'everyone' then true
    when 'test' then coalesce(
      (select a.is_test from public.accounts a where a.id = p_account_id), false)
    else false
  end;
end;
$$;

comment on function public.feature_enabled(text, uuid) is
  'Feature switch for an account today: off, test (test accounts only) or everyone.';

revoke all on function public.my_account_id() from public, anon;
revoke all on function public.is_parent() from public, anon;
revoke all on function public.feature_enabled(text, uuid) from public, anon;
grant execute on function public.my_account_id() to authenticated, service_role;
grant execute on function public.is_parent() to authenticated, service_role;
grant execute on function public.feature_enabled(text, uuid) to authenticated, service_role;
