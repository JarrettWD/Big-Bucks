-- Stage 9: the Wish List and goals (plan approved by Dad 2026-10-16: photos in the
-- database (A1), one goal at a time (B1), the projected date from her total worth at
-- today's regular savings rate, shown only within 5 years (C1)).
--
-- Nothing here moves money. The wish list reads her total worth (account_balances)
-- and today's regular savings rate; it never writes to the ledger, rates or settings,
-- and nothing reaches outside the database. Everything is behind feature:wishlist.
--
-- Kids write only through the wish_* functions below, each checking that she is a
-- kid, that the item is hers, and that the Wish List is switched on for her. The
-- parent-only "Got it" marker stays in wishlist_parent_marks, which kids can't read
-- and no kid function reads.

-- 1. Tables ------------------------------------------------------------------------------------------

-- Nothing ever wrote photo_url (no wish list functions existed), and photos now live
-- in wishlist_photos.
alter table public.wishlist_items drop column photo_url;

-- The Alberta day her 7 days count from: the day she added it, or the day she renamed it.
alter table public.wishlist_items
  add column wait_from date not null default public.app_today(),
  add constraint wishlist_items_name_length check (length(name) <= 60),
  add constraint wishlist_items_price_range check (price_cents between 100 and 10000000),
  add constraint wishlist_items_link_shape check (
    link is null or (length(link) <= 500 and link ~* '^https?://[^/?#[:space:]]+'));
comment on column public.wishlist_items.wait_from is
  'The Alberta day the 7-day wait counts from (added, or renamed). A goal from wait_from + 7.';

-- At most one goal at a time (Dad, 2026-10-16).
create unique index wishlist_items_one_goal on public.wishlist_items (account_id) where status = 'goal';

-- Goals are kept when they end, saying how.
alter table public.goals
  add column ended_at timestamptz,
  add column ended_how text check (ended_how in ('switched', 'stopped', 'got_it', 'removed')),
  add constraint goals_ended_how check ((ended_at is null) = (ended_how is null));
create unique index goals_one_open on public.goals (account_id) where ended_at is null;

-- Her photos, one per item: the photo (at most 150 KB) and a small thumbnail for the
-- list (at most 20 KB), both JPEG, both shrunk on her phone first. Kept in the
-- database so the backup, the Download zip, the pre-launch reset and the restore
-- drill all cover them like any other table (Storage stays unused).
create table public.wishlist_photos (
  wishlist_item_id uuid primary key references public.wishlist_items (id),
  account_id       uuid not null references public.accounts (id),
  photo            bytea not null check (octet_length(photo) between 100 and 153600),
  thumb            bytea not null check (octet_length(thumb) between 100 and 20480),
  added_at         timestamptz not null default public.app_now(),
  constraint wishlist_photos_jpeg check (substring(photo from 1 for 3) = '\xffd8ff'::bytea
                                         and substring(thumb from 1 for 3) = '\xffd8ff'::bytea)
);
create index wishlist_photos_account_idx on public.wishlist_photos (account_id);
alter table public.wishlist_photos enable row level security;
grant select on public.wishlist_photos to authenticated, service_role;
create policy wishlist_photos_read on public.wishlist_photos for select to authenticated
  using (account_id = (select public.my_account_id()) or (select public.is_parent()));

alter table public.parent_actions drop constraint parent_actions_action_check;
alter table public.parent_actions add constraint parent_actions_action_check
  check (action in ('approve_request', 'decline_request', 'answer_question', 'acknowledge_alert',
                    'add_rate', 'set_setting', 'edit_note', 'edit_glossary', 'cancel_change',
                    'correct_savings', 'countersign_agreement', 'correct_fund_price', 'record_market_closure',
                    'reset_kid_pin', 'record_early_close', 'download_backup', 'wishlist_mark'));

-- 2. Helpers (the database only) ---------------------------------------------------------------------

-- The calling kid's account, when the Wish List is on for her.
create function public.wish_kid()
returns uuid
language plpgsql
set search_path = ''
as $$
declare
  v_acct uuid := public.kid_account();
begin
  if not public.feature_enabled('wishlist', v_acct) then
    raise exception 'The Wish List isn''t switched on for you yet.' using errcode = '42501';
  end if;
  return v_acct;
end;
$$;

-- One of her items, locked. p_active: refused once it's in her Done list.
create function public.wish_item(p_acct uuid, p_item uuid, p_active boolean)
returns public.wishlist_items
language plpgsql
set search_path = ''
as $$
declare
  v public.wishlist_items;
begin
  select * into v from public.wishlist_items w where w.id = p_item for update;
  if not found or v.account_id is distinct from p_acct then
    raise exception 'That isn''t on your wish list.' using errcode = '42501';
  end if;
  if p_active and v.status not in ('wanted', 'goal') then
    raise exception 'That''s in your Done list now.';
  end if;
  return v;
end;
$$;

-- What she typed, checked. Returns the trimmed name.
create function public.wish_check(p_name text, p_price_cents bigint, p_stars integer)
returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v_name text := btrim(coalesce(p_name, ''));
begin
  if v_name = '' then
    raise exception 'Give your wish a name.';
  end if;
  if length(v_name) > 60 then
    raise exception 'Keep the name to 60 letters or fewer.';
  end if;
  if p_price_cents is not null and p_price_cents < 100 then
    raise exception 'A rough price needs to be at least $1.00.';
  end if;
  if p_price_cents > 10000000 then
    raise exception 'A rough price can be at most $100,000.00.';
  end if;
  if p_stars is null or p_stars not between 1 and 5 then
    raise exception 'Pick 1 to 5 stars.';
  end if;
  return v_name;
end;
$$;

-- A link she pasted: kept exactly as pasted, or refused. Only web links, with no
-- spaces or hidden characters (which can disguise where a link really goes). The
-- app shows only the site's name and never opens or previews the link itself.
create function public.wish_clean_link(p_link text)
returns text
language plpgsql immutable
set search_path = ''
as $$
declare
  v text := btrim(coalesce(p_link, ''));
begin
  if v = '' then
    return null;
  end if;
  if v ~ '[[:cntrl:]]' or v ~ '[­؜᠎​-‏‪-‮⁠-⁤⁦-⁯﻿]' then
    raise exception 'That link has a hidden character in it. Copy it again from the shop''s page.';
  end if;
  if v ~ '[[:space:]]' then
    raise exception 'That link has a space in it. Copy it again from the shop''s page.';
  end if;
  if v !~* '^https?://[^/?#]+' then
    raise exception 'A link needs to start with https:// or http://';
  end if;
  if length(v) > 500 then
    raise exception 'That link is too long (more than 500 letters).';
  end if;
  return v;
end;
$$;

-- "You're 40% of the way there": rounded DOWN, so 100% only when she really has enough.
create function public.wish_percent(p_worth bigint, p_price bigint)
returns integer
language sql immutable
set search_path = ''
as $$
  select case when p_price is null or p_price <= 0 then null
              else least(100, greatest(0, (p_worth * 100) / p_price))::integer end;
$$;

-- The savings rate the projection uses: the regular rate in force on the day,
-- ignoring specials (they end) and cancelled changes.
create function public.wish_savings_rate(p_day date)
returns numeric
language sql stable
set search_path = ''
as $$
  select r.rate
    from public.rates r
   where r.vehicle = 'savings' and r.gic_term is null and not r.is_special
     and r.effective_date <= p_day and not public.is_cancelled_rate(r.id)
   order by r.effective_date desc, r.id desc
   limit 1;
$$;

-- Roughly when she could afford it if her whole total worth grew at the savings rate,
-- compounding monthly like the real interest, adding nothing. A guess, never a promise:
-- months = 0 when she already has enough; no answer at all past 5 years (60 months),
-- with nothing saved, or at 0%. It's worked out each time, never stored.
create function public.wish_projection(p_worth bigint, p_price bigint, p_rate numeric, p_today date,
                                       out months integer, out around text)
language plpgsql immutable
set search_path = ''
as $$
declare
  v numeric;
begin
  if p_price is null then
    return;
  end if;
  if p_worth >= p_price then
    months := 0;
    return;
  end if;
  if p_worth <= 0 or p_rate is null or p_rate <= 0 then
    return;
  end if;
  v := ceil(ln(p_price::numeric / p_worth) / ln(1 + p_rate / 1200));
  if v > 60 then
    return;
  end if;
  months := v::integer;
  around := to_char(p_today + make_interval(months => months), 'FMMonth YYYY');
end;
$$;

-- Her funds are worth less than a week ago, from prices alone (the same units at
-- today's close and at the close a week earlier), so progress went down without her
-- doing anything. The screens then say so, gently.
create function public.wish_funds_dipped(p_acct uuid, p_today date)
returns boolean
language sql stable
set search_path = ''
as $$
  select coalesce(sum(u.units * (n.close - w.close)) < 0, false)
    from (select t.fund_id, sum(t.units) as units
            from public.transactions t
           where t.account_id = p_acct and t.vehicle = 'stock'
           group by t.fund_id
          having sum(t.units) > 0) u
    cross join lateral (select fp.close from public.fund_prices fp
                         where fp.fund_id = u.fund_id and fp.price_date <= p_today
                         order by fp.price_date desc limit 1) n
    cross join lateral (select fp.close from public.fund_prices fp
                         where fp.fund_id = u.fund_id and fp.price_date <= p_today - 7
                         order by fp.price_date desc limit 1) w;
$$;

-- Her wish list as the screens show it. Never the photo bytes (each photo is loaded on
-- its own with wish_photo). p_marks: the parent's view, with the "Got it" marker.
create function public.wish_list_json(p_acct uuid, p_marks boolean)
returns jsonb
language plpgsql stable
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_worth bigint := coalesce((select b.total_worth_cents from public.account_balances b where b.account_id = p_acct), 0);
  v_rate numeric := public.wish_savings_rate(v_today);
begin
  return jsonb_build_object(
    'today', v_today,
    'worth_cents', v_worth,
    'rate', v_rate,
    'funds_dipped', public.wish_funds_dipped(p_acct, v_today),
    'photos_used', (select count(*) from public.wishlist_photos p where p.account_id = p_acct),
    'photos_max', 30,
    'items', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'id', w.id, 'name', w.name, 'price_cents', w.price_cents, 'link', w.link, 'stars', w.stars,
                 'status', w.status, 'has_photo', p.added_at is not null, 'photo_at', p.added_at,
                 'added_on', w.wait_from, 'goal_from', to_char(w.wait_from + 7, 'Dy Mon FMDD'),
                 'can_goal', w.status = 'wanted' and v_today >= w.wait_from + 7,
                 'percent', public.wish_percent(v_worth, w.price_cents),
                 'enough', w.price_cents is not null and v_worth >= w.price_cents,
                 'months', pr.months, 'around', pr.around)
               || case when p_marks then jsonb_build_object(
                    'marked', m.wishlist_item_id is not null, 'mark_note', m.note,
                    'marked_on', public.edmonton_local(m.marked_at)::date) else '{}'::jsonb end
               order by w.sort_order, w.created_at, w.id)
        from public.wishlist_items w
        left join public.wishlist_photos p on p.wishlist_item_id = w.id
        left join public.wishlist_parent_marks m on p_marks and m.wishlist_item_id = w.id
        cross join lateral public.wish_projection(v_worth, w.price_cents, v_rate, v_today) pr
       where w.account_id = p_acct and w.status in ('wanted', 'goal')), '[]'::jsonb),
    'done', coalesce((
      select jsonb_agg(
               jsonb_build_object(
                 'id', w.id, 'name', w.name, 'price_cents', w.price_cents, 'link', w.link, 'stars', w.stars,
                 'status', w.status, 'has_photo', p.added_at is not null, 'photo_at', p.added_at,
                 'done_on', public.edmonton_local(w.status_changed_at)::date)
               || case when p_marks then jsonb_build_object(
                    'marked', m.wishlist_item_id is not null, 'mark_note', m.note,
                    'marked_on', public.edmonton_local(m.marked_at)::date) else '{}'::jsonb end
               order by w.status_changed_at desc, w.id)
        from public.wishlist_items w
        left join public.wishlist_photos p on p.wishlist_item_id = w.id
        left join public.wishlist_parent_marks m on p_marks and m.wishlist_item_id = w.id
       where w.account_id = p_acct and w.status in ('got_it', 'removed')), '[]'::jsonb));
