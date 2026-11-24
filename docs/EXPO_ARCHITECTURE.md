# BaddieLink Expo Application Architecture

**Status:** Architecture baseline for implementation  
**Date:** 2026-11-25  
**Target:** Expo SDK 58 / React Native 0.88  
**Repository:** `Logicalskyinc/Baddielink`  
**Implementation branch:** `feat/v1-member-experience`  
**Production:** Existing root static website remains unchanged.

## 1. Non-negotiable boundaries

- The existing website remains live and is not replaced during mobile development.
- The existing Supabase project `blibhehqdrgdoczcacpa` remains the shared backend. Do not create a replacement project or reset data.
- The Expo app lives under `apps/app/`. Keep the current website at the repository root.
- Do not change Render service configuration, production branch, publish path, or deployment state as part of Expo setup.
- No production migrations, database writes, Edge Function deployments, secret changes, payment activation, or production deploys without separate explicit approval.
- Existing feature-branch commits for the wallet catalogue visibility and authenticated header fixes remain part of the current work. This architecture work extends that phase; it does not replace it.
- UI presence is not feature completion. Every feature must be backed by authorization, error handling, tests and a verified runtime flow.

## 2. Verified infrastructure baseline

### GitHub and Render

- Repository default branch: `main`.
- Production baseline: `74df9713b023621f954575d513b1de7d0ee2cad9`.
- Current working branch: `feat/v1-member-experience`.
- Current working branch head at architecture review: `c55f040935aa8bb25d1368432fb87eccf586ec33`.
- Render service: `baddielink`, static site.
- Render branch: `main`; root directory: repository root; publish path: `.`; build command: none.
- Render auto-deploy is disabled.
- The app directory is not built or published by the current static-site configuration.

### Supabase

- Project: `BaddieLink` (`blibhehqdrgdoczcacpa`), region `eu-west-3`.
- Live PostgreSQL version observed: 17.12.
- Live public schema: 17 tables; RLS enabled on every listed public table.
- Migration history: 24 applied migrations observed during this review.
- Deployed Edge Functions: none.
- Use the live schema and policies as the source of truth. A migration file in Git alone is not proof that it is applied.

## 3. Application stack

Use stable, SDK-compatible packages. Let Expo select compatible native package versions with `npx expo install`; do not independently force React Native or native-module versions.

| Layer | Decision | Reason |
|---|---|---|
| Runtime | Expo SDK 58, React Native 0.88, React 19.3 | Current stable Expo release at architecture review |
| Language | TypeScript, strict mode | Catch unsafe navigation, API and component contracts early |
| Navigation | Expo Router | File-based routes shared by Android, iOS and web |
| Server state | TanStack Query | Cache, pagination, retries, invalidation and mutation lifecycle |
| Local UI state | Zustand, limited to ephemeral client state | Avoid duplicating server state in a global store |
| Forms | React Hook Form + Zod | Typed validation and consistent form handling |
| Motion/gestures | Reanimated + Gesture Handler | Native-driven transitions, swipe and gesture interactions |
| Media | Expo Image and Expo Video | Efficient image rendering and native video playback |
| Backend | Existing Supabase project and `@supabase/supabase-js` | Reuse Auth, PostgreSQL, Storage, RLS and Realtime |
| Lists | FlatList initially; benchmark FlashList before adoption | Avoid adding an unverified native dependency before measuring |
| Styling | Design tokens + React Native StyleSheet | Predictable cross-platform visual system |

Use the Expo SDK 58 compatibility matrix as the authority for native package versions. Avoid beta/canary packages in the production app.

### Windows 11 development toolchain

- Node.js 22.13+ LTS (or a newer supported LTS compatible with SDK 58).
- Git for Windows.
- VS Code.
- Android Studio with the SDK/JDK versions required by the current React Native environment guide, or a physical Android phone with Expo Go for the first device loop.
- Windows cannot run Apple's iOS Simulator locally. iOS builds and device testing will use EAS/cloud build infrastructure later, after the app is ready and the user approves that step.

## 4. Repository layout

Keep the legacy website files at the root. Add the mobile app as an isolated application:

