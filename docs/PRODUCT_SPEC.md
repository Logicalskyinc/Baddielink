# BaddieLink Product Specification

**Version:** 1.1  
**Status:** Approved product direction; implementation in progress  
**Market:** Côte d'Ivoire first  
**Organization:** LogicalSky

## 1. Product vision

BaddieLink is an 18+ social discovery and communication platform inspired by the strongest social mechanics of classic 2go. It is not a clone of 2go and is not limited to dating. Members should be able to meet people, make friends, build relationships, participate in communities, join conversations and develop a trusted social identity.

The product should remain useful even when a member is not seeking a romantic relationship.

## 2. Product decisions

- French-first user experience, localized for Côte d'Ivoire.
- Initial country: Côte d'Ivoire; country code `CI`, phone prefix `+225`, currency `XOF / FCFA`, timezone `Africa/Abidjan`, distances in kilometres.
- Minimum age: 18+.
- Public and private rooms.
- Persistent platform profiles with optional room-level display anonymity.
- BaddieCoins for virtual gifts and premium features.
- Full social experience: discovery, friendships, dating, direct messaging, rooms, moments, communities and voice rooms.
- Premium dark visual identity with black, deep purple and pink accents.
- Preserve the existing GitHub repository, Render service and dedicated Supabase project. Extend existing schema and code; do not duplicate infrastructure.

## 3. Main product modules

### 3.1 Discover
- Discover approved, eligible members.
- Filter by city and interests.
- Like and connect with members.
- Support friendship and relationship intentions.
- Respect discoverability, blocking and privacy settings.
- Do not expose precise location.

### 3.2 Rooms
- Public and private rooms.
- City-, language- and interest-based discovery.
- Room membership, roles, invitations and moderation.
- Real-time text conversations.
- Participant lists and presence.
- Optional room-specific aliases.
- The platform must retain the authenticated account-to-alias mapping for safety. Other room participants must not be able to read that mapping.
- Private room messages must be visible only to authorized members.

### 3.3 Direct messaging
- Persistent one-to-one conversations.
- Message requests and authorization rules.
- Text, reactions, replies and read receipts.
- Voice notes and media attachments after storage and moderation rules are implemented.
- Blocking and reporting.
- Do not expose fictional demo conversations to authenticated users.

### 3.4 Moments
- Photo, video and text status updates.
- Audience controls.
- Reactions and replies.
- Expiry and deletion rules.
- Upload validation, moderation and storage limits.

### 3.5 Communities
- Public and private communities.
- Membership requests and roles.
- Posts, discussions, reactions and comments.
- Moderators, reports and enforcement.
- Optional community-linked rooms and events.

### 3.6 Live voice rooms
- Hosts, speakers, listeners and moderator roles.
- Join/leave, mute and speaker permissions.
- Scheduled rooms and live participation.
- Reporting and removal controls.
- Evaluate WebRTC media infrastructure separately. Supabase Realtime may support signaling and metadata, but it is not an audio/video transport.

### 3.7 Persistent identity
- Unique username and display name.
- Profile photo/gallery, biography, city and interests.
- Friendship and relationship intentions.
- Privacy and discoverability controls.
- Verification state, badges and earned reputation.
- Keep private account data separate from public profile data.

### 3.8 BaddieCoins
- Wallet balance and transaction history.
- Virtual gift catalogue and delivery.
- Premium membership and eligible customization.
- Promotional rewards, clearly distinguished from purchased credits.
- Server-authoritative balance changes only.
- Immutable transaction ledger, atomic operations and idempotency keys.
- No user-to-user cash transfers or cash withdrawals in the initial release.
- Payment provider selection requires separate review of Côte d'Ivoire availability, fees, legal obligations and operational cost. No paid service is assumed or authorized by this specification.

## 4. Stars & Reputation

BaddieLink includes a 2go-inspired star progression system. Stars represent earned community reputation and participation quality. They are not a rating of attractiveness, dating value, wealth or popularity, and they cannot be purchased with BaddieCoins.

### Initial rank ladder

1. **Beginner** — new member; learning the platform.
2. **Novice** — has started participating constructively.
3. **Intermediate** — established member with consistent positive participation.
4. **Advanced** — trusted, active contributor.
5. **Expert** — recognized contributor and community participant.
6. **Legend** — exceptional long-term contribution and trust.

The names and ordering are approved. Exact point thresholds, star display and promotion criteria remain to be calibrated before implementation.

### Reputation signals
Positive signals may include:
- Meaningful, non-spam participation in rooms and communities.
- Helpful contributions recognized by community members.
- Consistent adherence to platform rules.
- Hosting well-moderated discussions or events.
- Constructive participation over time.

