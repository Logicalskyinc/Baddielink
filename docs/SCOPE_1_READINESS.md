# Scope 1 — Core Social Platform Readiness

**Review date:** 2026-11-20  
**Branch:** `scope-1/readiness-closeout`  
**Production:** `https://baddielink.onrender.com`  
**Status:** OPEN — not approved for release or Scope 2 handoff.

## Scope 1 inventory

| Area | Implementation status | Validation status |
|---|---|---|
| Signup, login, session restoration, logout | Implemented in frontend and Supabase Auth integration | Browser end-to-end tests pending |
| Adult declaration | Server RPC and client flow implemented | Auth flow tests pending; declaration is not official age verification |
| Member profiles and profile editing | Implemented | Authenticated update/RLS tests pending |
| Profile photo submission and moderation | Implemented with private storage and approval workflow | Upload/access tests pending |
| People Discovery | Implemented with approved + discoverable filtering | Authenticated visibility and privacy tests pending |
| Likes and mutual-match creation | Implemented with database trigger | Reciprocal concurrency test pending |
| Blocking and member reporting | Implemented | Authenticated interaction tests pending |
| Reputation display | French Côte d'Ivoire labels implemented; database rank keys unchanged | Browser rendering test pending |
| Reputation scoring/award engine | Not implemented | Rules, server-side idempotency and anti-abuse design required |
| Exhibitions and organizer moderation | Implemented foundation | End-to-end tests pending |
| Salons discovery and membership | Implemented foundation; public/private visibility and open/approval membership policies | Authenticated join/rejoin/authorization tests pending |
| Salon text messaging | Not enabled | Deferred to Scope 2 |
| Admin console and moderation | Implemented foundation | Owner/moderator and unauthorized-action tests pending |
| BaddieCoins | Preparation state only; no wallet or payments | Deferred to Scope 4 |
| Direct messages | Honest preparation state; no demo conversations or composer exposed | Deferred to Scope 2 |

## Work completed on this branch

- Recovered the SQL source for all 24 migrations currently recorded in production. Archive files are not to be replayed against the current production database.
- Preserved the two previously approved and applied production security migrations in the archive under their actual live migration versions.
- Re-verified 10 read-only production database invariants:
  - All 18 public tables have RLS enabled.
  - `private.admin_roles` has RLS enabled, no policies, and no direct `anon` or `authenticated` table privileges.
  - Member report creation is constrained to `open`.
  - Event report creation is constrained to `pending`.
  - Salon join and rejoin policies check the membership status against the Salon join policy.
  - The existing Auth account-record trigger remains SECURITY DEFINER with an empty search path.
  - The mutual-like trigger remains installed.
  - Production migration history still contains exactly 24 entries.
- Added two unapplied candidate migrations:
  - `20261119230000_serialize_mutual_like_matching.sql`: pair-scoped transaction advisory locking; two-session concurrency test still required.
  - `20261119233000_strengthen_generated_usernames.sql`: longer UUID-derived hash suffix; read-only format sample check passed, but isolated Auth signup test still required.
- Localized profile and public reputation labels to Nouveau, Initié, Habitué, Confirmé, Référence and Légende. Existing database keys are unchanged.
- Removed static fictional Aminata/Kevin message examples and the message composer from the initial HTML. The authenticated view already renders an honest messaging preparation state.
- Replaced the static demonstration wallet balance with an honest BaddieCoins preparation state. The authenticated view already renders a preparation state.
- Hid unfinished Communities, Moments and Audio discovery tabs/panels.
- Updated README and manual test plan to distinguish implemented foundations from deferred modules and to prohibit test writes against the shared production database.

## Important environment constraint

The Render preview and production site share the same Supabase project. The preview is not an isolated test environment.

Do not create disposable production users, likes, matches, reports, photos, events, Salon memberships, or moderation actions for testing. Do not run write-dependent tests on the preview.

No paid Supabase branch or additional paid infrastructure is authorized. Use an existing free/local isolated test option if available; otherwise record write-dependent checks as blocked rather than touching production data.

## Remaining Scope 1 exit gates

1. Static source validation and browser runtime review for the exact candidate branch.
2. Isolated signup, confirmation, age declaration, login, session restore and logout tests.
3. Profile editing, duplicate username and profile privacy/RLS tests.
4. Photo upload and moderation access tests.
5. Discovery, likes, reciprocal match, block and report tests.
6. Two-session reciprocal-like concurrency test before accepting the candidate migration.
7. Isolated signup-trigger test before accepting the username candidate migration.
8. Salon creation, public/private visibility, open join, approval join, rejoin and role-escalation denial tests.
9. Admin owner/moderator authorization, self-moderation denial and audit-log tests.
10. Mobile layout, keyboard/focus, live-region and browser-console checks.
11. Reputation event catalogue, anti-abuse controls, idempotency and promotion thresholds must be specified before implementing the award engine. Do not invent point values.
12. Final documentation/branch review and explicit release approval.

## Release controls

- This branch is not merged into `main`.
- PR #6 is not to be merged as a Scope 1 release vehicle.
- No production migration is approved by this document.
- No Render deployment or GitHub Actions run is authorized by this document.
- Scope 2 remains on hold until the Scope 1 exit report passes and the project owner explicitly authorizes the handoff.
