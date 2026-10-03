-- Stage 1: every table in the Data model, plus the Build decisions additions.
--
-- Money rules that the schema itself enforces:
--   * Money is integer cents (bigint). Fractional cents exist only in
--     interest_accruals.accrued (numeric). Fund units are numeric(20,8).
--   * Rates and yields are percent per year: 5.000 means 5%.
--   * The ledger is signed: in transactions, a positive amount_cents (or units)
--     adds to that vehicle and a negative one takes away. A vehicle's balance is
--     the plain sum of its rows. Check constraints below pin the sign per type.
--   * Timestamps default to app_now() and dates to app_today(), so the time
--     machine moves them too.
--
-- Nobody writes to these tables directly: see the RLS migration. Writes come
-- through Postgres functions in later stages.

-- Enums ---------------------------------------------------------------------

create type public.user_role as enum ('parent', 'investor');
create type public.view_mode as enum ('basic', 'detailed');
create type public.vehicle as enum ('savings', 'gic', 'stock');
-- QQQ trades on Nasdaq, which follows the same holiday calendar as the NYSE.
create type public.market as enum ('nyse', 'tsx');
create type public.request_type as enum ('deposit', 'withdraw', 'move');
create type public.request_status as enum ('pending', 'approved', 'declined', 'settled', 'expired');
create type public.transaction_type as enum (
  'deposit', 'withdraw', 'interest', 'transfer_in', 'transfer_out',
  'penalty', 'dividend', 'split_adjust', 'correction'
);
create type public.gic_status as enum ('active', 'matured', 'broken');
create type public.maturity_choice as enum ('renew', 'to_savings', 'new_term');
create type public.job_name as enum (
  'prices', 'settle', 'interest', 'monthly', 'gic_maturity', 'dividends', 'reconcile', 'backup'
);
create type public.job_status as enum ('ok', 'failed', 'retrying');
create type public.note_audience as enum ('kids', 'parent');
create type public.question_status as enum ('open', 'answered');
create type public.wishlist_status as enum ('wanted', 'goal', 'got_it', 'removed');
create type public.notification_type as enum (
  'rate_change', 'rate_live', 'request', 'gic_maturity',
  'cap_change', 'request_expired', 'badge', 'whats_new'
);
create type public.holiday_kind as enum ('closed', 'early_close');
create type public.alert_kind as enum (
  'job_failed', 'missing_price', 'mismatch', 'backup_failed', 'lockout', 'holidays_running_out', 'test'
);

-- People and accounts ---------------------------------------------------------

-- One per kid. Real names are set at runtime by the setup script, never in the repo.
create table public.accounts (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null check (btrim(name) <> ''),
  created_at          timestamptz not null default public.app_now(),
  is_test             boolean not null default false,
  view_mode           public.view_mode not null default 'detailed',
  theme_colour        text check (theme_colour ~ '^#[0-9A-Fa-f]{6}$'),
  avatar_animal       text,
  avatar_accessory    text,
  agreement_signed_at timestamptz,
  onboarding_done_at  timestamptz
);

-- Links a login to a role. A kid's profile points at her account; a parent's
-- profile has no account (the parent sees every account).
create table public.profiles (
  user_id      uuid primary key references auth.users (id) on delete cascade,
  role         public.user_role not null,
  account_id   uuid unique references public.accounts (id),
  username     text not null unique check (username ~ '^[a-z0-9_]{3,30}$'),
  display_name text not null check (btrim(display_name) <> ''),
  created_at   timestamptz not null default public.app_now(),
  constraint profiles_kid_has_account check ((role = 'investor') = (account_id is not null))
);

-- Reference tables ------------------------------------------------------------

create table public.funds (
  id             text primary key check (id ~ '^[a-z0-9_]+$'),
  name           text not null check (btrim(name) <> ''),
  proxy_symbol   text not null unique check (btrim(proxy_symbol) <> ''),
  market         public.market not null,
  colour         text not null check (colour ~ '^#[0-9A-Fa-f]{6}$'),
  dividend_yield numeric(6,3) not null check (dividend_yield >= 0 and dividend_yield < 100),
  sort_order     smallint not null default 0
);
comment on column public.funds.dividend_yield is 'Yearly dividend yield, percent (1.800 means 1.8%).';

