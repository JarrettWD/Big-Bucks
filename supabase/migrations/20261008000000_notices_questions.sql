-- Stage 7 part 2b: the notices list and her questions, with dates worked out here
-- (Alberta dates, from the pinned rule), so the browser never turns a time into a
-- date itself. Reads only.
--
--   my_notices(account, limit, before_id)   her notices, newest first, each with its date
--   my_questions(account)                   her questions to Dad ("Something looks wrong?"),
--                                           newest first, with Dad's answer and both dates

create function public.my_notices(p_account_id uuid, p_limit integer default 50, p_before_id bigint default null)
returns table (id bigint, type public.notification_type, title text, body text, on_day date, is_new boolean,
               related_gic_id bigint, related_request_id bigint)
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  return query
  select n.id, n.type, n.title, n.body, public.edmonton_local(n.created_at)::date, n.read_at is null,
         n.related_gic_id, n.related_request_id
    from public.notifications n
   where n.account_id = p_account_id
     and (p_before_id is null or n.id < p_before_id)
   order by n.id desc
   limit least(greatest(coalesce(p_limit, 50), 1), 200);
end;
$$;

comment on function public.my_notices(uuid, integer, bigint) is
  'Her notices, newest first, with each one''s Alberta date and whether it''s new (unread).';

create function public.my_questions(p_account_id uuid)
returns table (id bigint, transaction_id bigint, message text, reply text, answered boolean,
               asked_on date, answered_on date)
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if p_account_id is null or not coalesce(public.can_read_account(p_account_id), false) then
    raise exception 'You can only see your own account.' using errcode = '42501';
  end if;
  return query
  select q.id, q.transaction_id, q.message, q.parent_reply, q.status = 'answered',
         public.edmonton_local(q.created_at)::date,
         public.edmonton_local(q.answered_at)::date
    from public.questions q
   where q.account_id = p_account_id
   order by q.id desc;
end;
$$;

comment on function public.my_questions(uuid) is
  'Her questions to Dad, newest first: the line they''re about, Dad''s answer, and the Alberta dates.';

revoke all on function public.my_notices(uuid, integer, bigint) from public, anon, authenticated, service_role;
revoke all on function public.my_questions(uuid) from public, anon, authenticated, service_role;
grant execute on function public.my_notices(uuid, integer, bigint) to authenticated, service_role;
grant execute on function public.my_questions(uuid) to authenticated, service_role;