end;
$$;

-- Ends her open goal, saying how; the item goes back to her list unless it's done.
create function public.wish_end_goal(p_acct uuid, p_how text)
returns void
language plpgsql
set search_path = ''
as $$
begin
  update public.goals g set ended_at = public.app_now(), ended_how = p_how
   where g.account_id = p_acct and g.ended_at is null;
  update public.wishlist_items w set status = 'wanted', status_changed_at = public.app_now()
   where w.account_id = p_acct and w.status = 'goal';
end;
$$;

-- 3. What she reads -----------------------------------------------------------------------------------

create function public.kid_wishlist(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  if p_account_id is null or p_account_id is distinct from public.my_account_id() then
    raise exception 'You can only see your own wish list.' using errcode = '42501';
  end if;
  if not public.feature_enabled('wishlist', p_account_id) then
    raise exception 'The Wish List isn''t switched on for you yet.' using errcode = '42501';
  end if;
  return public.wish_list_json(p_account_id, false);
end;
$$;

-- Her goal, for Home's card (also in Dad's "View as"). Null with no goal, or while
-- the Wish List is off for her.
create function public.kid_goal(p_account_id uuid)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_today date := public.app_today();
  v_worth bigint;
  v_rate numeric;
  w public.wishlist_items;
  pr record;