Do not award points solely for message volume, repeated low-effort actions, paid purchases, gifts sent, or time spent online.

### Abuse resistance and fairness
- Award reputation through trusted server-side events, not client-supplied scores.
- Use idempotent event processing to prevent duplicate awards.
- Apply rate limits and diminishing returns to repetitive actions.
- Do not allow users to buy, gift or transfer rank points.
- Reports alone must not automatically reduce rank; only reviewed, substantiated moderation outcomes may affect eligibility.
- Provide a review/appeal path for material rank penalties.
- Keep reputation event history auditable.
- Separate public rank display from internal moderation risk signals.

## 5. Trust, safety and privacy

- 18+ eligibility is mandatory.
- A date-of-birth declaration is not the same as verified identity or verified age.
- Keep `age_declaration_at` distinct from `age_verified_at`; never let client input set a verified timestamp.
- Account-level identity remains known to the platform even when a room alias is displayed.
- Blocking, reporting, moderation queues and enforcement are core platform features.
- Protect against harassment, impersonation, spam, scams, underage access and sexual solicitation.
- The product must not become a marketplace for paid sexual services.
- Apply RLS to every user-owned or membership-restricted data set.
- Private media must use private storage and short-lived authorized access where appropriate.
- Provide account deletion and data-handling workflows.

## 6. Existing architecture to preserve

- GitHub: `Logicalskyinc/Baddielink`, default branch `main`.
- Render: existing static site `baddielink`, connected to the repository, publish path `.`, automatic deployment currently disabled.
- Supabase: dedicated project `blibhehqdrgdoczcacpa`, region `eu-west-3` (Paris).
- Browser client uses the Supabase publishable key. Never put a service-role key in browser code.
- Existing frontend files: `index.html`, `style.css`, `script.js`, `signup.html`, `supabase-config.js`, `auth-integration.js`.
- Existing public tables: `profiles`, `user_private_settings`, `profile_photos`, `likes`, `matches`, `messages`, `blocks`, `reports`.
- Existing database policies cover owner settings, approved adult discovery, likes, active-match messages, blocks and reports.
- Existing database functions/triggers create user records, create matches on mutual likes, enforce profile photo limits and validate adult declarations.
- Existing private Storage bucket: `baddielink-profile-photos`.

Do not replace existing tables or policies without a reviewed migration. Extend the existing data model and preserve existing user data.

## 7. Technical direction

- Supabase Auth for account authentication and session management.
- PostgreSQL as the authoritative data store.
- RLS for access control.
- Supabase Storage for approved media workflows.
- Supabase Realtime for authorized chat events, presence and notifications where appropriate.
- Server-side trusted functions for wallet operations, gifts, reputation awards and moderation workflows.
- WebRTC-compatible media infrastructure for voice rooms, selected only after a cost and reliability review.
- Add indexes for real query patterns and enforce uniqueness/foreign keys at the database layer.
- Make all balance and reputation mutations transactional and idempotent.
- Do not trust client-provided user IDs, ranks, wallet balances, moderation states or membership roles.

## 8. Proposed data model additions

These are proposed entities, not tables confirmed to exist:

- Rooms: `rooms`, `room_members`, `room_messages`, `room_identities`.
- Communities: `communities`, `community_members`, `community_posts`, `community_reactions`.
- Moments: `moments`, `moment_reactions`.
- Notifications: `notifications`.
- Reputation: `reputation_accounts`, `reputation_events`, `reputation_rules` or a versioned server-side ruleset.
- Economy: `wallets`, `wallet_transactions`, `virtual_gifts`, `gift_transactions`, `subscriptions`.
- Live: `voice_rooms`, `voice_room_members`, plus provider session metadata if required.
- Safety: `moderation_actions`, and additional audit records where existing `reports` is insufficient.

Before creating tables, inspect the existing schema, foreign keys, triggers, RLS policies and migrations. Prefer adapting existing `messages` or adding a conversation abstraction only after evaluating compatibility with existing match-based messaging.

## 9. Delivery roadmap

1. **Foundation verification:** authentication, age declaration, profile creation, session restoration, sign-out, RLS and deployment configuration.
2. **Core social:** real profiles, photos, discovery, likes, matches, persistent direct messaging, notifications, blocking and reporting.
3. **2go-inspired rooms:** public/private rooms, membership, aliases, real-time text and moderation.
4. **Communities and moments:** publishing, feeds, reactions, expiry, membership and moderation.
5. **Stars & Reputation:** server-authoritative events, rank ladder, abuse resistance and profile display.
6. **BaddieCoins:** ledger, gifts, premium entitlements and payment-provider review.
7. **Live voice:** provider evaluation, signaling, media transport, moderation and cost controls.
8. **Production readiness:** security tests, concurrency tests, load tests, backup/restore, accessibility, mobile performance and operational monitoring.

