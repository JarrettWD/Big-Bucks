-- Stage 9: the Wish List and goals. Known answers for the 7-day rule, the switch,
-- progress and the projected date, photos, the parent-only "Got it" marker and RLS.
-- Nothing here moves money: the wish list only reads her total worth and today's
-- savings rate.
begin;
select plan(162);

create schema tests;
grant usage on schema tests to anon, authenticated, service_role;

create function tests.clock(p_at text) returns void language sql as $$
  insert into public.settings (key, value, effective_date) values ('clock_override', p_at, date '2026-01-01');
$$;
create function tests.as_user(p_user uuid, p_aal text default 'aal1') returns void language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_user, 'role', 'authenticated', 'aal', p_aal)::text, true);
$$;
create function tests.acct(p_username text) returns uuid language sql as $$
  select account_id from public.profiles where username = p_username;
$$;
create function tests.as_kid(p_username text) returns void language sql as $$
  select tests.as_user((select user_id from public.profiles where username = p_username));
$$;
create function tests.as_parent(p_aal text default 'aal2') returns void language sql as $$
  select tests.as_user('00000000-0000-0000-0000-00000000000f', p_aal);
$$;
create function tests.new_kid(p_username text, p_test boolean) returns uuid language plpgsql as $$
declare
  v_user uuid := gen_random_uuid();
  v_acct uuid;
begin
  insert into auth.users (id, email) values (v_user, p_username || '@test.invalid');
  insert into public.accounts (name, is_test) values ('Kid ' || upper(right(p_username, 1)), p_test)
    returning id into v_acct;
  insert into public.profiles (user_id, role, account_id, username, display_name)
    values (v_user, 'investor', v_acct, p_username, p_username);
  return v_acct;
end;
$$;
create function tests.err(p_sql text) returns text language plpgsql as $$
begin
  execute p_sql;
  raise exception 'ran' using errcode = 'BB999';
exception
  when sqlstate 'BB999' then return null;
  when others then return sqlerrm;
end;
$$;
-- Her wish list (as she sees it), and one item in it by name.
create function tests.list() returns jsonb language sql as $$
  select public.kid_wishlist(public.my_account_id());
$$;
create function tests.item(p_name text) returns jsonb language sql as $$
  select i from jsonb_array_elements(tests.list() -> 'items') i where i ->> 'name' = p_name;
$$;
create function tests.done(p_name text) returns jsonb language sql as $$
  select i from jsonb_array_elements(tests.list() -> 'done') i where i ->> 'name' = p_name;
$$;
create function tests.id(p_name text) returns uuid language sql as $$
  select w.id from public.wishlist_items w where w.name = p_name order by w.created_at desc limit 1;
$$;
create function tests.names() returns text[] language sql as $$
  select array(select i ->> 'name' from jsonb_array_elements(tests.list() -> 'items') i);
$$;
-- A made-up JPEG: the JPEG start bytes, then filler, as base64 (what the app sends).
create function tests.jpeg(p_bytes integer) returns text language sql as $$
  select encode('\xffd8ffe0'::bytea || decode(repeat('ab', p_bytes - 4), 'hex'), 'base64');
$$;

insert into auth.users (id, email) values ('00000000-0000-0000-0000-00000000000f', 'parent@test.invalid');
insert into public.profiles (user_id, role, username, display_name)
  values ('00000000-0000-0000-0000-00000000000f', 'parent', 'test_parent', 'Parent');
select tests.clock('2026-10-16 10:00');
select tests.new_kid('wish_t', true);   -- a test account
select tests.new_kid('wish_a', false);  -- a real kid
select tests.new_kid('wish_b', false);  -- her sister
insert into public.settings (key, value, effective_date) values ('feature:wishlist', 'test', date '2026-01-01');

-- Her money: $400.00 in savings.
insert into public.transactions (account_id, vehicle, type, amount_cents, posting_key)
values (tests.acct('wish_t'), 'savings', 'deposit', 40000, 'test:wish:deposit');

-- 1. The feature switch ------------------------------------------------------------------------------

