# Apex Suite

Compliance and operations software for UK van operators, built by KGF Digital (KGF Logistics Group Ltd).

## What's here

| Folder | Contents |
| --- | --- |
| `apps/duty-shield-mobile` | Duty Shield driver app (Expo, iOS and Android) |
| `apps/web` | Web dashboard for managers, sign-up and billing (Next.js) |
| `packages/shared` | Code shared by the apps: database types, validation, constants |
| `supabase/migrations` | The database, as a series of SQL files run in order |
| `docs` | Notes and decisions |

## Status

- [x] Supabase `apex-dev` project created and initial schema applied
- [ ] Duty Shield MVP (see the spec's "First release" list)

## For developers

See `CLAUDE.md` for the rules every change follows. Copy `.env.example` to `.env.local` and fill in values from the Supabase dashboard; never commit `.env.local`.

© KGF Digital, KGF Logistics Group Ltd. All rights reserved.
