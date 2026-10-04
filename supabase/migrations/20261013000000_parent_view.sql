-- Stage 8: "View as <kid>". Dad sees a girl's real Home, Graphs, history and
-- notices, read-only. In that mode the app reads ONLY through parent_view: a
-- parent-only function (authenticator code required) that allows a fixed list of
-- reads, each answered by the same read function or view her own app uses, for
-- that one account. Nothing here writes; the kid actions already refuse a parent
-- (kid_account, mark_notices_read), and the tests prove it.

create function public.parent_view(p_account uuid, p_read text, p_args jsonb default '{}'::jsonb)
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
comment on function public.parent_view(uuid, text, jsonb) is
  '"View as <kid>": one read of her screens, read-only, for a parent with the authenticator code.';

revoke all on function public.parent_view(uuid, text, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.parent_view(uuid, text, jsonb) to authenticated;