select tests.as_kid('wish_a');
select is(tests.err($$select public.wish_add('Bike', 41000, null, 4)$$),
  'The Wish List isn''t switched on for you yet.', 'a real kid can''t add while the switch is "test accounts only"');
select is(tests.err($$select public.kid_wishlist(public.my_account_id())$$),
  'The Wish List isn''t switched on for you yet.', '...or read her list');
select is(public.kid_goal(public.my_account_id()), null, 'Home shows no goal card while it''s off (and doesn''t fail)');

select tests.as_kid('wish_t');
select isnt(public.wish_add('Bike', 41000, 'https://shop.example.com/bike', 4), null,
  'the test account can add a wish');
select is(tests.list() ->> 'photos_max', '30', 'she can have up to 30 photos');

-- 2. What she can type -------------------------------------------------------------------------------

select is(tests.err($$select public.wish_add('   ', 1000, null, 3)$$), 'Give your wish a name.', 'a name is needed');
select is(tests.err($$select public.wish_add(repeat('x', 61), 1000, null, 3)$$),
  'Keep the name to 60 letters or fewer.', 'at most 60 letters');
select is(tests.err($$select public.wish_add('Gum', 99, null, 3)$$),
  'A rough price needs to be at least $1.00.', 'at least $1.00');
select is(tests.err($$select public.wish_add('Gum', 0, null, 3)$$),
  'A rough price needs to be at least $1.00.', 'not $0');
select is(tests.err($$select public.wish_add('Castle', 10000001, null, 3)$$),
  'A rough price can be at most $100,000.00.', 'at most $100,000.00');
select is(tests.err($$select public.wish_add('Gum', 100, null, 0)$$), 'Pick 1 to 5 stars.', 'at least 1 star');
select is(tests.err($$select public.wish_add('Gum', 100, null, 6)$$), 'Pick 1 to 5 stars.', 'at most 5 stars');
select is(tests.err($$select public.wish_add('Gum', 100, 'javascript:alert(1)', 3)$$),
  'A link needs to start with https:// or http://', 'no javascript: links');
select is(tests.err($$select public.wish_add('Gum', 100, 'data:text/html,hi', 3)$$),
  'A link needs to start with https:// or http://', 'no data: links');
select is(tests.err($$select public.wish_add('Gum', 100, 'ftp://example.com/gum', 3)$$),
  'A link needs to start with https:// or http://', 'only web links');
select is(tests.err($$select public.wish_add('Gum', 100, 'https://example.com/a gum', 3)$$),
  'That link has a space in it. Copy it again from the shop''s page.', 'no spaces in a link');
select is(tests.err($$select public.wish_add('Gum', 100, 'https://example.com/' || chr(8238) || 'gum', 3)$$),
  'That link has a hidden character in it. Copy it again from the shop''s page.', 'no hidden characters');
select is(tests.err($$select public.wish_add('Gum', 100, 'https://example.com/' || repeat('g', 481), 3)$$),
  'That link is too long (more than 500 letters).', 'at most 500 letters');
select is(tests.err($$select public.wish_add('Gum', 100, 'https://', 3)$$),
  'A link needs to start with https:// or http://', 'a link needs a site');
select isnt(public.wish_add('  Gum  ', null, '   ', 2), null, 'a price is optional, and an empty link is no link');
select is((select (w.name, w.price_cents, w.link)::text from public.wishlist_items w where w.id = tests.id('Gum')),
  '(Gum,,)', 'the name is trimmed; no price and no link are stored as nothing');
select is((select w.link from public.wishlist_items w where w.id = tests.id('Bike')),
  'https://shop.example.com/bike', 'a link is kept exactly as she pasted it');

