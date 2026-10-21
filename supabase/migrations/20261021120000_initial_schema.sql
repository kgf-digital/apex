-- =====================================================================
-- Apex Suite: unified Supabase (Postgres) schema
-- One database for Apex TMS, Duty Shield, Fleet, Warehouse and Suite.
-- Multi-tenant from day one: every business row carries tenant_id and
-- Row Level Security limits each user to the tenants they belong to.
--
-- Run once in a NEW Supabase project: Dashboard > SQL Editor > paste > Run.
-- Version 1 · 2026-10-21 · prepared for KGF Logistics Ltd
-- =====================================================================

create extension if not exists pgcrypto;

-- ---------------------------------------------------------------------
-- 0. Shared helpers
-- ---------------------------------------------------------------------

create or replace function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

-- ---------------------------------------------------------------------
-- 1. CORE (owned by Apex Suite)
-- ---------------------------------------------------------------------

create table public.tenants (
  id                          uuid primary key default gen_random_uuid(),
  name                        text not null,
  company_number              text,
  vat_number                  text,
  -- Hours limits are settings, not hard-coded, so they can follow
  -- current DVSA guidance. Defaults reflect GB domestic rules
  -- (10h driving, 11h duty per day) - confirm before relying on them.
  daily_driving_limit_minutes integer not null default 600,
  daily_duty_limit_minutes    integer not null default 660,
  created_at                  timestamptz not null default now(),
  updated_at                  timestamptz not null default now()
);

create table public.tenant_members (
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  user_id     uuid not null references auth.users(id) on delete cascade,
  role        text not null check (role in
                ('owner','admin','planner','fleet_manager','warehouse','driver','viewer')),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  primary key (tenant_id, user_id)
);

create table public.sites (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id),
  name              text not null,
  site_type         text not null check (site_type in ('depot','warehouse','office','other')),
  address_line1     text,
  address_line2     text,
  town              text,
  postcode          text,
  legacy_base44_id  text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz
);

-- ---------------------------------------------------------------------
-- 2. MASTER DATA (customers, drivers, subcontractors owned by TMS;
--    vehicles owned by Fleet)
-- ---------------------------------------------------------------------

create table public.customers (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id),
  account_code      text not null,
  name              text not null,
  billing_email     text,
  phone             text,
  address_line1     text,
  address_line2     text,
  town              text,
  postcode          text,
  payment_terms_days integer default 30,
  is_active         boolean not null default true,
  legacy_base44_id  text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz,
  unique (tenant_id, account_code)
);

create table public.drivers (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenants(id),
  user_id               uuid references auth.users(id),   -- set when the driver has a login
  first_name            text not null,
  last_name             text not null,
  phone                 text,
  email                 text,
  employment_type       text not null default 'employee'
                          check (employment_type in ('employee','agency','self_employed')),
  licence_number        text,
  licence_categories    text[],
  licence_expiry        date,
  licence_last_checked  date,
  home_site_id          uuid references public.sites(id),
  is_active             boolean not null default true,
  legacy_base44_id      text,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now(),
  deleted_at            timestamptz
);

create table public.subcontractors (
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenants(id),
  company_name              text not null,
  contact_name              text,
  phone                     text,
  email                     text,
  courier_exchange_ref      text,
  git_insurance_expiry      date,   -- goods in transit
  hire_reward_insurance_expiry date,
  rating                    smallint check (rating between 1 and 5),
  is_active                 boolean not null default true,
  legacy_base44_id          text,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  deleted_at                timestamptz
);

create table public.vehicles (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id),
  registration      text not null,
  make              text,
  model             text,
  body_type         text check (body_type in
                      ('small_van','swb','mwb','lwb','xlwb','luton','dropside','other')),
  fuel_type         text check (fuel_type in ('diesel','petrol','electric','hybrid','other')),
  gross_weight_kg   integer check (gross_weight_kg <= 3500),
  payload_kg        integer,
  ownership         text not null default 'owned'
                      check (ownership in ('owned','leased','finance','hired')),
  acquired_on       date,
  disposed_on       date,
  home_site_id      uuid references public.sites(id),
  status            text not null default 'available'
                      check (status in ('available','in_use','vor','disposed')),
  current_odometer  integer,
  legacy_base44_id  text,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  deleted_at        timestamptz
);
create unique index vehicles_tenant_reg_live
  on public.vehicles (tenant_id, registration) where deleted_at is null;

