-- =====================================================================
-- Duty Shield foundations
--   1. Role helpers (who is staff, who is a driver)
--   2. Composite tenant keys: links can never cross companies
--   3. Corrections and evidence locks for checks, defects, hours, incidents
--   4. Subscriptions, invitations and audit log
--   5. Role-based access: drivers see only their own records
--   6. Sign-up and invitation functions for the apps
--   7. Updated hours view that uses corrected records
-- Run once, after 20261021120000_initial_schema.sql.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. ROLE HELPERS
-- ---------------------------------------------------------------------

create or replace function public.has_tenant_role(tid uuid, roles text[])
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.tenant_members m
    where m.tenant_id = tid and m.user_id = auth.uid() and m.role = any(roles)
  );
$$;

-- Staff can read everything in their company (drivers cannot).
create or replace function public.is_tenant_staff(tid uuid)
returns boolean
language sql stable
set search_path = public
as $$
  select public.has_tenant_role(tid,
    array['owner','admin','planner','fleet_manager','warehouse','viewer']);
$$;

-- Writers can change company records (viewers and drivers cannot).
create or replace function public.is_tenant_writer(tid uuid)
returns boolean
language sql stable
set search_path = public
as $$
  select public.has_tenant_role(tid,
    array['owner','admin','planner','fleet_manager','warehouse']);
$$;

create or replace function public.is_tenant_manager(tid uuid)
returns boolean
language sql stable
set search_path = public
as $$
  select public.has_tenant_role(tid, array['owner','admin','fleet_manager']);
$$;

-- The driver record that belongs to the signed-in user in this company.
create or replace function public.current_driver_id(tid uuid)
returns uuid
language sql stable security definer
set search_path = public
as $$
  select d.id from public.drivers d
  where d.tenant_id = tid and d.user_id = auth.uid() and d.deleted_at is null
  limit 1;
$$;

create unique index drivers_tenant_user_unique
  on public.drivers (tenant_id, user_id) where user_id is not null;

-- ---------------------------------------------------------------------
-- 2. COMPOSITE TENANT KEYS
--    Every link (job -> customer, defect -> vehicle, ...) must stay inside
--    the same company. A (tenant_id, id) key on each linked table plus a
--    matching foreign key on each link column makes the database refuse
--    cross-company links. Empty (null) links are still allowed.
-- ---------------------------------------------------------------------

do $$
declare
  t text;
begin
  foreach t in array array[
    'sites','customers','drivers','subcontractors','vehicles','jobs','job_stops',
    'vehicle_checks','maintenance_events','defects','duty_days','incidents',
    'documents','skus','warehouse_locations'
  ]
  loop
    execute format(
      'alter table public.%I add constraint %I unique (tenant_id, id)',
      t, t || '_tenant_id_id_key');
  end loop;
end;
$$;

do $$
declare
  link text[];
