-- TSX is closed every Jan 1 (Dad, 2026-11-27), so its 2027-01-01 holiday is marked confirmed.
-- Data only. is_trading_day ignores `confirmed`, so no trading day, settlement or dividend date
-- moves. `confirmed` only feeds the Dashboard's holiday warning, which counts whole years:
-- TSX Family Day (2027-02-15) is still unconfirmed, so the warning still reads "confirmed only
-- through Dec 31, 2026" until TSX's 2027 calendar is added.
do $$
declare
  v_n integer;
begin
  update public.market_holidays
     set confirmed = true
   where market = 'tsx' and holiday_date = date '2027-01-01' and kind = 'closed' and not confirmed;
  get diagnostics v_n = row_count;
  if v_n <> 1 then
    raise exception 'Expected to confirm exactly one TSX holiday (2027-01-01), but changed %.', v_n;
  end if;
end;
$$;