-- ---------------------------------------------------------------------
-- 3. TMS: bookings, dispatch, allocation, POD
-- ---------------------------------------------------------------------

create table public.jobs (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenants(id),
  job_number          text not null,
  customer_id         uuid not null references public.customers(id),
  booking_source      text not null check (booking_source in
                        ('website','manual','courier_exchange','duty_shield','api')),
  status              text not null default 'booked' check (status in
                        ('quoted','booked','allocated','collected','in_transit',
                         'delivered','failed','cancelled')),
  service_level       text check (service_level in ('same_day','next_day','timed','economy','dedicated')),
  customer_reference  text,
  goods_description   text,
  pieces              integer,
  weight_kg           numeric(10,2),
  price_net           numeric(10,2),
  vat_rate            numeric(5,2) default 20.00,
  courier_exchange_ref text,
  booked_at           timestamptz not null default now(),
  legacy_base44_id    text,
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  deleted_at          timestamptz,
  unique (tenant_id, job_number)
);

-- Collections and deliveries; supports multi-drop.
create table public.job_stops (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id),
  job_id          uuid not null references public.jobs(id) on delete cascade,
  sequence        smallint not null,
  stop_type       text not null check (stop_type in ('collection','delivery')),
  site_id         uuid references public.sites(id),   -- when the stop is one of our own sites
  contact_name    text,
  contact_phone   text,
  address_line1   text,
  address_line2   text,
  town            text,
  postcode        text not null,
  window_from     timestamptz,
  window_to       timestamptz,
  arrived_at      timestamptz,
  completed_at    timestamptz,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  unique (job_id, sequence)
);

create table public.job_allocations (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenants(id),
  job_id              uuid not null references public.jobs(id) on delete cascade,
  resource_type       text not null check (resource_type in ('own_driver','subcontractor')),
  driver_id           uuid references public.drivers(id),
  vehicle_id          uuid references public.vehicles(id),
  subcontractor_id    uuid references public.subcontractors(id),
  subcontract_cost_net numeric(10,2),
  status              text not null default 'active' check (status in ('active','replaced','cancelled')),
  allocated_at        timestamptz not null default now(),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now(),
  check (
    (resource_type = 'own_driver'    and driver_id is not null and subcontractor_id is null) or
    (resource_type = 'subcontractor' and subcontractor_id is not null)
  )
);

create table public.pods (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id),
  job_id          uuid not null references public.jobs(id),
  job_stop_id     uuid references public.job_stops(id),
  driver_id       uuid references public.drivers(id),
  outcome         text not null check (outcome in ('delivered','partial','failed')),
  failure_reason  text,
  recipient_name  text,
  signature_path  text,      -- Supabase Storage path
  photo_paths     text[],
  latitude        numeric(9,6),
  longitude       numeric(9,6),
  captured_at     timestamptz not null default now(),
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

-- ---------------------------------------------------------------------
-- 4. DUTY SHIELD: checks, defects, hours, incidents, DVSA, guides
-- ---------------------------------------------------------------------

create table public.vehicle_checks (
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id),
  vehicle_id    uuid not null references public.vehicles(id),
  driver_id     uuid not null references public.drivers(id),
  check_type    text not null default 'daily_walkaround'
                  check (check_type in ('daily_walkaround','weekly','handover')),
  odometer      integer,
  result        text not null check (result in ('pass','advisory','fail')),
  answers       jsonb,      -- the checklist items and responses
  started_at    timestamptz not null default now(),
  completed_at  timestamptz,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

create table public.maintenance_events (   -- Fleet; declared here because defects link to it
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id),
  vehicle_id    uuid not null references public.vehicles(id),
  event_type    text not null check (event_type in ('service','repair','tyres','mot','bodywork','other')),
  supplier      text,
  off_road_from timestamptz,
  returned_at   timestamptz,
  odometer      integer,
  cost_net      numeric(10,2),
  invoice_ref   text,
  notes         text,
  legacy_base44_id text,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  deleted_at    timestamptz
);