begin
  -- {table, column, referenced table}
  foreach link slice 1 in array array[
    ['drivers','home_site_id','sites'],
    ['vehicles','home_site_id','sites'],
    ['jobs','customer_id','customers'],
    ['job_stops','job_id','jobs'],
    ['job_stops','site_id','sites'],
    ['job_allocations','job_id','jobs'],
    ['job_allocations','driver_id','drivers'],
    ['job_allocations','vehicle_id','vehicles'],
    ['job_allocations','subcontractor_id','subcontractors'],
    ['pods','job_id','jobs'],
    ['pods','job_stop_id','job_stops'],
    ['pods','driver_id','drivers'],
    ['vehicle_checks','vehicle_id','vehicles'],
    ['vehicle_checks','driver_id','drivers'],
    ['maintenance_events','vehicle_id','vehicles'],
    ['defects','vehicle_id','vehicles'],
    ['defects','vehicle_check_id','vehicle_checks'],
    ['defects','reported_by_driver_id','drivers'],
    ['defects','maintenance_event_id','maintenance_events'],
    ['duty_days','driver_id','drivers'],
    ['duty_days','vehicle_id','vehicles'],
    ['duty_activities','duty_day_id','duty_days'],
    ['incidents','driver_id','drivers'],
    ['incidents','vehicle_id','vehicles'],
    ['incidents','job_id','jobs'],
    ['dvsa_reports','incident_id','incidents'],
    ['dvsa_reports','defect_id','defects'],
    ['document_acknowledgements','document_id','documents'],
    ['document_acknowledgements','driver_id','drivers'],
    ['vehicle_compliance','vehicle_id','vehicles'],
    ['fuel_transactions','vehicle_id','vehicles'],
    ['fuel_transactions','driver_id','drivers'],
    ['vehicle_costs','vehicle_id','vehicles'],
    ['skus','customer_id','customers'],
    ['warehouse_locations','site_id','sites'],
    ['stock_movements','site_id','sites'],
    ['stock_movements','customer_id','customers'],
    ['stock_movements','sku_id','skus'],
    ['stock_movements','location_id','warehouse_locations'],
    ['stock_movements','job_id','jobs']
  ]
  loop
    execute format(
      'alter table public.%I add constraint %I foreign key (tenant_id, %I)
         references public.%I (tenant_id, id)',
      link[1], link[1] || '_' || link[2] || '_same_tenant', link[2], link[3]);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 3. CORRECTIONS AND EVIDENCE LOCKS
--    A correction is a new row whose corrects_id points at the ORIGINAL
--    row (never at another correction). The original is never changed.
-- ---------------------------------------------------------------------

alter table public.vehicle_checks add column corrects_id uuid;
alter table public.defects        add column corrects_id uuid;
alter table public.duty_days      add column corrects_id uuid;
alter table public.incidents      add column corrects_id uuid;

alter table public.vehicle_checks add column correction_reason text;
alter table public.defects        add column correction_reason text;
alter table public.duty_days      add column correction_reason text;
alter table public.incidents      add column correction_reason text;

alter table public.vehicle_checks add constraint vehicle_checks_corrects_same_tenant
  foreign key (tenant_id, corrects_id) references public.vehicle_checks (tenant_id, id);
alter table public.defects add constraint defects_corrects_same_tenant
  foreign key (tenant_id, corrects_id) references public.defects (tenant_id, id);
alter table public.duty_days add constraint duty_days_corrects_same_tenant
  foreign key (tenant_id, corrects_id) references public.duty_days (tenant_id, id);
alter table public.incidents add constraint incidents_corrects_same_tenant
  foreign key (tenant_id, corrects_id) references public.incidents (tenant_id, id);

-- One original duty day per driver per date; corrections sit alongside it.
alter table public.duty_days drop constraint duty_days_driver_id_duty_date_key;
create unique index duty_days_one_original_per_day
  on public.duty_days (driver_id, duty_date) where corrects_id is null;

create or replace function public.evidence_guard()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  locked     boolean := true;
  allowed    text[]  := array['updated_at'];
  changed    text[];
  parent_signed boolean;
  target_corrects uuid;