begin
  if p_account_id is null
     or (p_account_id is distinct from public.my_account_id() and not public.is_parent()) then
    raise exception 'You can only see your own wish list.' using errcode = '42501';
  end if;
  if not public.feature_enabled('wishlist', p_account_id) then
    return null;
  end if;
  select * into w from public.wishlist_items x where x.account_id = p_account_id and x.status = 'goal';
  if not found then
    return null;
  end if;
  v_worth := coalesce((select b.total_worth_cents from public.account_balances b where b.account_id = p_account_id), 0);
  v_rate := public.wish_savings_rate(v_today);
  select * into pr from public.wish_projection(v_worth, w.price_cents, v_rate, v_today);
  return jsonb_build_object(
    'id', w.id, 'name', w.name, 'price_cents', w.price_cents, 'worth_cents', v_worth,
    'has_photo', exists (select 1 from public.wishlist_photos p where p.wishlist_item_id = w.id),
    'photo_at', (select p.added_at from public.wishlist_photos p where p.wishlist_item_id = w.id),
    'percent', public.wish_percent(v_worth, w.price_cents),
    'enough', v_worth >= w.price_cents,
    'months', pr.months, 'around', pr.around,
    'funds_dipped', public.wish_funds_dipped(p_account_id, v_today));
end;
$$;

