# BaddieLink 🇨🇮

BaddieLink is an 18+ social discovery platform for Côte d’Ivoire, built by LogicalSky. The interface is French-first and localized for XOF, the +225 phone prefix, and the Africa/Abidjan timezone.

## Current implementation

The current web application uses Supabase Auth and the existing Supabase project. The feature branch includes:

- Account signup and login, adult self-declaration, and session restoration.
- Member profiles, discoverability preferences, approved-member discovery, likes, and Côte d’Ivoire-localized reputation display.
- Salons discovery, creation and membership management, including public/private visibility and open/approval join policies. Salon text messaging is not enabled.
- Profile photo uploads to private Supabase Storage, with moderation status controlling public visibility.
- Exhibitions: event discovery, event submissions, organizer applications, event interests, and reporting.
- A separate, server-authorized Admin Console for event, organizer, photo, member, and report moderation.
- Owner-only moderator management and an append-only administrative audit log.
- A default discoverability setting for new accounts. Existing member preferences are preserved.

## Important limitations

This is an actively developed web application, not a completed social network. The following are not implemented as production features yet:

- Rooms/salons, communities, moments/status, and live voice rooms. Their placeholder panels are hidden until functional implementations are ready.
- Production direct messaging. The member message screen is an honest preparation state; no demonstration conversations or message composer are exposed.
- BaddieCoins purchases, wallet transactions, and payments. The wallet is a preparation state; no real balance or payment processing is enabled.
- Formal identity or age verification. Adult access currently relies on a user declaration and is not an official identity check.
- End-to-end encrypted messaging. The OpenMLS browser proof of concept is isolated experimental work and is not integrated, compiled, or approved for production use.

Admin moderation is enforced by database authorization functions and row-level security. Never expose a Supabase service-role key in browser code. A successful static-site deploy does not prove every authenticated workflow has passed end-to-end testing.

## Run locally

Serve the repository root with any static HTTP server and open `index.html`. The app loads Supabase JS v2 from its configured CDN and reads the public project URL/key from `supabase-config.js`. Do not open the file directly with a `file://` URL if browser module or authentication redirect behavior is required.

## Main files

- `index.html` — application structure and member/admin interfaces.
- `style.css` — responsive styling.
- `script.js` — shared navigation and presentation behavior.
- `auth-integration.js` — Supabase authentication, profiles, discovery, events, photo upload, and admin workflows.
- `supabase/migrations/` — committed database migrations. A migration file is not applied to the hosted project merely because it is present in Git.

## Release validation

Use `docs/MANUAL_TEST_PLAN.md` before promoting changes. Preview and production currently share the existing Supabase project, so actions in preview can affect real accounts and records. Use read-only checks unless a real moderation action is explicitly intended. Production deployment is a separate step after branch review and validation.