```text
Baddielink/
├── index.html                 # Existing website; do not move
├── style.css                  # Existing website; do not move
├── script.js                  # Existing website; do not move
├── auth-integration.js        # Existing website; do not move
├── supabase-config.js         # Existing website config; do not copy secrets
├── apps/
│   └── app/
│       ├── app/               # Expo Router routes and layouts
│       ├── src/
│       │   ├── components/
│       │   ├── features/
│       │   ├── hooks/
│       │   ├── lib/
│       │   ├── services/
│       │   ├── stores/
│       │   ├── theme/
│       │   └── types/
│       ├── assets/
│       ├── .env.example
│       ├── .gitignore
│       ├── app.json
│       ├── package.json
│       └── tsconfig.json
├── docs/
│   └── EXPO_ARCHITECTURE.md
└── supabase/
    ├── migrations/
    └── proposals/
```

Do not introduce root-level npm workspaces or move existing files until a separate build/deployment review proves that doing so cannot change the static site's published root.

## 5. Navigation and information architecture

### Primary authenticated navigation

The five primary destinations are:

1. **Home** — social feed, moments rail and relevant community/event activity.
2. **Discover** — people discovery, interests, friendship/relationship intent and member profiles.
3. **Messages** — real conversations and message requests; no fictional conversations.
4. **Communities** — public/private salons and communities, membership and discussion.
5. **Profile** — member identity, photos, reputation, connections, activity, wallet shortcut and settings.

### Secondary routes

- Authentication: welcome, sign in, sign up, age declaration and recovery.
- Member: profile detail, photo viewer, match detail and report/block actions.
- Messaging: conversation, message request and conversation details.
- Spaces: discovery, detail, create/edit, member list and moderation.
- Events: discovery, event detail, submit event and organizer application.
- Wallet: catalogue, balance and ledger history only when the backend economy is implemented and approved.
- Settings: privacy, discoverability, notifications, account and safety.
- Admin moderation remains a separate, server-authorized web console. Do not expose admin-only routes as ordinary member navigation.

### Proposed route structure

```text
app/
├── _layout.tsx
├── (auth)/
│   ├── _layout.tsx
│   ├── welcome.tsx
│   ├── sign-in.tsx
│   ├── sign-up.tsx
│   └── age-gate.tsx
└── (app)/
    ├── _layout.tsx
    ├── (tabs)/
    │   ├── _layout.tsx
    │   ├── home.tsx
    │   ├── discover.tsx
    │   ├── messages.tsx
    │   ├── communities.tsx
    │   └── profile.tsx
    ├── members/[id].tsx
    ├── matches/[id].tsx
    ├── chats/[id].tsx
    ├── spaces/[id].tsx
    ├── spaces/create.tsx
    ├── events/index.tsx
    ├── events/[id].tsx
    ├── wallet/index.tsx
    └── settings/
        ├── index.tsx
        ├── privacy.tsx
        └── account.tsx
```

The route tree is a target, not a claim that these screens already exist.

## 6. Backend reuse map

The live Supabase schema was inspected on 2026-11-25. The following tables are present in the live `public` schema, with RLS enabled:

| Existing table | Intended app use | Status / constraint |
|---|---|---|
| `profiles` | Public member identity, bio, city, interests and discoverability | Existing; preserve owner-column restrictions and moderation gates |
| `user_private_settings` | DOB and age declaration | Private; never expose DOB in public profile queries |
| `profile_photos` | Photo metadata and moderation state | Existing private bucket; only approved media is displayable |
| `likes` | Member likes | Existing |
| `matches` | Mutual likes and active match relationship | Existing |
| `messages` | Direct messages associated with a match | Existing but match-bound; does not provide the full message-request/conversation model |
| `blocks` | Member blocking | Existing; apply to discovery, feeds, messaging and spaces |
| `reports` | Member/message/space-message reports | Existing; preserve reviewed moderation workflow |
| `reputation_profiles` | Public reputation score/rank | Existing read model; awards must remain server-authoritative |
| `event_organizers` | Approved/trusted organizers | Existing |
| `events` | Event discovery and submissions | Existing; status controls public visibility |
| `event_interests` | Member interest in events | Existing |
| `organizer_applications` | Organizer onboarding | Existing |
| `event_reports` | Event reports | Existing |
| `admin_audit_log` | Auditable admin actions | Admin-only access; never expose unrestricted client writes |
| `spaces` | Shared salon/community container | Existing; current RLS/policies must be reviewed before enabling community type |
| `space_memberships` | Space membership and roles | Existing; owner/moderator authorization must remain database-enforced |
| `space_messages` | Text messages inside active spaces | Existing and Realtime publication configured by migration; only active authorized members |