-- 3. Progress and the projected date (from her total worth, at today's regular savings rate) ----------

select is(tests.list() ->> 'worth_cents', '40000', 'her total worth is $400.00');
select is(tests.item('Bike') ->> 'percent', '97', '$400 of $410 is 97% (rounded down)');
select is(tests.item('Bike') ->> 'enough', 'false', 'not enough yet');
select is(tests.item('Bike') ->> 'months', '15', 'at 2.0%, about 15 months');
select is(tests.item('Bike') ->> 'around', 'January 2028', '...so around January 2028');
select is(tests.item('Gum') ->> 'percent', null, 'no price, no percent');
select is(tests.item('Gum') ->> 'months', null, '...and no projection');

select is(public.wish_percent(40999, 41000), 99, 'a cent short is 99%, never 100%');
select is(public.wish_percent(41000, 41000), 100, 'exactly enough is 100%');
select is(public.wish_percent(90000, 41000), 100, 'more than enough stays at 100%');
select is(public.wish_percent(0, 41000), 0, 'nothing yet is 0%');
select is((select (p.months, p.around)::text from public.wish_projection(40000, 41000, 2.000, date '2026-10-16') p),
  '(15,"January 2028")', 'known answer: $400 → $410 at 2.0% takes 15 months');
select is((select (p.months, p.around)::text from public.wish_projection(10000, 11050, 2.000, date '2026-10-16') p),
  '(60,"October 2031")', 'exactly 5 years (60 months) is still shown');
select is((select (p.months, p.around)::text from public.wish_projection(10000, 11060, 2.000, date '2026-10-16') p),
  '(,)', '61 months is past the 5-year limit: no date');
select is((select (p.months, p.around)::text from public.wish_projection(10000, 45000, 2.000, date '2026-10-16') p),
  '(,)', '$100 → $450 by interest alone (about 75 years): no date');
select is((select (p.months, p.around)::text from public.wish_projection(0, 45000, 2.000, date '2026-10-16') p),
  '(,)', 'nothing saved yet: no date');
select is((select (p.months, p.around)::text from public.wish_projection(10000, 45000, 0, date '2026-10-16') p),
  '(,)', 'a 0% rate: no date');
select is((select (p.months, p.around)::text from public.wish_projection(50000, 45000, 2.000, date '2026-10-16') p),
  '(0,)', 'already enough: 0 months, no date needed');

-- A special doesn't count (it ends); the regular rate in force today does.
insert into public.rates (vehicle, gic_term, rate, effective_date, end_date, is_special, note)
values ('savings', null, 5.000, date '2026-10-16', date '2026-10-31', true, 'Test special.');
select is(tests.item('Bike') ->> 'months', '15', 'a savings special doesn''t change the projection');
select is(tests.list() ->> 'rate', '2.000', 'the regular savings rate is the one used');

-- 4. No photo bytes in the list ------------------------------------------------------------------------

select lives_ok($$select public.wish_set_photo(tests.id('Bike'), tests.jpeg(120000), tests.jpeg(15000))$$,
  'she adds a photo (120 KB) and its thumbnail (15 KB)');
select is(tests.item('Bike') ->> 'has_photo', 'true', 'the list says the item has a photo');
select ok(not (tests.item('Bike') ? 'photo') and not (tests.item('Bike') ? 'thumb'),
  'the list never carries the photo itself');
select ok(octet_length(tests.list()::text) < 5000, 'the whole list stays small (no picture bytes in it)');
select is(public.wish_photo(tests.id('Bike'), 'thumb'), replace(tests.jpeg(15000), E'\n', ''),
  'the thumbnail is loaded on its own, exactly as saved');
select is(public.wish_photo(tests.id('Bike'), 'full'), replace(tests.jpeg(120000), E'\n', ''),
  '...and the full photo, only when asked for');
select is(tests.list() ->> 'photos_used', '1', 'one photo used');

select is(tests.err($$select public.wish_set_photo(tests.id('Gum'), tests.jpeg(153601), tests.jpeg(15000))$$),
  'That photo is too big. Try another one.', 'a photo over 150 KB is refused');
select is(tests.err($$select public.wish_set_photo(tests.id('Gum'), tests.jpeg(120000), tests.jpeg(20481))$$),
  'That photo is too big. Try another one.', 'a thumbnail over 20 KB is refused');
select is(tests.err($$select public.wish_set_photo(tests.id('Gum'), encode(decode(repeat('ab', 5000), 'hex'), 'base64'), tests.jpeg(5000))$$),
  'That photo didn''t work. Try another one or a screenshot.', 'only a JPEG');
select is(tests.err($$select public.wish_set_photo(tests.id('Gum'), 'not base64 at all!', tests.jpeg(5000))$$),
  'That photo didn''t work. Try another one or a screenshot.', 'not a picture at all');
select is(tests.err($$select public.wish_set_photo(tests.id('Gum'), tests.jpeg(50), tests.jpeg(50))$$),
  'That photo didn''t work. Try another one or a screenshot.', 'too small to be a picture');

-- 5. The 7-day rule (Alberta days, from app_today()) --------------------------------------------------

select is(tests.item('Bike') ->> 'goal_from', 'Fri Oct 23', 'added Fri Oct 16: a goal from Fri Oct 23');
select is(tests.item('Bike') ->> 'can_goal', 'false', 'not on the day she adds it');
select is(tests.err($$select public.wish_make_goal(tests.id('Bike'))$$),
  'Still want this? You can make it a goal from Fri Oct 23.', 'refused on day 0');
select isnt(public.wish_add('Game', 6000, null, 5), null, 'a second wish');
select isnt(public.wish_add('Kite', 2500, null, 3), null, 'a third wish');

select tests.clock('2026-10-19 12:00');
select lives_ok($$select public.wish_update(tests.id('Game'), 'Game deluxe', 6000, null, 5)$$,
  'on day 3 she renames the game');
select is(tests.item('Game deluxe') ->> 'goal_from', 'Mon Oct 26', 'a new name starts the 7 days again (Oct 19 + 7)');
select lives_ok($$select public.wish_update(tests.id('Kite'), 'Kite', 3000, 'https://kites.example.com', 4)$$,
  'on day 3 she changes the kite''s price, link and stars');
select is(tests.item('Kite') ->> 'goal_from', 'Fri Oct 23', '...which doesn''t restart the 7 days');
select is(tests.item('Kite') ->> 'price_cents', '3000', '...and the new price is kept');

select tests.clock('2026-10-22 23:59');
select is(tests.err($$select public.wish_make_goal(tests.id('Bike'))$$),
  'Still want this? You can make it a goal from Fri Oct 23.', 'refused on day 6, a minute before midnight');
select is(tests.item('Bike') ->> 'can_goal', 'false', 'still not on day 6');

select tests.clock('2026-10-23 00:01');
select is(tests.item('Bike') ->> 'can_goal', 'true', 'on day 7 it can become a goal');
select is(tests.err($$select public.wish_make_goal(tests.id('Gum'))$$),
  'Add a rough price first, so you can see how close you are.', 'a goal needs a price');
select is(tests.err($$select public.wish_make_goal(tests.id('Game deluxe'))$$),
  'Still want this? You can make it a goal from Mon Oct 26.', 'the renamed game still waits');
select lives_ok($$select public.wish_make_goal(tests.id('Bike'))$$, 'day 7: the bike becomes her goal');
select is(tests.item('Bike') ->> 'status', 'goal', 'it shows as her goal');
select is((select count(*) from public.goals g where g.account_id = tests.acct('wish_t') and g.ended_at is null),
  1::bigint, 'one goal');
select is((select (g.name, g.target_cents)::text from public.goals g
            where g.account_id = tests.acct('wish_t') and g.ended_at is null), '(Bike,41000)',
  'the goal has the item''s name and price');

-- 6. One goal at a time, and Home's goal card -------------------------------------------------------

select is(public.kid_goal(public.my_account_id()) ->> 'name', 'Bike', 'Home shows the bike');
select is(public.kid_goal(public.my_account_id()) ->> 'percent', '97', '...97% of the way there');
select is(public.kid_goal(public.my_account_id()) ->> 'around', 'January 2028', '...and the projected month');
select is(tests.err($$select public.wish_make_goal(tests.id('Kite'))$$),
  'You''re already saving for Bike. Switch your goal?', 'a second goal needs her to switch');
select lives_ok($$select public.wish_make_goal(tests.id('Kite'), true)$$, 'she switches her goal to the kite');
select is(public.kid_goal(public.my_account_id()) ->> 'name', 'Kite', 'Home shows the kite now');
select is(public.kid_goal(public.my_account_id()) ->> 'enough', 'true', '$400 is enough for a $30 kite');
select is(tests.item('Bike') ->> 'status', 'wanted', 'the bike is back on her list');
select is(tests.item('Bike') ->> 'can_goal', 'true', '...and can be her goal again any time');
select is((select string_agg(g.name || ':' || coalesce(g.ended_how, 'now'), ' ' order by g.id) from public.goals g
            where g.account_id = tests.acct('wish_t')), 'Bike:switched Kite:now',
  'the old goal is kept, marked switched');
select is(tests.err($$select public.wish_update(tests.id('Kite'), 'Big kite', 3000, null, 4)$$),
  'Stop saving for this goal first if you want to change its name.', 'a goal''s name can''t change');
select lives_ok($$select public.wish_update(tests.id('Kite'), 'Kite', 3500, null, 4)$$, 'its price can');
select is((select g.target_cents from public.goals g where g.account_id = tests.acct('wish_t') and g.ended_at is null),
  3500::bigint, '...and the goal follows the new price');
select lives_ok($$select public.wish_stop_goal()$$, 'she stops saving for the kite');
select is(public.kid_goal(public.my_account_id()), null, 'no goal card now');
select is(tests.item('Kite') ->> 'status', 'wanted', 'the kite is a normal wish again');
select is(tests.err($$select public.wish_stop_goal()$$), 'You don''t have a goal right now.', 'nothing to stop');

-- 7. Her order ------------------------------------------------------------------------------------------

select is(tests.names(), array['Bike', 'Gum', 'Game deluxe', 'Kite'], 'in the order she added them');
select lives_ok($$select public.wish_reorder(array[tests.id('Kite'), tests.id('Bike'), tests.id('Game deluxe'), tests.id('Gum')])$$,
  'she reorders');
select is(tests.names(), array['Kite', 'Bike', 'Game deluxe', 'Gum'], 'the new order is kept');
select is(tests.err($$select public.wish_reorder(array[tests.id('Kite'), tests.id('Bike')])$$),
  'Your list changed. Please try again.', 'every item must be in the new order');
select is(tests.err($$select public.wish_reorder(array[tests.id('Kite'), tests.id('Kite'), tests.id('Game deluxe'), tests.id('Gum')])$$),
  'Your list changed. Please try again.', 'no item twice');

-- 8. The Done list ----------------------------------------------------------------------------------------

select lives_ok($$select public.wish_make_goal(tests.id('Bike'))$$, 'the bike is her goal again');
select lives_ok($$select public.wish_done(tests.id('Bike'), 'got_it')$$, 'she got the bike');
select is(tests.done('Bike') ->> 'status', 'got_it', 'it''s in her Done list as "I got this"');
select is(tests.done('Bike') ->> 'has_photo', 'true', '...with its photo');
select is(tests.item('Bike'), null, '...and not in her list');
select is((select g.ended_how from public.goals g where g.account_id = tests.acct('wish_t') order by g.id desc limit 1),
  'got_it', 'her goal ended because she got it');
select is(public.kid_goal(public.my_account_id()), null, 'no goal card after that');
select lives_ok($$select public.wish_done(tests.id('Gum'), 'removed')$$, 'she removes the gum');
select is(tests.done('Gum') ->> 'status', 'removed', 'it''s in her Done list as removed');
select is(tests.err($$select public.wish_update(tests.id('Gum'), 'Gum', 100, null, 3)$$),
  'That''s in your Done list now.', 'a Done item can''t be changed');
select is(tests.err($$select public.wish_make_goal(tests.id('Gum'))$$),
  'That''s in your Done list now.', '...or become a goal');
select is(tests.err($$select public.wish_set_photo(tests.id('Gum'), tests.jpeg(5000), tests.jpeg(5000))$$),
  'That''s in your Done list now.', '...or get a photo');
select lives_ok($$select public.wish_remove_photo(tests.id('Bike'))$$, 'she can still remove a Done item''s photo');
select is(tests.list() ->> 'photos_used', '0', 'its spot is free again');
select is(tests.err($$select public.wish_done(tests.id('Kite'), 'lost')$$), 'Pick "I got this" or "Remove".',
  'only the two ways to finish');

-- 9. Limits ------------------------------------------------------------------------------------------------

insert into public.wishlist_items (account_id, name, stars, sort_order)
select tests.acct('wish_t'), 'Filler ' || n, 1, 100 + n from generate_series(1, 48) n;
select is(tests.err($$select public.wish_add('One too many', 100, null, 1)$$),
  'Your list is full (50 things). Remove one first.', 'at most 50 things on her list');
insert into public.wishlist_photos (wishlist_item_id, account_id, photo, thumb)
select w.id, w.account_id, decode(tests.jpeg(1000), 'base64'), decode(tests.jpeg(500), 'base64')
  from public.wishlist_items w
 where w.name in (select 'Filler ' || n from generate_series(1, 30) n);
select is(tests.list() ->> 'photos_used', '30', '30 photos');
select is(tests.err($$select public.wish_set_photo(tests.id('Kite'), tests.jpeg(5000), tests.jpeg(1000))$$),
  'You''ve used all 30 photo spots. Remove a photo first.', 'not a 31st');
select lives_ok($$select public.wish_set_photo(tests.id('Filler 1'), tests.jpeg(6000), tests.jpeg(1000))$$,
  'replacing a photo is fine when she''s at 30');
delete from public.wishlist_photos where wishlist_item_id in (select id from public.wishlist_items where name like 'Filler %');
delete from public.wishlist_items where name like 'Filler %';

-- 10. Only her own -------------------------------------------------------------------------------------

insert into public.settings (key, value, effective_date) values ('feature:wishlist', 'everyone', date '2026-10-23');
select tests.as_kid('wish_b');
select isnt(public.wish_add('Paints', 1500, null, 3), null, 'switched on for everyone: her sister adds a wish');
select is(tests.err($$select public.wish_update(tests.id('Kite'), 'Mine now', 100, null, 1)$$),
  'That isn''t on your wish list.', 'she can''t change her sister''s wish');
select is(tests.err($$select public.wish_done(tests.id('Kite'), 'removed')$$),
  'That isn''t on your wish list.', '...or remove it');
select is(tests.err($$select public.wish_make_goal(tests.id('Kite'))$$),
  'That isn''t on your wish list.', '...or make it her goal');
select is(tests.err($$select public.wish_photo(tests.id('Kite'), 'thumb')$$),
  'That photo isn''t yours to see.', '...or see its photo');
select is(tests.err($$select public.wish_reorder(array[tests.id('Paints'), tests.id('Kite')])$$),
  'Your list changed. Please try again.', '...or put it in her list''s order');
select is(tests.err($$select public.kid_wishlist(tests.acct('wish_t'))$$),
  'You can only see your own wish list.', '...or read her list');
select is(tests.err($$select public.kid_goal(tests.acct('wish_t'))$$),
  'You can only see your own wish list.', '...or her goal');

-- RLS, as the signed-in role really is.
select tests.as_kid('wish_t');
select public.wish_set_photo(tests.id('Kite'), tests.jpeg(5000), tests.jpeg(1000));
select public.wish_make_goal(tests.id('Kite'));
select tests.as_parent();
select public.parent_wishlist_mark(tests.id('Kite'), true, 'Mom bought it for her birthday');
-- Her account id, readable once the role switches (profiles are her own row only then).
create table tests.ids as select tests.acct('wish_t') as wish_t;
grant select on tests.ids to authenticated;
select tests.as_kid('wish_b');
set local role authenticated;
select is((select count(*) from public.wishlist_items where account_id = (select wish_t from tests.ids)), 0::bigint,
  'RLS: her sister sees none of her items');
select is((select count(*) from public.wishlist_photos where account_id = (select wish_t from tests.ids)), 0::bigint,
  'RLS: ...none of her photos');
select is((select count(*) from public.goals where account_id = (select wish_t from tests.ids)), 0::bigint,
  'RLS: ...none of her goals');
select is((select count(*) from public.wishlist_items), 1::bigint, 'RLS: she sees only her own one wish');
reset role;
select tests.as_kid('wish_t');
set local role authenticated;
select ok((select count(*) from public.wishlist_items) > 0 and
          (select bool_and(account_id = public.my_account_id()) from public.wishlist_items),
  'RLS: she sees her own items, and only hers');
select is((select count(*) from public.wishlist_photos), 1::bigint, 'RLS: she sees her own photo');
select is((select count(*) from public.wishlist_parent_marks), 0::bigint,
  'RLS: she can''t see the "Got it" marker, even on her own item');
select throws_ok($$insert into public.wishlist_items (account_id, name) values (public.my_account_id(), 'Sneaky')$$,
  '42501', null, 'no direct insert into her list');
select throws_ok($$update public.wishlist_items set stars = 5$$, '42501', null, 'no direct update');
select throws_ok($$delete from public.wishlist_photos$$, '42501', null, 'no direct delete of photos');
select throws_ok($$insert into public.wishlist_parent_marks (wishlist_item_id) values (gen_random_uuid())$$,
  '42501', null, 'no direct "Got it" marker');
select throws_ok($$update public.goals set target_cents = 1$$, '42501', null, 'no direct change to a goal');
reset role;

-- 11. The parent-only "Got it" marker -------------------------------------------------------------------

select tests.as_kid('wish_t');
create temp table seen as select tests.list() as l, public.kid_goal(public.my_account_id()) as g;
select is(tests.err($$select public.parent_wishlist_mark(tests.id('Kite'), false)$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'a kid can''t mark anything');
select ok(position('Mom bought' in tests.list()::text) = 0 and position('marked' in tests.list()::text) = 0,
  'her list says nothing about the marker');
select ok(position('Mom bought' in public.kid_goal(public.my_account_id())::text) = 0
          and position('marked' in public.kid_goal(public.my_account_id())::text) = 0,
  'her goal card says nothing about it');

select tests.as_parent('aal1');
select is(tests.err($$select public.parent_wishlist_mark(tests.id('Kite'), false)$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', 'Dad needs the authenticator code');
select is(tests.err($$select public.parent_wishlists()$$),
  'Only a parent signed in with the second step (the authenticator code) can do this.', '...to see the wish lists too');
select tests.as_parent();
select is((select count(*) from public.parent_actions where action = 'wishlist_mark'), 1::bigint,
  'marking "Got it" was logged');
select is((select summary from public.parent_actions where action = 'wishlist_mark'),
  'Marked Kid T''s "Kite" as Got it.', '...in plain words');
select is((select i ->> 'marked' || ' ' || (i ->> 'mark_note')
             from jsonb_array_elements(public.parent_wishlists()) k, jsonb_array_elements(k -> 'items') i
            where k ->> 'account_id' = tests.acct('wish_t')::text and i ->> 'name' = 'Kite'),
  'true Mom bought it for her birthday', 'Dad sees the marker and its note');
select is((select k ->> 'enabled' from jsonb_array_elements(public.parent_wishlists()) k
            where k ->> 'account_id' = tests.acct('wish_t')::text), 'true', '...and that her Wish List is on');
select is((select count(*) from jsonb_array_elements(public.parent_wishlists()) k, jsonb_array_elements(k -> 'items') i
            where k ->> 'account_id' = tests.acct('wish_t')::text and i ? 'photo'), 0::bigint,
  'Dad''s list carries no photo bytes either');
select is(public.wish_photo(tests.id('Kite'), 'thumb'), replace(tests.jpeg(1000), E'\n', ''), 'Dad can load her photo');
select is(tests.err($$select public.wish_make_goal(tests.id('Kite'))$$), 'Only a kid''s account can do this.',
  'Dad can''t change her list');
select lives_ok($$select public.parent_wishlist_mark(tests.id('Kite'), false)$$, 'Dad clears the marker');
select is((select count(*) from public.wishlist_parent_marks m where m.wishlist_item_id = tests.id('Kite')), 0::bigint,
  'the marker is gone');
select is((select summary from public.parent_actions where action = 'wishlist_mark' order by id desc limit 1),
  'Cleared Got it on Kid T''s "Kite".', 'clearing it was logged too');
select is(tests.err($$select public.parent_wishlist_mark(tests.id('Kite'), true, repeat('x', 201))$$),
  'Keep the note to 200 letters or fewer.', 'a short note');
select public.parent_wishlist_mark(tests.id('Kite'), true, 'Got it');
select tests.as_kid('wish_t');
select is((select l from seen), tests.list(), 'her list reads exactly the same with or without the marker');
select is((select g from seen), public.kid_goal(public.my_account_id()), '...and so does her goal card');
select lives_ok($$select public.wish_done(tests.id('Kite'), 'removed')$$, 'she can still remove a marked item');

-- 12. When her funds go down --------------------------------------------------------------------------

select tests.as_kid('wish_t');
select public.wish_add('Tent', 100000, null, 3);
insert into public.fund_prices (fund_id, price_date, close) values ('dow', date '2026-10-15', 500);
insert into public.transactions (account_id, vehicle, fund_id, type, amount_cents, units, unit_price, posting_key)
values (tests.acct('wish_t'), 'savings', null, 'transfer_out', -10000, null, null, 'test:wish:buy:s'),
       (tests.acct('wish_t'), 'stock', 'dow', 'transfer_in', 10000, 0.2, 500, 'test:wish:buy:f');
select is(tests.item('Tent') ->> 'percent', '40', '$300 in savings and $100 in the Dow fund: 40% of $1,000');
select is(tests.list() ->> 'funds_dipped', 'false', 'no drop yet: no "went down" line');
insert into public.fund_prices (fund_id, price_date, close) values ('dow', date '2026-10-22', 450);
select is(tests.item('Tent') ->> 'percent', '39', 'the Dow fund falls 10%: $390 is 39%, so her progress went down');
select is(tests.list() ->> 'funds_dipped', 'true', '...and her list says her funds went down this week');
select is(public.kid_goal(public.my_account_id()), null, 'no goal, no card');
select tests.clock('2026-10-26 09:00');
select public.wish_make_goal(tests.id('Game deluxe'));
select is(public.kid_goal(public.my_account_id()) ->> 'funds_dipped', 'true', 'the goal card knows too');
insert into public.fund_prices (fund_id, price_date, close) values ('dow', date '2026-10-23', 520);
select is(tests.list() ->> 'funds_dipped', 'false', 'back above last week''s close: no "went down" line');

-- 13. Who may call what ---------------------------------------------------------------------------------

select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('wish_add', 'wish_update', 'wish_set_photo', 'wish_remove_photo', 'wish_photo',
                             'wish_reorder', 'wish_done', 'wish_make_goal', 'wish_stop_goal', 'kid_wishlist',
                             'kid_goal', 'parent_wishlist_mark', 'parent_wishlists')
           and has_function_privilege('authenticated', p.oid, 'EXECUTE')
           and not has_function_privilege('anon', p.oid, 'EXECUTE')
         order by 1),
  array['kid_goal', 'kid_wishlist', 'parent_wishlist_mark', 'parent_wishlists', 'wish_add', 'wish_done',
        'wish_make_goal', 'wish_photo', 'wish_remove_photo', 'wish_reorder', 'wish_set_photo', 'wish_stop_goal',
        'wish_update'],
  'signed-in users can call the wish list functions (each checks who is calling); anon can''t');
select is(
  array(select p.proname::text from pg_proc p
         where p.pronamespace = 'public'::regnamespace
           and p.proname in ('wish_kid', 'wish_list_json', 'wish_projection', 'wish_percent', 'wish_link_problem',
                             'wish_funds_dipped')
           and (has_function_privilege('authenticated', p.oid, 'EXECUTE')
                or has_function_privilege('anon', p.oid, 'EXECUTE'))
         order by 1),
  '{}'::text[], 'the helpers are for the database only');

select * from finish();
rollback;