create table public.defects (
  id                    uuid primary key default gen_random_uuid(),
  tenant_id             uuid not null references public.tenants(id),
  vehicle_id            uuid not null references public.vehicles(id),
  vehicle_check_id      uuid references public.vehicle_checks(id),
  reported_by_driver_id uuid references public.drivers(id),
  category              text not null,
  description           text not null,
  severity              text not null check (severity in ('minor','major','dangerous')),
  vehicle_off_road      boolean not null default false,
  status                text not null default 'open'
                          check (status in ('open','acknowledged','in_repair','fixed','closed')),
  photo_paths           text[],
  maintenance_event_id  uuid references public.maintenance_events(id),
  reported_at           timestamptz not null default now(),
  fixed_at              timestamptz,
  created_at            timestamptz not null default now(),
  updated_at            timestamptz not null default now()
);

create table public.duty_days (
  id                uuid primary key default gen_random_uuid(),
  tenant_id         uuid not null references public.tenants(id),
  driver_id         uuid not null references public.drivers(id),
  duty_date         date not null,
  vehicle_id        uuid references public.vehicles(id),
  duty_start        timestamptz,
  duty_end          timestamptz,
  driving_minutes   integer not null default 0,
  duty_minutes      integer not null default 0,
  break_minutes     integer not null default 0,
  source            text not null default 'app' check (source in ('app','manual','import')),
  driver_signed_at  timestamptz,
  manager_signed_at timestamptz,
  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),
  unique (driver_id, duty_date)
);

create table public.duty_activities (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id),
  duty_day_id  uuid not null references public.duty_days(id) on delete cascade,
  activity     text not null check (activity in ('driving','other_work','break','rest')),
  started_at   timestamptz not null,
  ended_at     timestamptz,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table public.incidents (
  id                  uuid primary key default gen_random_uuid(),
  tenant_id           uuid not null references public.tenants(id),
  occurred_at         timestamptz not null,
  driver_id           uuid references public.drivers(id),
  vehicle_id          uuid references public.vehicles(id),
  job_id              uuid references public.jobs(id),
  incident_type       text not null check (incident_type in
                        ('collision','near_miss','injury','goods_damage','theft','other')),
  description         text not null,
  location_text       text,
  third_party_involved boolean not null default false,
  police_ref          text,
  insurer_ref         text,
  estimated_cost      numeric(10,2),
  status              text not null default 'open' check (status in ('open','investigating','closed')),
  photo_paths         text[],
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table public.dvsa_reports (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id),
  incident_id    uuid references public.incidents(id),
  defect_id      uuid references public.defects(id),
  report_type    text not null,
  reference      text,
  submitted_by   uuid references auth.users(id),
  submitted_at   timestamptz not null default now(),
  payload        jsonb,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table public.documents (   -- guides and instructions
  id                        uuid primary key default gen_random_uuid(),
  tenant_id                 uuid not null references public.tenants(id),
  title                     text not null,
  category                  text,
  storage_path              text not null,
  version                   integer not null default 1,
  requires_acknowledgement  boolean not null default false,
  published_at              timestamptz,
  created_at                timestamptz not null default now(),
  updated_at                timestamptz not null default now(),
  deleted_at                timestamptz
);

create table public.document_acknowledgements (
  tenant_id        uuid not null references public.tenants(id),
  document_id      uuid not null references public.documents(id) on delete cascade,
  driver_id        uuid not null references public.drivers(id),
  document_version integer not null,
  acknowledged_at  timestamptz not null default now(),
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  primary key (document_id, driver_id, document_version)
);

-- ---------------------------------------------------------------------
-- 5. FLEET: compliance dates, fuel, running costs
-- ---------------------------------------------------------------------

create table public.vehicle_compliance (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id),
  vehicle_id      uuid not null references public.vehicles(id),
  item            text not null check (item in
                    ('mot','service','vehicle_tax','insurance','lease_end','other')),
  due_date        date not null,
  completed_date  date,
  reference       text,
  cost_net        numeric(10,2),
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);

create table public.fuel_transactions (
  id             uuid primary key default gen_random_uuid(),
  tenant_id      uuid not null references public.tenants(id),
  vehicle_id     uuid not null references public.vehicles(id),
  driver_id      uuid references public.drivers(id),
  transacted_at  timestamptz not null,
  litres         numeric(8,2),
  kwh            numeric(8,2),   -- EV charging
  cost_net       numeric(10,2) not null,
  odometer       integer,
  card_ref       text,
  created_at     timestamptz not null default now(),
  updated_at     timestamptz not null default now()
);

