-- The price fix, part 4: the parent "Fix a close" screen's read (pre-Stage-12 list, built with the
-- price fix because production day needs it).
--
-- close_fix_preview now also answers before Dad has typed a close (p_close null): the stored close
-- and when it was fetched, so he can compare it with the official one. With a close it lists every
-- adjustment, as before. It still only reads: nothing changes and nothing reaches outside.

-- close_fix_preview: from 20261113010000_close_fix.sql (p_close may be null; the stored close and
-- its fetch time in words).
create or replace function public.close_fix_preview(p_fund_id text, p_date date, p_close numeric)
returns jsonb
language plpgsql stable
security definer
set search_path = ''
as $$
declare
  v_fund public.funds;
  v_old public.fund_prices;
begin
  perform public.require_parent();
  select * into v_fund from public.funds f where f.id = p_fund_id;
  if not found then
    raise exception 'There''s no fund called "%".', p_fund_id;
  end if;
  if p_date is null then
    raise exception 'Choose the day of the close.';
  end if;
  select * into v_old from public.fund_prices fp where fp.fund_id = p_fund_id and fp.price_date = p_date;
  if not found then
    raise exception 'There''s no close stored for % on %.', v_fund.name, public.fmt_date(p_date);
  end if;
  if p_close is not null and (p_close <= 0 or p_close <> round(p_close, 8)) then
    raise exception 'A close is a price above $0, with at most 8 decimal places.';
  end if;
  return jsonb_build_object(
    'fund_id', p_fund_id, 'fund_name', v_fund.name, 'date', p_date, 'day_words', public.fmt_date(p_date),
    'old_close', v_old.close, 'old_close_words', public.fmt_money4(v_old.close * 100),
    'fetched_at', v_old.fetched_at, 'fetched_words', public.fmt_moment(v_old.fetched_at),
    'final', public.final_close(p_fund_id, p_date) is not null,
    'new_close', p_close,
    'new_close_words', case when p_close is not null then public.fmt_money4(p_close * 100) end,
    'adjustments', case when p_close is null or p_close = v_old.close then '[]'::jsonb
                        else coalesce((select jsonb_agg(a || jsonb_build_object(
                               'kid_name', (select ac.name from public.accounts ac where ac.id = (a ->> 'account_id')::uuid)))
                               from public.close_fix_adjustments(p_fund_id, p_date, p_close) a), '[]'::jsonb) end);
end;
$$;
comment on function public.close_fix_preview(text, date, numeric) is
  'Parent only: the stored close (p_close null), or what "Fix a close" would change trade by trade. Changes nothing.';