-- Dated rate history. Append-only. Rate is percent per year.
create table public.rates (
  id             bigint generated always as identity primary key,
  vehicle        public.vehicle not null check (vehicle in ('savings', 'gic')),
  gic_term       smallint check (gic_term in (1, 3, 6, 9, 12, 24)),
  rate           numeric(6,3) not null check (rate >= 0 and rate < 100),
  effective_date date not null,
  end_date       date,
  is_special     boolean not null default false,
  note           text,
  created_by     uuid,
  created_at     timestamptz not null default public.app_now(),
  constraint rates_term_matches_vehicle check ((vehicle = 'gic') = (gic_term is not null)),
  constraint rates_special_has_end check (is_special = (end_date is not null)),
  constraint rates_end_after_start check (end_date is null or end_date >= effective_date)
);
comment on column public.rates.rate is 'Percent per year (5.000 means 5%).';
create index rates_lookup_idx on public.rates (vehicle, gic_term, effective_date desc, id desc);

create table public.fund_prices (
  fund_id    text not null references public.funds (id),
  price_date date not null,
  close      numeric(20,8) not null check (close > 0),
  fetched_at timestamptz not null default public.app_now(),
  primary key (fund_id, price_date)
);

-- Closed days and early closes per market. Rows with confirmed = false were
-- calculated from the exchange's usual rules before the exchange published that
-- year; stage 4's warning treats unconfirmed years as missing.
create table public.market_holidays (
  market       public.market not null,
  holiday_date date not null,
  name         text not null check (btrim(name) <> ''),
  kind         public.holiday_kind not null default 'closed',
  closes_at    time,
  confirmed    boolean not null,
  source_url   text not null,
  primary key (market, holiday_date),
  constraint market_holidays_weekday check (extract(isodow from holiday_date) < 6),
  constraint market_holidays_early_close_time check ((kind = 'early_close') = (closes_at is not null))
);
comment on column public.market_holidays.closes_at is 'Early-close time, US/Canada Eastern.';

create table public.glossary (
  term     text primary key check (btrim(term) <> ''),
  kid_text text not null check (btrim(kid_text) <> '')
);

-- GICs ------------------------------------------------------------------------

create table public.gic_holdings (
  id              bigint generated always as identity primary key,
  account_id      uuid not null references public.accounts (id),
  principal_cents bigint not null check (principal_cents > 0),
  rate            numeric(6,3) not null check (rate >= 0 and rate < 100),
  rate_id         bigint references public.rates (id),
  term_months     smallint not null check (term_months in (1, 3, 6, 9, 12, 24)),
  start_date      date not null,
  maturity_date   date not null,
  status          public.gic_status not null default 'active',
  maturity_choice public.maturity_choice,
  renewed_from_id bigint references public.gic_holdings (id),
  created_at      timestamptz not null default public.app_now(),
  -- Start date plus the term in calendar months; Postgres moves Jan 31 + 1 month
  -- back to the month's last day (Feb 28, or Feb 29 in a leap year).
  constraint gic_maturity_rule check (maturity_date = (start_date + make_interval(months => term_months))::date)
);
comment on column public.gic_holdings.rate is 'Locked-in rate, percent per year.';
create index gic_holdings_account_idx on public.gic_holdings (account_id);

-- Requests --------------------------------------------------------------------

create table public.requests (
  id            bigint generated always as identity primary key,
  account_id    uuid not null references public.accounts (id),
  type          public.request_type not null,
  from_vehicle  public.vehicle,
  to_vehicle    public.vehicle,
  fund_id       text references public.funds (id),
  gic_term      smallint check (gic_term in (1, 3, 6, 9, 12, 24)),
  gic_id        bigint references public.gic_holdings (id),
  amount_cents  bigint check (amount_cents > 0),
  sell_all      boolean not null default false,
  status        public.request_status not null default 'pending',
  held_cents    bigint not null default 0 check (held_cents >= 0),
  held_units    numeric(20,8) not null default 0 check (held_units >= 0),
  parent_note   text,
  reflection    text,
  created_at    timestamptz not null default public.app_now(),
  decided_at    timestamptz,
  settled_at    timestamptz,
  -- Deposits land in savings; withdrawals leave from savings; every move goes through savings.
  constraint requests_shape check (
    (type = 'deposit'  and from_vehicle is null      and to_vehicle = 'savings') or
    (type = 'withdraw' and from_vehicle = 'savings'  and to_vehicle is null) or
    (type = 'move'     and from_vehicle is not null and to_vehicle is not null
                       and from_vehicle <> to_vehicle
                       and 'savings' in (from_vehicle, to_vehicle))
  ),
  constraint requests_fund_iff_stock check (
    (fund_id is not null) = ('stock' in (coalesce(from_vehicle, 'savings'), coalesce(to_vehicle, 'savings')))
  ),
  constraint requests_term_iff_gic_buy check ((gic_term is not null) = (to_vehicle is not distinct from 'gic')),
  constraint requests_gic_id_only_for_gic check (gic_id is null or 'gic' in (coalesce(from_vehicle, 'savings'), coalesce(to_vehicle, 'savings'))),
  -- "Sell all" has no amount; everything else must name one.
  constraint requests_amount_or_sell_all check (
    (sell_all and amount_cents is null and from_vehicle is not distinct from 'stock') or
    (not sell_all and amount_cents is not null)
  )
);
create index requests_account_idx on public.requests (account_id, created_at desc);
create index requests_pending_idx on public.requests (status) where status = 'pending';