The live schema contains 18 entries in the list above; the count is 18, not 17. (The earlier table inventory count was understated.)

### Backend gaps requiring a separate reviewed design

Do not create these tables in the Expo scaffold. First define and review migrations, constraints, indexes, RLS and moderation paths:

- Feed: posts, post media, audience/visibility, comments, reactions, bookmarks, reshares and feed pagination/ranking.
- Moments: media/text status, audience controls, expiry, deletion and moderation.
- Notifications: per-user notifications, read state, delivery preferences and push-token lifecycle.
- Communities: membership/role policies and community posts/discussions. Existing `spaces` is a foundation, but current policies are salon-oriented.
- Direct messaging: message requests and a conversation/participant abstraction if the product must support conversations outside existing matches. Preserve the existing match-linked `messages` until a migration is reviewed.
- Room aliases: private account-to-alias mapping and member-visible alias data with strict separation.
- Voice: room lifecycle and participant metadata plus a separately evaluated WebRTC media provider. Supabase Realtime is not an audio transport.
- Economy: wallets, immutable ledger, inventory, gift transactions, provider webhook reconciliation and referral provenance. Existing live schema has no active BLC ledger; no payments are enabled.
- Reputation events: auditable, idempotent server-side award history and rule versioning.

## 7. Authentication and client security

- Use Supabase Auth with the existing project. Do not create a second user identity store.
- Restore the session before rendering authenticated routes; gate protected screens from the verified session state.
- Configure a unique app URL scheme and implement deep-link handling for email confirmation, password recovery and OAuth return paths before enabling those flows in the app.
- Reuse the existing adult declaration flow only after confirming its current RPC contract. A declaration is not identity or age verification. Never let a client set `age_verified_at`.
- Use only the Supabase publishable key in the mobile app. Never ship a service-role or secret key in app code, build variables exposed to the client, or the repository.
- Keep credentials in local environment files excluded from Git. Commit only `.env.example` with variable names and placeholder values.
- Derive the current user ID from the authenticated Supabase session. Never trust a client-supplied user ID, role, moderation status, wallet balance, reputation score or membership role.
- RLS remains the authorization boundary. UI hiding is not authorization.
- Treat private media as private. Use authorized access and short-lived signed URLs where appropriate; do not make the profile-photo bucket public to simplify image rendering.
- Apply block/report checks consistently across discovery, feed, messages and spaces.
- Do not use user-editable Auth metadata as an authorization source.
- Do not show demo conversations, fake members, fake activity counts or fake wallet balances in authenticated experiences.

### Supabase client structure

Use a single typed Supabase client under `src/lib/supabase/`, with:
- Environment validation at startup (fail clearly if URL/key is missing).
- A tested React Native session-storage adapter.
- Auth deep-link/session handling.
- Generated database types based on the live schema.
- No privileged credentials.

Session storage choice must be finalized during implementation. Evaluate the official React Native approach using AsyncStorage and Expo SecureStore-backed encryption; do not invent a custom cryptographic format without review.

## 8. Data access and state management

Organize feature code by domain. Keep UI components out of database authorization logic.

- `services/`: narrow Supabase queries and mutations, one domain per module.
- `features/`: screens, components and hooks for each product capability.
- TanStack Query: server data, caching, pagination, optimistic updates and rollback.
- Zustand: ephemeral UI state only (for example, active composer draft or transient player state).
- React Hook Form + Zod: form state and client validation; database constraints and RLS remain authoritative.
- Use cursor/keyset pagination for feeds and message history. Avoid unbounded queries and offset pagination for high-churn feeds.
- Use idempotency keys for retryable user actions where duplicate effects would be harmful.
- Optimistic UI must have rollback and visible error recovery. Do not optimistically claim a match, payment, gift delivery or moderation result before the server confirms it.
- Realtime subscriptions must be scoped to the active user/conversation/space and cleaned up on navigation or sign-out.
- Cache invalidation follows successful server mutations; do not duplicate backend state in Zustand.