-- One photo, as base64: the thumbnail for lists, the full photo when she opens it.
-- Her own, or any for the parent.
create function public.wish_photo(p_item uuid, p_size text default 'thumb')
returns text
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_acct uuid;
  v bytea;
begin
  if p_size is null or p_size not in ('thumb', 'full') then
    raise exception 'Ask for the "thumb" or the "full" photo.';
  end if;
  select w.account_id into v_acct from public.wishlist_items w where w.id = p_item;
  if v_acct is null or (v_acct is distinct from public.my_account_id() and not public.is_parent()) then
    raise exception 'That photo isn''t yours to see.' using errcode = '42501';
  end if;
  select case p_size when 'full' then p.photo else p.thumb end into v
    from public.wishlist_photos p where p.wishlist_item_id = p_item;
  return replace(encode(v, 'base64'), E'\n', '');
end;
$$;

-- 4. What she does --------------------------------------------------------------------------------------

create function public.wish_add(p_name text, p_price_cents bigint default null, p_link text default null,
                                p_stars integer default 3)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct uuid := public.wish_kid();
  v_name text := public.wish_check(p_name, p_price_cents, p_stars);
  v_link text := public.wish_clean_link(p_link);
  v_id uuid;
begin
  if (select count(*) from public.wishlist_items w
       where w.account_id = v_acct and w.status in ('wanted', 'goal')) >= 50 then
    raise exception 'Your list is full (50 things). Remove one first.';
  end if;
  insert into public.wishlist_items (account_id, name, price_cents, link, stars, sort_order, wait_from)
  values (v_acct, v_name, p_price_cents, v_link, p_stars,
          coalesce((select max(w.sort_order) from public.wishlist_items w
                     where w.account_id = v_acct and w.status in ('wanted', 'goal')), 0) + 1,
          public.app_today())
  returning id into v_id;
  return v_id;