create table public.vehicle_costs (   -- fixed costs for cost-per-mile
  id            uuid primary key default gen_random_uuid(),
  tenant_id     uuid not null references public.tenants(id),
  vehicle_id    uuid not null references public.vehicles(id),
  cost_type     text not null check (cost_type in ('lease','finance','insurance','tax','depreciation','other')),
  period_start  date not null,
  period_end    date not null,
  amount_net    numeric(10,2) not null,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  check (period_end >= period_start)
);

-- ---------------------------------------------------------------------
-- 6. WAREHOUSE: customer stock and movements
-- ---------------------------------------------------------------------

create table public.skus (
  id               uuid primary key default gen_random_uuid(),
  tenant_id        uuid not null references public.tenants(id),
  customer_id      uuid not null references public.customers(id),
  sku_code         text not null,
  description      text,
  unit_of_measure  text not null default 'each',
  unit_weight_kg   numeric(10,3),
  legacy_base44_id text,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now(),
  deleted_at       timestamptz,
  unique (tenant_id, customer_id, sku_code)
);

create table public.warehouse_locations (
  id          uuid primary key default gen_random_uuid(),
  tenant_id   uuid not null references public.tenants(id),
  site_id     uuid not null references public.sites(id),
  code        text not null,   -- e.g. A-01-03
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (site_id, code)
);

create table public.stock_movements (
  id              uuid primary key default gen_random_uuid(),
  tenant_id       uuid not null references public.tenants(id),
  site_id         uuid not null references public.sites(id),
  customer_id     uuid not null references public.customers(id),
  sku_id          uuid not null references public.skus(id),
  location_id     uuid references public.warehouse_locations(id),
  movement_type   text not null check (movement_type in ('goods_in','goods_out','adjustment','transfer')),
  quantity_delta  integer not null,   -- positive in, negative out
  job_id          uuid references public.jobs(id),   -- goods out linked to the delivery job
  reference       text,               -- customer PO / ASN / order no.
  moved_at        timestamptz not null default now(),
  recorded_by     uuid references auth.users(id),
  notes           text,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  check (
    (movement_type = 'goods_in'  and quantity_delta > 0) or
    (movement_type = 'goods_out' and quantity_delta < 0) or
    (movement_type in ('adjustment','transfer'))
  )
);

-- ---------------------------------------------------------------------
-- 7. INDEXES on the joins reports use most
-- ---------------------------------------------------------------------

create index on public.jobs (tenant_id, status);
create index on public.jobs (customer_id);
create index on public.job_stops (job_id);
create index on public.job_allocations (job_id);
create index on public.job_allocations (driver_id);
create index on public.job_allocations (vehicle_id);
create index on public.pods (job_id);
create index on public.vehicle_checks (vehicle_id, started_at);
create index on public.defects (vehicle_id, status);
create index on public.duty_days (tenant_id, duty_date);
create index on public.incidents (tenant_id, occurred_at);
create index on public.vehicle_compliance (vehicle_id, due_date);
create index on public.fuel_transactions (vehicle_id, transacted_at);
create index on public.maintenance_events (vehicle_id);
create index on public.stock_movements (customer_id, sku_id);
create index on public.stock_movements (job_id);

-- ---------------------------------------------------------------------
-- 8. SECURITY: tenant isolation with Row Level Security
-- ---------------------------------------------------------------------

create or replace function public.is_tenant_member(tid uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1 from public.tenant_members m
    where m.tenant_id = tid and m.user_id = auth.uid()
  );
$$;

alter table public.tenants enable row level security;
create policy tenants_member_read on public.tenants
  for select to authenticated using (public.is_tenant_member(id));

alter table public.tenant_members enable row level security;
create policy members_read_own on public.tenant_members
  for select to authenticated using (user_id = auth.uid());

create trigger set_updated_at before update on public.tenants
  for each row execute function public.set_updated_at();
create trigger set_updated_at before update on public.tenant_members
  for each row execute function public.set_updated_at();

-- Same rules for every business table: updated_at trigger, RLS on,
-- and a policy that only lets members of the row's tenant read or write it.
do $$
declare
  t text;