## 9. Experience and design system

The visual foundation follows the approved premium dark identity: black/charcoal surfaces with deep violet and pink accents. Use accent gradients sparingly so content remains the focus.

Experience principles:
- Social-first, not dating-only. Friendship and community activity must be first-class.
- Distinctive interaction quality without copying TikTok's brand, layouts or proprietary behavior.
- Fast, predictable navigation and responsive touch feedback.
- Native-feeling swipe, sheet, tab and media transitions.
- Smooth vertical feed scrolling; media should load progressively and avoid blocking text.
- Clear loading, empty, offline, retry and moderation states. No fake content to disguise missing backend data.
- Respect reduced-motion settings and provide accessible labels, contrast and touch targets.
- Support low-bandwidth use: thumbnails, lazy loading, bounded media sizes, retry controls and graceful text-first fallback.
- Avoid heavy animation on every component. Prioritize gesture feedback and meaningful transitions.

Define tokens for color, typography, spacing, radius, elevation, motion duration and semantic states before building production screens.

## 10. Performance and reliability

- Keep feed cards and navigation components small and memoize only where profiling supports it.
- Use stable list keys, bounded page sizes, image dimensions and thumbnail variants.
- Pause video when a card leaves the active viewport; avoid autoplaying multiple videos.
- Do not preload large media over mobile data without user intent or an explicit preference.
- Debounce discovery filters and search.
- Cancel or ignore stale requests when users switch screens quickly.
- Handle expired sessions, offline mode, timeouts, rate limits and Supabase errors explicitly.
- Instrument crashes and performance only after privacy/consent review and a decision on any paid services.
- Do not add paid analytics, push providers or media infrastructure during the scaffold phase.

## 11. Testing and release gates

### Local development gates

1. Install and run the Expo app without changing the website.
2. Verify Expo Router navigation and Android device rendering.
3. Verify environment configuration does not expose secrets.
4. Typecheck and lint the app.
5. Verify Supabase session restoration and sign-out using an approved test account.
6. Test deep links with a non-production-safe test flow before relying on email confirmation or recovery.
7. Verify read-only profile, discovery, events and space queries against the existing RLS policies.
8. Test denied access as well as allowed access. Never use another member's data to bypass policy.
9. Test poor network, retry, stale cache and rapid navigation.
10. Check Android device performance and responsive layouts.

### Promotion gates

- No production migration until schema, RLS and rollback are reviewed and separately approved.
- No Edge Function deployment or secret change without separate approval.
- No merge to `main` until implementation, source checks, runtime tests and branch diff are reviewed.
- No Render deploy until the user explicitly approves it.
- Existing website remains the fallback until the mobile app passes functional, security, accessibility and performance validation.

Track each item independently as **planned**, **implemented**, **tested**, **committed**, **previewed**, **deployed** and **live-verified**.

## 12. Initial implementation sequence

1. Prepare Windows 11 tooling and clone the existing repository.
2. Check out `feat/v1-member-experience` and verify the expected head before editing.
3. Scaffold the Expo Router TypeScript app in `apps/app/` using the current stable SDK 58 template.
4. Add only the dependencies required for the shell and Supabase integration; resolve native versions with `npx expo install`.
5. Establish design tokens, app layouts, route guards and a clean empty-state shell for the five primary tabs.
6. Add generated database types and a typed Supabase client, without writing to production data.
7. Implement and test authentication/session restoration.
8. Build the member profile and discovery read paths against existing RLS.
9. Design missing feed/moments/DM/community backend capabilities separately before implementing those write flows.

**Current status:** Architecture documented. Expo project not yet scaffolded. No Supabase schema, data, secrets, Render configuration or production deployment changed.