end;
$$;

-- A new name starts the 7 days again (so a wish can't turn into a new impulse on day 8);
-- the price, link and stars can change freely. A goal keeps its name.
create function public.wish_update(p_item uuid, p_name text, p_price_cents bigint, p_link text, p_stars integer)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct uuid := public.wish_kid();
  v public.wishlist_items := public.wish_item(v_acct, p_item, true);
  v_name text := public.wish_check(p_name, p_price_cents, p_stars);
  v_link text := public.wish_clean_link(p_link);
  v_renamed boolean := v_name is distinct from v.name;
begin
  if v_renamed and v.status = 'goal' then
    raise exception 'Stop saving for this goal first if you want to change its name.';
  end if;
  if v.status = 'goal' and p_price_cents is null then
    raise exception 'A goal needs a rough price.';
  end if;
  update public.wishlist_items w
     set name = v_name, price_cents = p_price_cents, link = v_link, stars = p_stars,
         wait_from = case when v_renamed then public.app_today() else w.wait_from end
   where w.id = v.id;
  if v.status = 'goal' then
    update public.goals g set target_cents = p_price_cents
     where g.account_id = v_acct and g.ended_at is null;
  end if;
end;
$$;

create function public.wish_set_photo(p_item uuid, p_photo text, p_thumb text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct uuid := public.wish_kid();
  v public.wishlist_items := public.wish_item(v_acct, p_item, true);
  v_photo bytea;
  v_thumb bytea;
begin
  begin
    v_photo := decode(p_photo, 'base64');
    v_thumb := decode(p_thumb, 'base64');
  exception when others then
    raise exception 'That photo didn''t work. Try another one or a screenshot.';
  end;
  if octet_length(v_photo) > 153600 or octet_length(v_thumb) > 20480 then
    raise exception 'That photo is too big. Try another one.';
  end if;
  if v_photo is null or v_thumb is null or octet_length(v_photo) < 100 or octet_length(v_thumb) < 100
     or substring(v_photo from 1 for 3) <> '\xffd8ff'::bytea or substring(v_thumb from 1 for 3) <> '\xffd8ff'::bytea then
    raise exception 'That photo didn''t work. Try another one or a screenshot.';
  end if;
  if (select count(*) from public.wishlist_photos p
       where p.account_id = v_acct and p.wishlist_item_id <> v.id) >= 30 then
    raise exception 'You''ve used all 30 photo spots. Remove a photo first.';
  end if;
  insert into public.wishlist_photos (wishlist_item_id, account_id, photo, thumb, added_at)
  values (v.id, v_acct, v_photo, v_thumb, public.app_now())
  on conflict (wishlist_item_id) do update
    set photo = excluded.photo, thumb = excluded.thumb, added_at = excluded.added_at;
end;
$$;

-- Also for an item in her Done list.
create function public.wish_remove_photo(p_item uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct uuid := public.wish_kid();
  v public.wishlist_items := public.wish_item(v_acct, p_item, false);
begin
  delete from public.wishlist_photos p where p.wishlist_item_id = v.id;
end;
$$;

-- Her whole list (not the Done list), in her new order.
create function public.wish_reorder(p_items uuid[])
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct uuid := public.wish_kid();
begin
  perform 1 from public.wishlist_items w
   where w.account_id = v_acct and w.status in ('wanted', 'goal') for update;
  if p_items is null
     or cardinality(p_items) <> (select count(distinct x) from unnest(p_items) x)
     or array(select x from unnest(p_items) x order by x)
        is distinct from array(select w.id from public.wishlist_items w
                                where w.account_id = v_acct and w.status in ('wanted', 'goal') order by w.id) then
    raise exception 'Your list changed. Please try again.';
  end if;
  update public.wishlist_items w set sort_order = o.n
    from unnest(p_items) with ordinality o(id, n)
   where w.id = o.id;
end;
$$;

-- "I got this" or "Remove": into her Done list (never deleted). A goal ends with it.
create function public.wish_done(p_item uuid, p_how text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct uuid := public.wish_kid();
  v public.wishlist_items := public.wish_item(v_acct, p_item, true);
begin
  if p_how is null or p_how not in ('got_it', 'removed') then
    raise exception 'Pick "I got this" or "Remove".';
  end if;
  if v.status = 'goal' then
    update public.goals g set ended_at = public.app_now(), ended_how = p_how
     where g.account_id = v_acct and g.ended_at is null;
  end if;
  update public.wishlist_items w
     set status = p_how::public.wishlist_status, status_changed_at = public.app_now()
   where w.id = v.id;
end;
$$;

-- "Still want this?" Yes: a wish becomes her goal, from 7 days after she added (or
-- renamed) it, and only with a price. One goal at a time: p_switch swaps them.
create function public.wish_make_goal(p_item uuid, p_switch boolean default false)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct uuid := public.wish_kid();
  v public.wishlist_items := public.wish_item(v_acct, p_item, true);
  v_goal text;
begin
  if v.status = 'goal' then
    raise exception 'That''s already your goal.';
  end if;
  if public.app_today() < v.wait_from + 7 then
    raise exception 'Still want this? You can make it a goal from %.', to_char(v.wait_from + 7, 'Dy Mon FMDD');
  end if;
  if v.price_cents is null then
    raise exception 'Add a rough price first, so you can see how close you are.';
  end if;
  select g.name into v_goal from public.goals g where g.account_id = v_acct and g.ended_at is null;
  if v_goal is not null then
    if not coalesce(p_switch, false) then
      raise exception 'You''re already saving for %. Switch your goal?', v_goal;
    end if;
    perform public.wish_end_goal(v_acct, 'switched');
  end if;
  update public.wishlist_items w set status = 'goal', status_changed_at = public.app_now() where w.id = v.id;
  insert into public.goals (account_id, name, target_cents, wishlist_item_id)
  values (v_acct, v.name, v.price_cents, v.id);
end;
$$;

create function public.wish_stop_goal()
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_acct uuid := public.wish_kid();
begin
  if not exists (select 1 from public.goals g where g.account_id = v_acct and g.ended_at is null) then
    raise exception 'You don''t have a goal right now.';
  end if;
  perform public.wish_end_goal(v_acct, 'stopped');
end;
$$;

-- 5. The parent ---------------------------------------------------------------------------------------

-- Every kid's wish list and Done list, with the "Got it" marker. Real kids first.
create function public.parent_wishlists()
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
begin
  perform public.require_parent();
  return coalesce((
    select jsonb_agg(jsonb_build_object('account_id', a.id, 'name', a.name, 'is_test', a.is_test,
                                        'enabled', public.feature_enabled('wishlist', a.id))
                     || public.wish_list_json(a.id, true)
                     order by a.is_test, a.name, a.id)
      from public.accounts a), '[]'::jsonb);
end;
$$;

-- Quietly mark an item as bought ("Got it"), or clear the mark. Kids never see it.
create function public.parent_wishlist_mark(p_item uuid, p_got_it boolean, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v public.wishlist_items;
  v_kid text;
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
begin
  perform public.require_parent();
  select * into v from public.wishlist_items w where w.id = p_item for update;
  if not found then
    raise exception 'There''s no such wish.';
  end if;
  if length(v_note) > 200 then
    raise exception 'Keep the note to 200 letters or fewer.';
  end if;
  select a.name into v_kid from public.accounts a where a.id = v.account_id;
  if coalesce(p_got_it, false) then
    insert into public.wishlist_parent_marks (wishlist_item_id, marked_by, marked_at, note)
    values (v.id, auth.uid(), public.app_now(), v_note)
    on conflict (wishlist_item_id) do update
      set marked_by = excluded.marked_by, marked_at = excluded.marked_at, note = excluded.note;
    perform public.log_parent_action('wishlist_mark', v.account_id, null,
      'Marked ' || v_kid || '''s "' || v.name || '" as Got it.',
      jsonb_build_object('item', v.id, 'got_it', true, 'note', v_note));
  else
    delete from public.wishlist_parent_marks m where m.wishlist_item_id = v.id;
    perform public.log_parent_action('wishlist_mark', v.account_id, null,
      'Cleared Got it on ' || v_kid || '''s "' || v.name || '".',
      jsonb_build_object('item', v.id, 'got_it', false));
  end if;
end;
$$;

-- 6. The pre-launch reset clears photos too --------------------------------------------------------------

create or replace function private.prelaunch_tables()
returns text[]
language sql
immutable
set search_path = ''
as $$
  select array['public.transactions', 'public.interest_accruals', 'public.gic_holdings', 'public.requests',
               'public.notifications', 'public.questions', 'public.goals', 'public.badges',
               'public.wishlist_items', 'public.wishlist_parent_marks', 'public.wishlist_photos',
               'public.agreement_signatures', 'public.whats_new_seen', 'public.alerts', 'public.login_attempts',
               'public.outbox', 'private.kid_pin_resets'];
$$;

-- 7. Who may call them ------------------------------------------------------------------------------------

revoke all on function public.wish_kid() from public, anon, authenticated, service_role;
revoke all on function public.wish_item(uuid, uuid, boolean) from public, anon, authenticated, service_role;
revoke all on function public.wish_check(text, bigint, integer) from public, anon, authenticated, service_role;
revoke all on function public.wish_clean_link(text) from public, anon, authenticated, service_role;
revoke all on function public.wish_percent(bigint, bigint) from public, anon, authenticated, service_role;
revoke all on function public.wish_savings_rate(date) from public, anon, authenticated, service_role;
revoke all on function public.wish_projection(bigint, bigint, numeric, date) from public, anon, authenticated, service_role;
revoke all on function public.wish_funds_dipped(uuid, date) from public, anon, authenticated, service_role;
revoke all on function public.wish_list_json(uuid, boolean) from public, anon, authenticated, service_role;
revoke all on function public.wish_end_goal(uuid, text) from public, anon, authenticated, service_role;

revoke all on function public.kid_wishlist(uuid) from public, anon, authenticated, service_role;
revoke all on function public.kid_goal(uuid) from public, anon, authenticated, service_role;
revoke all on function public.wish_photo(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.wish_add(text, bigint, text, integer) from public, anon, authenticated, service_role;
revoke all on function public.wish_update(uuid, text, bigint, text, integer) from public, anon, authenticated, service_role;
revoke all on function public.wish_set_photo(uuid, text, text) from public, anon, authenticated, service_role;
revoke all on function public.wish_remove_photo(uuid) from public, anon, authenticated, service_role;
revoke all on function public.wish_reorder(uuid[]) from public, anon, authenticated, service_role;
revoke all on function public.wish_done(uuid, text) from public, anon, authenticated, service_role;
revoke all on function public.wish_make_goal(uuid, boolean) from public, anon, authenticated, service_role;
revoke all on function public.wish_stop_goal() from public, anon, authenticated, service_role;
revoke all on function public.parent_wishlists() from public, anon, authenticated, service_role;
revoke all on function public.parent_wishlist_mark(uuid, boolean, text) from public, anon, authenticated, service_role;

grant execute on function public.kid_wishlist(uuid) to authenticated;
grant execute on function public.kid_goal(uuid) to authenticated;
grant execute on function public.wish_photo(uuid, text) to authenticated;
grant execute on function public.wish_add(text, bigint, text, integer) to authenticated;
grant execute on function public.wish_update(uuid, text, bigint, text, integer) to authenticated;
grant execute on function public.wish_set_photo(uuid, text, text) to authenticated;
grant execute on function public.wish_remove_photo(uuid) to authenticated;
grant execute on function public.wish_reorder(uuid[]) to authenticated;
grant execute on function public.wish_done(uuid, text) to authenticated;
grant execute on function public.wish_make_goal(uuid, boolean) to authenticated;
grant execute on function public.wish_stop_goal() to authenticated;
grant execute on function public.parent_wishlists() to authenticated;
grant execute on function public.parent_wishlist_mark(uuid, boolean, text) to authenticated;

-- 8. Dad's "View as": her Home's goal card (the same read her app makes) -----------------------------

create or replace function public.parent_view(p_account uuid, p_read text, p_args jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  a jsonb := coalesce(p_args, '{}'::jsonb);
  r jsonb;
begin
  perform public.require_parent();
  if p_account is null or not exists (select 1 from public.accounts x where x.id = p_account) then
    raise exception 'There''s no account to view.';
  end if;

  case p_read
    when 'account' then
      select jsonb_build_object('account_id', x.id, 'name', x.name, 'is_test', x.is_test)
        into r from public.accounts x where x.id = p_account;
    when 'app_today' then
      r := to_jsonb(public.app_today());
    -- Her Home: the same rows her app reads from these views and her notices.
    when 'balances' then
      select to_jsonb(b) into r from public.account_balances b where b.account_id = p_account;
    when 'home_gics' then
      select coalesce(jsonb_agg(to_jsonb(g) order by g.maturity_date, g.gic_id), '[]'::jsonb) into r
        from public.gic_positions g
       where g.account_id = p_account
         and (g.status = 'active' or (g.status = 'matured' and g.maturity_choice is null));
    when 'unread_notices' then
      select coalesce(jsonb_agg(jsonb_build_object('id', n.id, 'type', n.type, 'title', n.title, 'body', n.body,
                                                   'related_gic_id', n.related_gic_id)
                                order by n.created_at desc, n.id desc), '[]'::jsonb) into r
        from public.notifications n where n.account_id = p_account and n.read_at is null;
    when 'unread_count' then
      r := to_jsonb((select count(*) from public.notifications n where n.account_id = p_account and n.read_at is null));
    when 'figures_updating' then
      r := to_jsonb(public.figures_updating(p_account));
    when 'feature_enabled' then
      r := to_jsonb(public.feature_enabled(a ->> 'p_feature', p_account));
    when 'current_rates' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.current_rates() with ordinality t;
    when 'fund_overview' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.fund_overview(p_account) with ordinality t;
    when 'my_activity' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_activity(p_account, coalesce((a ->> 'p_limit')::integer, 20),
                                (a ->> 'p_before_at')::timestamptz, a ->> 'p_before_key') with ordinality t;
    when 'my_notices' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_notices(p_account, coalesce((a ->> 'p_limit')::integer, 50),
                               (a ->> 'p_before_id')::bigint) with ordinality t;
    when 'my_questions' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_questions(p_account) with ordinality t;
    -- B4: her onboarding and her signed agreements.
    when 'onboarding_state' then
      r := public.onboarding_state(p_account);
    when 'my_agreements' then
      r := public.my_agreements(p_account);
    -- Stage 9: her goal card on Home (never the "Got it" marker).
    when 'kid_goal' then
      r := public.kid_goal(p_account);
    -- Her Graphs.
    when 'graph_ranges' then
      r := public.graph_ranges(p_account);
    when 'daily_balances' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.daily_balances(p_account, (a ->> 'p_from')::date, (a ->> 'p_to')::date) with ordinality t;
    when 'growth_by_option' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.growth_by_option(p_account, (a ->> 'p_from')::date, (a ->> 'p_to')::date) with ordinality t;
    when 'money_in_vs_earned' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.money_in_vs_earned(p_account) with ordinality t;
    when 'my_mix' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.my_mix(p_account) with ordinality t;
    when 'gic_ladder' then
      select coalesce(jsonb_agg(to_jsonb(t) - 'ordinality' order by t.ordinality), '[]'::jsonb) into r
        from public.gic_ladder(p_account) with ordinality t;
    when 'fund_chart' then
      r := public.fund_chart(p_account, a ->> 'p_fund_id', (a ->> 'p_from')::date);
    else
      raise exception 'There''s no "%" to view.', p_read;
  end case;
  return r;
end;
$$;