begin
  foreach t in array array[
    'sites','customers','drivers','subcontractors','vehicles',
    'jobs','job_stops','job_allocations','pods',
    'vehicle_checks','maintenance_events','defects','duty_days','duty_activities',
    'incidents','dvsa_reports','documents','document_acknowledgements',
    'vehicle_compliance','fuel_transactions','vehicle_costs',
    'skus','warehouse_locations','stock_movements'
  ]
  loop
    execute format(
      'create trigger set_updated_at before update on public.%I
         for each row execute function public.set_updated_at()', t);
    execute format('alter table public.%I enable row level security', t);
    execute format(
      'create policy tenant_isolation on public.%I for all to authenticated
         using (public.is_tenant_member(tenant_id))
         with check (public.is_tenant_member(tenant_id))', t);
    execute format('create index on public.%I (tenant_id)', t);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 9. REPORTING VIEWS (respect RLS via security_invoker)
-- ---------------------------------------------------------------------

-- Revenue and subcontract cost per job. Fleet cost per mile is added
-- once mileage per job is captured (next version).
create view public.v_job_margin with (security_invoker = true) as
select
  j.tenant_id,
  j.id            as job_id,
  j.job_number,
  j.customer_id,
  c.name          as customer_name,
  j.status,
  j.booked_at,
  j.price_net     as revenue_net,
  coalesce(sum(a.subcontract_cost_net) filter (where a.status = 'active'), 0) as subcontract_cost_net,
  j.price_net - coalesce(sum(a.subcontract_cost_net) filter (where a.status = 'active'), 0) as margin_before_fleet_net,
  bool_or(a.resource_type = 'subcontractor' and a.status = 'active') as is_subcontracted
from public.jobs j
join public.customers c on c.id = j.customer_id
left join public.job_allocations a on a.job_id = j.id
where j.deleted_at is null
group by j.tenant_id, j.id, j.job_number, j.customer_id, c.name, j.status, j.booked_at, j.price_net;

create view public.v_stock_on_hand with (security_invoker = true) as
select
  m.tenant_id, m.site_id, m.customer_id, m.sku_id,
  s.sku_code, s.description,
  sum(m.quantity_delta) as quantity_on_hand,
  max(m.moved_at)       as last_movement_at
from public.stock_movements m
join public.skus s on s.id = m.sku_id
group by m.tenant_id, m.site_id, m.customer_id, m.sku_id, s.sku_code, s.description;

create view public.v_compliance_due with (security_invoker = true) as
select
  vc.tenant_id, vc.vehicle_id, v.registration, vc.item, vc.due_date,
  (vc.due_date - current_date) as days_until_due
from public.vehicle_compliance vc
join public.vehicles v on v.id = vc.vehicle_id
where vc.completed_date is null
  and v.deleted_at is null
  and vc.due_date <= current_date + 30;

create view public.v_driver_hours_flags with (security_invoker = true) as
select
  d.tenant_id, d.driver_id, dr.first_name, dr.last_name, d.duty_date,
  d.driving_minutes, d.duty_minutes,
  d.driving_minutes > t.daily_driving_limit_minutes as driving_over_limit,
  d.duty_minutes    > t.daily_duty_limit_minutes    as duty_over_limit
from public.duty_days d
join public.drivers dr on dr.id = d.driver_id
join public.tenants t  on t.id  = d.tenant_id;

create view public.v_open_defects with (security_invoker = true) as
select
  df.tenant_id, df.vehicle_id, v.registration, df.severity, df.vehicle_off_road,
  df.status, df.reported_at,
  now() - df.reported_at as open_for
from public.defects df
join public.vehicles v on v.id = df.vehicle_id
where df.status not in ('fixed','closed');

-- ---------------------------------------------------------------------
-- 10. FIRST TENANT (run after creating your own login in Supabase Auth)
-- ---------------------------------------------------------------------
-- insert into public.tenants (name, company_number) values ('KGF Logistics Ltd', '<company no.>');
-- insert into public.tenant_members (tenant_id, user_id, role)
--   select t.id, u.id, 'owner' from public.tenants t, auth.users u
--   where t.name = 'KGF Logistics Ltd' and u.email = '<your email>';
