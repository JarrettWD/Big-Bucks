-- Stage 2: schema additions for the money engine.
--
-- 1. transactions.effective_at: when the money counts. posted_at stays the real
--    time the row was written. They differ only for automatic postings: a trade
--    written by the 3:30 pm run counts from the 2:00 pm close, and a catch-up run
--    on Nov 10 for Nov 5 counts from Nov 5. Balances "as of a day" (interest,
--    graphs, dividends) use effective_at, so a late run still gives the right answer.
--    No ledger rows exist yet anywhere, so no existing row needs a value.
alter table public.transactions
  add column effective_at timestamptz not null default public.app_now();
comment on column public.transactions.effective_at is
  'When the money counts. Equal to posted_at except for automatic postings, which count from their own date or close.';
create index transactions_account_effective_idx on public.transactions (account_id, effective_at);

-- 2. A matured GIC waiting for her choice earns the savings rate (Dad's decision,
--    stage 2). The daily accrual records the waiting amount next to the savings
--    balance, so "How was this calculated?" can show both.
alter table public.interest_accruals
  add column gic_waiting_cents bigint not null default 0 check (gic_waiting_cents >= 0);
comment on column public.interest_accruals.balance_cents is 'End-of-day savings balance, in cents (held money included).';
comment on column public.interest_accruals.gic_waiting_cents is
  'Matured GIC money waiting for her choice at the end of the day, in cents. Earns the savings rate.';

-- 3. Fund splits, recorded by the price job (stage 4). Units scale by ratio_to / ratio_from.
create table public.fund_splits (
  fund_id    text not null references public.funds (id),
  split_date date not null,
  ratio_from integer not null check (ratio_from > 0),
  ratio_to   integer not null check (ratio_to > 0),
  source     text,
  created_at timestamptz not null default public.app_now(),
  primary key (fund_id, split_date),
  constraint fund_splits_changes_something check (ratio_from <> ratio_to)
);
comment on table public.fund_splits is 'ETF splits. A 2-for-1 split is ratio_from 1, ratio_to 2.';
alter table public.fund_splits enable row level security;
create policy fund_splits_read on public.fund_splits for select to authenticated using (true);
grant select on public.fund_splits to authenticated, service_role;

-- 4. Keys that stop automatic notes and notices being written twice.
alter table public.notes add column auto_key text unique check (btrim(auto_key) <> '');
alter table public.notifications add column dedupe_key text unique check (btrim(dedupe_key) <> '');

-- 5. New job names and notice types. (New enum values are only used inside
--    function bodies, which run after this migration commits.)
alter type public.job_name add value 'expire';
alter type public.job_name add value 'auto_move';
alter type public.job_name add value 'splits';
alter type public.job_name add value 'notes';
alter type public.job_name add value 'rate_notices';
alter type public.notification_type add value 'question';

-- 6. Dividend yields become dated settings (Dad's decision, stage 2), so a yield
--    change keeps its history like a rate change. The column goes, leaving one source.
insert into public.settings (key, value, effective_date, note)
select 'dividend_yield:' || f.id, rtrim(rtrim(f.dividend_yield::text, '0'), '.'), date '2026-01-01',
       'Starting yield, percent per year.'
  from public.funds f;
alter table public.funds drop column dividend_yield;

-- 7. The standard market-move notes. Dad can change the wording with set_setting.
insert into public.settings (key, value, effective_date, note) values
  ('market_move_note_down',
   'Big drop today. This happens a few times a year. Long-term, markets have recovered.',
   date '2026-01-01', 'Shown when a fund falls more than 2% in a day.'),
  ('market_move_note_up',
   'Big jump today. Markets go up and down, and one great day doesn''t mean the next will be.',
   date '2026-01-01', 'Shown when a fund rises more than 2% in a day.');
