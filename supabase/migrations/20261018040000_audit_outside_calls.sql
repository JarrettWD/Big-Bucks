-- Stage 4, step 1: fixes from the pre-launch audit (2026-10-08). One door to the
-- outside world.
--
-- Stage 4 adds the first things that reach outside the database (alert emails,
-- the health check). A preview runs the real action and rolls it back, but a
-- rollback can't take back an email. So nothing in the database calls out
-- directly. Anything meant for the outside is queued with queue_outside(), which
-- does nothing while in_preview() is on, and lands in public.outbox. A sender
-- (stage 4: pg_cron, outside any preview) delivers what's queued after the
-- transaction that queued it has committed. A rolled-back preview's queue entry
-- never existed, and the in_preview() check stops it even before that.
--
-- supabase/tests/parent_approvals_test.sql enforces the rule: no function we own
-- (in any schema) may call pg_net, the http extension, dblink or an Edge
-- Function, except the named sender, and that sender must check in_preview();
-- no database webhooks; no dynamic SQL that could build such a call; no pg_cron
-- job calling out except through the sender; and queue_outside() is tested by
-- what it does, not by its text.

create table public.outbox (
  id          bigint generated always as identity primary key,
  kind        text not null check (kind in ('email', 'push', 'http')),
  payload     jsonb not null,
  created_at  timestamptz not null default public.app_now(),
  sent_at     timestamptz,
  attempts    integer not null default 0 check (attempts >= 0),
  last_error  text
);
comment on table public.outbox is
  'Messages for the outside world (email, push, HTTP), queued inside a transaction and sent after it commits. Server only.';
create index outbox_unsent_idx on public.outbox (id) where sent_at is null;
alter table public.outbox enable row level security;
create policy outbox_read on public.outbox for select to authenticated using ((select public.is_parent()));
revoke all on public.outbox from public, anon, authenticated, service_role;
grant select on public.outbox to authenticated, service_role;

-- The one way to send anything outside. In a preview, nothing is queued.
create function public.queue_outside(p_kind text, p_payload jsonb)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id bigint;
begin
  if public.in_preview() then
    return null;
  end if;
  insert into public.outbox (kind, payload) values (p_kind, coalesce(p_payload, '{}'::jsonb))
  returning id into v_id;
  return v_id;
end;
$$;
comment on function public.queue_outside(text, jsonb) is
  'Queues a message for the outside world. Does nothing in a preview (in_preview()). The only door out.';

revoke all on function public.queue_outside(text, jsonb) from public, anon, authenticated, service_role;