begin
  -- Escape hatch for an administrator handling a legal request in the
  -- SQL editor: run  set local apex.allow_evidence_change = 'on';  first.
  if coalesce(current_setting('apex.allow_evidence_change', true), '') = 'on' then
    return coalesce(new, old);
  end if;

  if tg_op = 'DELETE' then
    raise exception 'Apex: % records are kept as evidence and cannot be deleted', tg_table_name
      using errcode = 'P0001';
  end if;

  if tg_op = 'INSERT' then
    if tg_table_name = 'duty_activities' then
      select d.driver_signed_at is not null into parent_signed
      from public.duty_days d where d.id = new.duty_day_id;
      if parent_signed then
        raise exception 'Apex: this duty day has been signed; add a correction instead'
          using errcode = 'P0001';
      end if;
    elsif (to_jsonb(new) ->> 'corrects_id') is not null then
      execute format('select corrects_id from public.%I where id = $1', tg_table_name)
        into target_corrects using (to_jsonb(new) ->> 'corrects_id')::uuid;
      if target_corrects is not null then
        raise exception 'Apex: a correction must point at the original record'
          using errcode = 'P0001';
      end if;
    end if;
    return new;
  end if;

  -- UPDATE: which fields may still change?
  case tg_table_name
    when 'vehicle_checks' then
      locked := old.completed_at is not null;
    when 'duty_days' then
      locked := old.driver_signed_at is not null;
      allowed := allowed || array['manager_signed_at'];
    when 'duty_activities' then
      select d.driver_signed_at is not null into locked
      from public.duty_days d where d.id = old.duty_day_id;
    when 'defects' then
      allowed := allowed || array['status','vehicle_off_road','maintenance_event_id','fixed_at'];
    when 'incidents' then
      allowed := allowed || array['status','police_ref','insurer_ref','estimated_cost'];
    else
      null;  -- dvsa_reports, pods: nothing may change
  end case;

  if not locked then
    return new;
  end if;

  select coalesce(array_agg(n.key), '{}') into changed
  from jsonb_each(to_jsonb(new)) n
  where n.value is distinct from to_jsonb(old) -> n.key
    and not (n.key = any(allowed));

  if array_length(changed, 1) > 0 then
    raise exception 'Apex: % is evidence; these fields cannot be changed: %. Add a correction instead.',
      tg_table_name, array_to_string(changed, ', ')
      using errcode = 'P0001';
  end if;
  return new;
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array['vehicle_checks','defects','duty_days','duty_activities',
                           'incidents','dvsa_reports','pods']
  loop
    execute format(
      'create trigger evidence_guard before insert or update or delete on public.%I
         for each row execute function public.evidence_guard()', t);
  end loop;
end;
$$;

-- ---------------------------------------------------------------------
-- 4. SUBSCRIPTIONS, INVITATIONS, AUDIT LOG
-- ---------------------------------------------------------------------

-- Written only by the server (Stripe webhooks) using the secret key.
create table public.subscriptions (
  id                      uuid primary key default gen_random_uuid(),
  tenant_id               uuid not null unique references public.tenants(id) on delete cascade,
  plan                    text not null check (plan in ('solo','fleet','suite')),
  status                  text not null default 'trialing'
                            check (status in ('trialing','active','past_due','cancelled')),
  van_allowance           integer not null default 1 check (van_allowance >= 0),
  trial_ends_at           timestamptz,
  current_period_end      timestamptz,
  stripe_customer_id      text unique,
  stripe_subscription_id  text unique,
  created_at              timestamptz not null default now(),
  updated_at              timestamptz not null default now()
);

create table public.invitations (
  id           uuid primary key default gen_random_uuid(),
  tenant_id    uuid not null references public.tenants(id) on delete cascade,
  email        text not null,
  role         text not null check (role in
                 ('admin','planner','fleet_manager','warehouse','driver','viewer')),
  driver_id    uuid,                  -- link to an existing driver record, if any
  token_hash   text not null unique,  -- only a hash is stored; the token is emailed
  invited_by   uuid references auth.users(id),
  expires_at   timestamptz not null default now() + interval '7 days',
  accepted_at  timestamptz,
  accepted_by  uuid references auth.users(id),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now(),
  constraint invitations_driver_same_tenant
    foreign key (tenant_id, driver_id) references public.drivers (tenant_id, id)
);
create index on public.invitations (tenant_id);
create index on public.invitations (lower(email));

create table public.audit_log (
  id          bigint generated always as identity primary key,
  tenant_id   uuid not null references public.tenants(id) on delete cascade,
  table_name  text not null,
  record_id   text not null,
  action      text not null check (action in ('INSERT','UPDATE','DELETE')),
  changed_by  uuid,
  changed_at  timestamptz not null default now(),
  old_data    jsonb,
  new_data    jsonb
);
create index on public.audit_log (tenant_id, changed_at desc);
create index on public.audit_log (table_name, record_id);

create or replace function public.write_audit_log()
returns trigger
language plpgsql security definer
set search_path = public
as $$
declare
  r jsonb := to_jsonb(coalesce(new, old));
begin
  insert into public.audit_log (tenant_id, table_name, record_id, action, changed_by, old_data, new_data)
  values (
    (r ->> 'tenant_id')::uuid,
    tg_table_name,
    coalesce(r ->> 'id', r ->> 'user_id'),
    tg_op,
    auth.uid(),
    case when tg_op in ('UPDATE','DELETE') then to_jsonb(old) end,
    case when tg_op in ('INSERT','UPDATE') then to_jsonb(new) end
  );
  return coalesce(new, old);
end;
$$;

do $$
declare
  t text;
begin
  foreach t in array array['tenant_members','drivers','vehicles','subscriptions','invitations',
                           'vehicle_checks','defects','duty_days','incidents','dvsa_reports']
  loop
    execute format(
      'create trigger write_audit_log after insert or update or delete on public.%I
         for each row execute function public.write_audit_log()', t);
  end loop;
  foreach t in array array['subscriptions','invitations']
  loop
    execute format(
      'create trigger set_updated_at before update on public.%I
         for each row execute function public.set_updated_at()', t);
  end loop;
end;
$$;

alter table public.subscriptions enable row level security;
alter table public.invitations   enable row level security;
alter table public.audit_log     enable row level security;

create policy subscriptions_staff_read on public.subscriptions
  for select to authenticated using (public.is_tenant_staff(tenant_id));

create policy invitations_manager_all on public.invitations
  for all to authenticated
  using (public.is_tenant_manager(tenant_id))
  with check (public.is_tenant_manager(tenant_id));

create policy audit_owner_read on public.audit_log
  for select to authenticated using (public.has_tenant_role(tenant_id, array['owner','admin']));

-- ---------------------------------------------------------------------
-- 5. ROLE-BASED ACCESS
--    Replaces the single company-wide rule from the first migration.
-- ---------------------------------------------------------------------

-- Staff can also see who else is in their company.
create policy members_staff_read on public.tenant_members
  for select to authenticated using (public.is_tenant_staff(tenant_id));

do $$
declare
  t   text;
  rec text[];
begin
  -- A. Office-only tables: staff read, writers write, drivers see nothing.
  foreach t in array array[
    'customers','subcontractors','jobs','job_stops','job_allocations',
    'maintenance_events','dvsa_reports','vehicle_compliance','vehicle_costs',
    'skus','warehouse_locations','stock_movements'
  ]
  loop
    execute format('drop policy tenant_isolation on public.%I', t);
    execute format('create policy staff_read on public.%I for select to authenticated
                      using (public.is_tenant_staff(tenant_id))', t);
    execute format('create policy writer_insert on public.%I for insert to authenticated
                      with check (public.is_tenant_writer(tenant_id))', t);
    execute format('create policy writer_update on public.%I for update to authenticated
                      using (public.is_tenant_writer(tenant_id))
                      with check (public.is_tenant_writer(tenant_id))', t);
    execute format('create policy writer_delete on public.%I for delete to authenticated
                      using (public.is_tenant_writer(tenant_id))', t);
  end loop;

  -- B. Shared reference tables: everyone in the company reads, writers write.
  foreach t in array array['sites','vehicles','documents']
  loop
    execute format('drop policy tenant_isolation on public.%I', t);
    execute format('create policy member_read on public.%I for select to authenticated
                      using (public.is_tenant_member(tenant_id))', t);
    execute format('create policy writer_insert on public.%I for insert to authenticated
                      with check (public.is_tenant_writer(tenant_id))', t);
    execute format('create policy writer_update on public.%I for update to authenticated
                      using (public.is_tenant_writer(tenant_id))
                      with check (public.is_tenant_writer(tenant_id))', t);
    execute format('create policy writer_delete on public.%I for delete to authenticated
                      using (public.is_tenant_writer(tenant_id))', t);
  end loop;

  -- C. Driver records: a driver sees and adds only their own; staff see all.
  foreach rec slice 1 in array array[
    ['vehicle_checks','driver_id'],
    ['defects','reported_by_driver_id'],
    ['duty_days','driver_id'],
    ['incidents','driver_id'],
    ['pods','driver_id'],
    ['document_acknowledgements','driver_id'],
    ['fuel_transactions','driver_id']
  ]
  loop
    t := rec[1];
    execute format('drop policy tenant_isolation on public.%I', t);
    execute format('create policy own_or_staff_read on public.%I for select to authenticated
                      using (public.is_tenant_staff(tenant_id)
                             or %I = public.current_driver_id(tenant_id))', t, rec[2]);
    execute format('create policy own_or_writer_insert on public.%I for insert to authenticated
                      with check (public.is_tenant_writer(tenant_id)
                                  or (public.is_tenant_member(tenant_id)
                                      and %I = public.current_driver_id(tenant_id)))', t, rec[2]);
    execute format('create policy own_or_writer_update on public.%I for update to authenticated
                      using (public.is_tenant_writer(tenant_id)
                             or %I = public.current_driver_id(tenant_id))
                      with check (public.is_tenant_writer(tenant_id)
                                  or %I = public.current_driver_id(tenant_id))', t, rec[2], rec[2]);
    execute format('create policy writer_delete on public.%I for delete to authenticated
                      using (public.is_tenant_writer(tenant_id))', t);
  end loop;
end;
$$;

-- D. Duty activities follow their duty day.
create or replace function public.owns_duty_day(day_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.duty_days d
    where d.id = day_id and d.driver_id = public.current_driver_id(d.tenant_id)
  );
$$;

drop policy tenant_isolation on public.duty_activities;
create policy own_or_staff_read on public.duty_activities for select to authenticated
  using (public.is_tenant_staff(tenant_id) or public.owns_duty_day(duty_day_id));
create policy own_or_writer_insert on public.duty_activities for insert to authenticated
  with check (public.is_tenant_writer(tenant_id)
              or (public.is_tenant_member(tenant_id) and public.owns_duty_day(duty_day_id)));
create policy own_or_writer_update on public.duty_activities for update to authenticated
  using (public.is_tenant_writer(tenant_id) or public.owns_duty_day(duty_day_id))
  with check (public.is_tenant_writer(tenant_id) or public.owns_duty_day(duty_day_id));
create policy writer_delete on public.duty_activities for delete to authenticated
  using (public.is_tenant_writer(tenant_id));

-- E. Driver profiles: a driver sees only their own; writers manage all.
drop policy tenant_isolation on public.drivers;
create policy own_or_staff_read on public.drivers for select to authenticated
  using (public.is_tenant_staff(tenant_id) or user_id = auth.uid());
create policy writer_insert on public.drivers for insert to authenticated
  with check (public.is_tenant_writer(tenant_id));
create policy writer_update on public.drivers for update to authenticated
  using (public.is_tenant_writer(tenant_id))
  with check (public.is_tenant_writer(tenant_id));
create policy writer_delete on public.drivers for delete to authenticated
  using (public.is_tenant_writer(tenant_id));

-- ---------------------------------------------------------------------
-- 6. SIGN-UP AND INVITATION FUNCTIONS (called by the apps)
-- ---------------------------------------------------------------------

-- Solo sign-up: creates the driver's own company, makes them owner,
-- creates their driver profile and a 30-day Solo trial. Returns tenant id.
create or replace function public.create_solo_account(
  company_name text, first_name text, last_name text
)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  tid uuid;
begin
  if uid is null then
    raise exception 'Apex: sign in first' using errcode = 'P0001';
  end if;
  if coalesce(trim(company_name), '') = '' then
    raise exception 'Apex: a company or trading name is required' using errcode = 'P0001';
  end if;

  insert into public.tenants (name) values (trim(company_name)) returning id into tid;
  insert into public.tenant_members (tenant_id, user_id, role) values (tid, uid, 'owner');
  insert into public.drivers (tenant_id, user_id, first_name, last_name, email, employment_type)
    select tid, uid, trim(first_name), trim(last_name), u.email, 'self_employed'
    from auth.users u where u.id = uid;
  insert into public.subscriptions (tenant_id, plan, status, van_allowance, trial_ends_at)
    values (tid, 'solo', 'trialing', 1, now() + interval '30 days');
  return tid;
end;
$$;

-- Managers create an invitation; returns the one-time token to send.
create or replace function public.create_invitation(
  tid uuid, invite_email text, invite_role text, for_driver_id uuid default null
)
returns text
language plpgsql security definer
set search_path = public
as $$
declare
  token text := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
begin
  if not public.is_tenant_manager(tid) then
    raise exception 'Apex: only owners, admins and fleet managers can invite people'
      using errcode = 'P0001';
  end if;
  insert into public.invitations (tenant_id, email, role, driver_id, token_hash, invited_by)
  values (tid, lower(trim(invite_email)), invite_role, for_driver_id,
          encode(sha256(convert_to(token, 'UTF8')), 'hex'), auth.uid());
  return token;
end;
$$;

-- The invited person accepts while signed in with the invited email.
-- Drivers are linked to their driver profile (created if needed).
create or replace function public.accept_invitation(token text)
returns uuid
language plpgsql security definer
set search_path = public
as $$
declare
  uid    uuid := auth.uid();
  inv    public.invitations%rowtype;
  uemail text;
begin
  if uid is null then
    raise exception 'Apex: sign in first' using errcode = 'P0001';
  end if;

  select * into inv from public.invitations
  where token_hash = encode(sha256(convert_to(token, 'UTF8')), 'hex')
  for update;

  if not found or inv.accepted_at is not null or inv.expires_at < now() then
    raise exception 'Apex: this invitation is not valid or has expired' using errcode = 'P0001';
  end if;

  select lower(email) into uemail from auth.users where id = uid;
  if uemail is distinct from inv.email then
    raise exception 'Apex: sign in with the email address the invitation was sent to'
      using errcode = 'P0001';
  end if;

  insert into public.tenant_members (tenant_id, user_id, role)
  values (inv.tenant_id, uid, inv.role)
  on conflict (tenant_id, user_id) do nothing;

  if inv.role = 'driver' then
    if inv.driver_id is not null then
      update public.drivers set user_id = uid
      where id = inv.driver_id and tenant_id = inv.tenant_id and user_id is null;
    elsif public.current_driver_id(inv.tenant_id) is null then
      insert into public.drivers (tenant_id, user_id, first_name, last_name, email)
      values (inv.tenant_id, uid, '', '', uemail);
    end if;
  end if;

  update public.invitations set accepted_at = now(), accepted_by = uid where id = inv.id;
  return inv.tenant_id;
end;
$$;

revoke execute on function public.create_solo_account(text, text, text) from public, anon;
revoke execute on function public.create_invitation(uuid, text, text, uuid) from public, anon;
revoke execute on function public.accept_invitation(text) from public, anon;
grant execute on function public.create_solo_account(text, text, text) to authenticated;
grant execute on function public.create_invitation(uuid, text, text, uuid) to authenticated;
grant execute on function public.accept_invitation(text) to authenticated;

-- ---------------------------------------------------------------------
-- 7. HOURS VIEW USES THE LATEST VERSION OF EACH DAY
-- ---------------------------------------------------------------------

create view public.v_duty_days_current with (security_invoker = true) as
select distinct on (coalesce(d.corrects_id, d.id)) d.*
from public.duty_days d
order by coalesce(d.corrects_id, d.id), d.created_at desc;

create or replace view public.v_driver_hours_flags with (security_invoker = true) as
select
  d.tenant_id, d.driver_id, dr.first_name, dr.last_name, d.duty_date,
  d.driving_minutes, d.duty_minutes,
  d.driving_minutes > t.daily_driving_limit_minutes as driving_over_limit,
  d.duty_minutes    > t.daily_duty_limit_minutes    as duty_over_limit
from public.v_duty_days_current d
join public.drivers dr on dr.id = d.driver_id
join public.tenants t  on t.id  = d.tenant_id;
