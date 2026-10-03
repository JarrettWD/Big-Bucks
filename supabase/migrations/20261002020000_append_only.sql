-- Stage 1: the ledger, the rate history and the daily interest accruals are
-- append-only, like settings (stage 0). UPDATE, DELETE and TRUNCATE are rejected
-- for every role, the service role and the database owner included. Mistakes
-- are fixed with a new correcting row that carries a plain-language note.
--
-- interest_accruals is not named in the spec's append-only list, but it is the
-- working behind every "Interest paid" line, so it is protected the same way.

create trigger transactions_no_update_delete
  before update or delete on public.transactions
  for each row execute function public.reject_append_only_change();

create trigger transactions_no_truncate
  before truncate on public.transactions
  for each statement execute function public.reject_append_only_change();

create trigger rates_no_update_delete
  before update or delete on public.rates
  for each row execute function public.reject_append_only_change();

create trigger rates_no_truncate
  before truncate on public.rates
  for each statement execute function public.reject_append_only_change();

create trigger interest_accruals_no_update_delete
  before update or delete on public.interest_accruals
  for each row execute function public.reject_append_only_change();

create trigger interest_accruals_no_truncate
  before truncate on public.interest_accruals
  for each statement execute function public.reject_append_only_change();