-- The ledger ------------------------------------------------------------------

create table public.transactions (
  id           bigint generated always as identity primary key,
  account_id   uuid not null references public.accounts (id),
  vehicle      public.vehicle not null,
  fund_id      text references public.funds (id),
  gic_id       bigint references public.gic_holdings (id),
  type         public.transaction_type not null,
  amount_cents bigint not null,
  units        numeric(20,8),
  unit_price   numeric(20,8) check (unit_price > 0),
  request_id   bigint references public.requests (id),
  posting_key  text unique check (btrim(posting_key) <> ''),
  note         text,
  reverses_id  bigint references public.transactions (id),
  posted_at    timestamptz not null default public.app_now(),

  -- Which vehicle carries what
  constraint tx_stock_has_fund_and_units check (vehicle <> 'stock' or (fund_id is not null and units is not null)),
  constraint tx_units_only_for_stock check (vehicle = 'stock' or (units is null and unit_price is null)),
  constraint tx_fund_only_on_stock_or_savings check (fund_id is null or vehicle in ('stock', 'savings')),
  constraint tx_gic_has_gic_id check (vehicle <> 'gic' or gic_id is not null),
  constraint tx_gic_id_only_on_gic_or_savings check (gic_id is null or vehicle in ('gic', 'savings')),

  -- Which types belong to which vehicle
  constraint tx_type_vehicle check (
    case type
      when 'deposit'      then vehicle = 'savings'
      when 'withdraw'     then vehicle = 'savings'
      when 'interest'     then vehicle in ('savings', 'gic')
      when 'dividend'     then vehicle = 'savings'
      when 'penalty'      then vehicle in ('savings', 'gic')
      when 'split_adjust' then vehicle = 'stock'
      else true
    end
  ),

  -- Signs: + adds to the vehicle, - takes away
  constraint tx_sign check (
    case type
      when 'deposit'      then amount_cents > 0
      when 'interest'     then amount_cents > 0
      when 'dividend'     then amount_cents > 0
      when 'transfer_in'  then amount_cents > 0 and (units is null or units > 0)
      when 'withdraw'     then amount_cents < 0
      when 'penalty'      then amount_cents < 0
      when 'transfer_out' then amount_cents < 0 and (units is null or units < 0)
      when 'split_adjust' then amount_cents = 0 and units <> 0
      when 'correction'   then amount_cents <> 0 or coalesce(units, 0) <> 0
    end
  ),

  -- Corrections are open: they carry a plain-language note, and only they reverse things.
  constraint tx_correction_has_note check (type <> 'correction' or btrim(coalesce(note, '')) <> ''),
  constraint tx_reverses_only_corrections check (reverses_id is null or type = 'correction')
);
comment on table public.transactions is
  'The append-only ledger. Signed: + adds to the vehicle, - takes away. Fix mistakes with a correction row.';
create index transactions_account_idx on public.transactions (account_id, posted_at);
create index transactions_gic_idx on public.transactions (gic_id) where gic_id is not null;
create index transactions_fund_idx on public.transactions (account_id, fund_id) where fund_id is not null;

-- Daily savings accrual in fractional cents. One row per account per day.
create table public.interest_accruals (
  account_id    uuid not null references public.accounts (id),
  accrual_date  date not null,
  balance_cents bigint not null check (balance_cents >= 0),
  rate          numeric(6,3) not null check (rate >= 0 and rate < 100),
  rate_id       bigint references public.rates (id),
  days_in_year  smallint not null check (days_in_year in (365, 366)),
  accrued       numeric not null check (accrued >= 0),
  created_at    timestamptz not null default public.app_now(),
  primary key (account_id, accrual_date)
);
comment on column public.interest_accruals.accrued is 'Interest earned that day, in fractional cents.';