## 10. Acceptance principles

A feature is not complete because its UI exists. It must be connected to the backend, protected by authorization, tested for failure and concurrency cases, and verified in the live application when deployment is explicitly approved.

Track each item separately as **planned**, **implemented**, **tested**, **committed**, **deployed** and **live-verified**. Never use one status as a substitute for another.

## 11. Current verified baseline (2026-11-17)

- Repository branch `main` exists; a separate feature branch is used for upcoming work.
- The current UI is still a prototype; demo data and local-only actions remain in `script.js`.
- Supabase contains eight public tables, all with RLS enabled; inspected row counts were zero.
- The private profile-photo bucket exists with a 5 MiB limit and JPEG/PNG/WebP allowlist.
- Supabase Realtime publication currently contains no public tables.
- No Supabase Edge Functions were listed.
- Auth registration/login integration code exists, but signup/login/session behavior has not been end-to-end verified in this audit.
- Render static site exists and automatic deployment is disabled.
- No deployment, billing change or paid infrastructure change is authorized by this specification.


## 12. Implementation progress update (2026-11-17)

Feature branch: `feature/baddielink-social-foundation`.

### Implemented on the feature branch (not deployed)
- Removed the client-side demo sign-up/login handler that previously allowed a local fake session.
- Kept Supabase Auth sign-up, password sign-in, session restoration and sign-out as the only authentication path.
- Authenticated users no longer receive prototype discovery profiles, fake likes or sample conversations.
- Removed the unused phone-number field from signup because no verified phone persistence/verification workflow exists yet.
- Removed signup copy that incorrectly stated that no server account was created.
- Replaced the demo wallet balance with an explicit BaddieCoins preparation state; no fake balance is shown.
- Clarified that the adult declaration is not official age verification.
- Added visible styling for authentication errors.

### Not yet verified
- Browser execution and JavaScript syntax check in a real browser.
- End-to-end signup, email confirmation, login, session restore, age declaration and logout using a test account.
- Profile creation trigger behavior under the actual Auth flow.
- Responsive and accessibility regression checks.
- No new database schema, RLS, Storage or Realtime changes have been made in this implementation phase.

### Current status
- Product specification: committed on feature branch.
- Authentication/demo-flow hardening: implemented and committed on feature branch; static source checks passed.
- Browser/runtime tests: pending.
- Database migrations: none applied.
- Main branch: unchanged.
- Render deployment: not triggered; existing service remains connected to `main` with auto-deploy disabled.


## 13. Implementation progress update (2026-11-17, profile foundation)

### Implemented on feature branch
- Added a real profile editor backed by the existing `profiles` table.
- Editable fields: display name, username, city, biography, interests and discoverability.
- Username validation matches the database format (3–24 lowercase letters, digits and underscores).
- Profile updates are scoped to the authenticated user's own profile ID.
- The editor does not send moderation or verification fields.
- Added a responsive French-language profile editor modal and member profile summary.
- Login mode no longer requires the signup-only terms checkbox.
- Corrected Unicode normalization for generated usernames.

### Database security verification
- Confirmed that RLS is enabled and owner policies remain in place.
- Confirmed column-level UPDATE grants limit profile edits to approved editable columns. Authenticated users do not have UPDATE permission for `moderation_status`.
- Confirmed authenticated users do not have UPDATE permission on `user_private_settings`; the adult declaration is written through `confirm_adult_status`.
- Confirmed profile photo moderation status is not client-updatable; authenticated users can update only `display_order`.
- No database permissions or schema were changed.

### Static source checks
- Supabase signup, password login, session restoration and logout paths are present.
- Demo login and demo profile data are not used in the authenticated path.
- Profile editor reads and updates only the current authenticated member's row.
- Profile form, interest controls and discoverability control are present.
- Main branch remains unchanged.

### Still pending
- Browser runtime and responsive testing.
- Real signup, email confirmation, login, age declaration and logout tests.
- Profile update tests against Supabase, including duplicate usernames and RLS denial cases.
- Accessibility checks and browser console review.
- No test account has been created and no production database changes have been made.
- No Render deployment has been triggered.

### Current delivery status
- Product specification: committed on feature branch.
- Authentication and profile foundation: implemented and committed on feature branch; static source checks passed.
- Runtime/E2E validation: pending.
- Stars & Reputation: specified, not implemented.
- Main branch: unchanged.
- Render: unchanged; deployment remains disabled.
