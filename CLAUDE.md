# Apex Suite — guide for Claude Code

Apex is a compliance and operations platform for UK light freight (vans up to 3.5t gross weight), built by **KGF Digital**, part of KGF Logistics Group Ltd. Its first customer is **KGF Logistics Ltd**; it will be sold to other UK operators.

Read this file at the start of every session and follow it.

## Product

Five modules share one database:

| Module | Owns | Status |
| --- | --- | --- |
| Duty Shield | Walkaround checks, defects, driver hours (GB domestic rules), incidents, DVSA reports, guides, POD capture | **Building first.** Standalone product and the hook into the suite |
| TMS | Bookings, dispatch, customers, drivers, sub-contractors, Courier Exchange link, jobs, PODs | Later |
| Fleet | Company vehicles, MOT/service/tax/insurance dates, maintenance, fuel, costs | Later |
| Warehouse | Customer stock, goods in, goods out | Later |
| Suite | Cross-module reporting and dashboards | Later |

The websites stay on Base44 for now and will send bookings to TMS through an API endpoint.

Full spec (plans, sign-up flow, KPIs, phased plan): the "Apex Suite Integration & Reporting Spec" doc in the APEX Suite project.

## Stack

- **Database, auth, storage:** Supabase (Postgres). `apex-dev` project is on Free (dummy data only); `apex-live` will be on Pro in the London region (eu-west-2).
- **Driver app:** Expo (React Native), iOS and Android, in `apps/duty-shield-mobile`. Offline first.
- **Web dashboard:** Next.js in `apps/web` (manager dashboard, sign-up, billing, later TMS/Fleet/Warehouse screens).
- **Shared code:** `packages/shared` (database types, validation, constants such as hours limits).
- **Billing:** Stripe, on the web only.
- **Language:** TypeScript everywhere.

## Database rules (non-negotiable)

1. All schema changes are new files in `supabase/migrations/`, named `YYYYMMDDHHMMSS_description.sql`. Never edit a migration that has been run.
2. Every business table has `tenant_id`, `created_at`, `updated_at` and Row Level Security using `public.is_tenant_member(tenant_id)`. New tables follow the pattern in the initial migration.
3. A tenant is the operating company whose vans, drivers and data are recorded (e.g. KGF Logistics Ltd). KGF Digital is the software supplier, never a tenant.
4. Records created on a phone get their UUID on the phone, so offline retries never duplicate.
5. Checks, defects, incidents, hours and DVSA reports are **evidence-grade**: once submitted, never updated or deleted. Corrections are new rows that reference the original.
6. Driver hours limits come from tenant settings (`daily_driving_limit_minutes`, `daily_duty_limit_minutes`), never hard-coded.
7. Reporting views use `security_invoker = true` so RLS applies.
8. Every link between records carries the same tenant: add a `(tenant_id, <column>)` foreign key to the referenced table's `(tenant_id, id)` key for any new link.
9. Access by role (see `20261021140000_duty_shield_foundations.sql`): **drivers** see only their own checks, defects, hours, incidents, PODs, fuel and profile, plus the company's vans, sites and guides; **staff** (owner, admin, planner, fleet_manager, warehouse, viewer) read everything in their company; **viewers** cannot write; only owner, admin and fleet_manager invite people. Use the helpers `is_tenant_staff`, `is_tenant_writer`, `is_tenant_manager` and `current_driver_id`.
10. Corrections: a new row with `corrects_id` pointing at the original (never at another correction) and a `correction_reason`. Read hours through `v_duty_days_current`.
11. Sign-up and joining go through `create_solo_account`, `create_invitation` and `accept_invitation`; apps never insert into `tenants` or `tenant_members` directly. `subscriptions` is written only by server code handling Stripe webhooks.

## Security

- Never commit secrets. Real values live in `.env.local` (git-ignored); `.env.example` lists the names only.
- The Supabase **secret / service role key** is only used in server code, never in the mobile app or browser.
- Driver data is personal data under UK GDPR: collect only what a feature needs, and never log it.

## Conventions

- UK English in all user-facing text (licence, tyre, colour, organisation). Dates as `21 Oct 2026`, 24-hour times, £ and GB postcodes.
- Units: kg, miles, litres.
- Plain, friendly wording for drivers; they use the app in cabs and yards, often on poor signal.
- Keep changes small and explain them in plain English: the owner is not a developer.
- Commit messages: short imperative summary, then a line on why.