-- Jobs, notes and alerts ------------------------------------------------------

create table public.job_runs (
  id           bigint generated always as identity primary key,
  job          public.job_name not null,
  run_for_date date not null,
  status       public.job_status not null,
  details      jsonb,
  started_at   timestamptz not null default public.app_now(),
  finished_at  timestamptz
);
create index job_runs_job_date_idx on public.job_runs (job, run_for_date desc);

create table public.notes (
  id         bigint generated always as identity primary key,
  note_date  date not null,
  fund_id    text references public.funds (id),
  body       text not null check (btrim(body) <> ''),
  audience   public.note_audience not null default 'kids',
  created_at timestamptz not null default public.app_now()
);
create index notes_date_idx on public.notes (note_date desc);

-- Problems for Dad. Alerts about test accounts are quiet: logged, never raised.
create table public.alerts (
  id          bigint generated always as identity primary key,
  kind        public.alert_kind not null,
  account_id  uuid references public.accounts (id),
  is_quiet    boolean not null default false,
  message     text not null check (btrim(message) <> ''),
  details     jsonb,
  created_at  timestamptz not null default public.app_now(),
  resolved_at timestamptz,
  resolved_by uuid
);
create index alerts_open_idx on public.alerts (created_at desc) where resolved_at is null;

-- Failed PINs and lockouts, written by the kid-login Edge Function in stage 6.
create table public.login_attempts (
  id           bigint generated always as identity primary key,
  username     text not null,
  user_id      uuid references auth.users (id) on delete set null,
  succeeded    boolean not null,
  locked_until timestamptz,
  attempted_at timestamptz not null default public.app_now()
);
create index login_attempts_username_idx on public.login_attempts (username, attempted_at desc);

-- Kid-owned extras -------------------------------------------------------------

create table public.questions (
  id             bigint generated always as identity primary key,
  account_id     uuid not null references public.accounts (id),
  transaction_id bigint references public.transactions (id),
  message        text not null check (btrim(message) <> ''),
  parent_reply   text,
  status         public.question_status not null default 'open',
  created_at     timestamptz not null default public.app_now(),
  answered_at    timestamptz,
  constraint questions_answered_has_reply check ((status = 'answered') = (parent_reply is not null))
);
create index questions_account_idx on public.questions (account_id);

create table public.wishlist_items (
  id                uuid primary key default gen_random_uuid(),
  account_id        uuid not null references public.accounts (id),
  name              text not null check (btrim(name) <> ''),
  price_cents       bigint check (price_cents > 0),
  link              text,
  photo_url         text,
  stars             smallint not null default 3 check (stars between 1 and 5),
  sort_order        integer not null default 0,
  status            public.wishlist_status not null default 'wanted',
  created_at        timestamptz not null default public.app_now(),
  status_changed_at timestamptz
);
create index wishlist_items_account_idx on public.wishlist_items (account_id, sort_order);

-- The parent-only "Got it" marker. Separate table because RLS hides rows, not columns.
create table public.wishlist_parent_marks (
  wishlist_item_id uuid primary key references public.wishlist_items (id),
  marked_by        uuid,
  marked_at        timestamptz not null default public.app_now(),
  note             text
);

create table public.goals (
  id               bigint generated always as identity primary key,
  account_id       uuid not null references public.accounts (id),
  name             text not null check (btrim(name) <> ''),
  target_cents     bigint not null check (target_cents > 0),
  wishlist_item_id uuid references public.wishlist_items (id),
  created_at       timestamptz not null default public.app_now(),
  reached_at       timestamptz
);
create index goals_account_idx on public.goals (account_id);

create table public.badges (
  id                     bigint generated always as identity primary key,
  account_id             uuid not null references public.accounts (id),
  badge                  text not null check (badge ~ '^[a-z0-9_]+$'),
  unlocks_accessory      text,
  earned_at              timestamptz not null default public.app_now(),
  related_transaction_id bigint references public.transactions (id),
  unique (account_id, badge)
);

create table public.notifications (
  id                 bigint generated always as identity primary key,
  account_id         uuid not null references public.accounts (id),
  type               public.notification_type not null,
  title              text not null check (btrim(title) <> ''),
  body               text not null,
  related_rate_id    bigint references public.rates (id),
  related_request_id bigint references public.requests (id),
  related_gic_id     bigint references public.gic_holdings (id),
  created_at         timestamptz not null default public.app_now(),
  read_at            timestamptz
);
create index notifications_account_idx on public.notifications (account_id, created_at desc);
