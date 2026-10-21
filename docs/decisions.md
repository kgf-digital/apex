# Decisions

| Date | Decision | Why |
| --- | --- | --- |
| 21 Oct 2026 | Rebuild Apex off Base44 on Supabase + Expo + Next.js, in one repository | Control, predictable cost, one database for cross-app reporting, saleable IP |
| 21 Oct 2026 | KGF Digital (KGF Logistics Group Ltd) owns the software and accounts; KGF Logistics Ltd is the first tenant | Keeps IP with the software business; operators are tenants |
| 21 Oct 2026 | Duty Shield is built first | Standalone product for UK van drivers and the hook into the suite |
| 21 Oct 2026 | `apex-dev` on Supabase Free (region chosen by Supabase, Ireland); `apex-live` on Pro in London | Specific regions need Pro; dev holds dummy data only |
| 21 Oct 2026 | Websites stay on Base44 for now | Bookings will reach TMS through an API endpoint |
