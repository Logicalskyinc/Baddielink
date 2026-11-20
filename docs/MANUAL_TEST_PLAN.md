# BaddieLink Manual Test Plan

**Target branch:** `scope-1/readiness-closeout`  
**Status:** Prepared; functional tests remain pending. The Render preview shares production Supabase and is not approved for test writes.  
**Environment:** Preview and production use the same Supabase project. Preview is not a data-isolated staging environment.

## Safety rules

- Do not create disposable users or test records in the shared production database.
- Do not upload test photos, submit events, approve/reject real members, change roles, or change moderation settings as part of routine smoke testing.
- Read-only navigation and viewing existing records are safe. A real moderation action is only allowed when the project owner explicitly intends that action.
- Never bypass a member's discoverability preference. Approval and discoverability are separate states.
- Do not treat a successful static-site deploy as proof that authenticated workflows passed.

## Authentication

- [ ] Existing account can sign in and session restores after refresh.
- [ ] Logout clears the session.
- [ ] Login does not require the signup-only terms checkbox.
- [ ] Signup rejects missing fields, passwords shorter than eight characters, DOB under 18 and DOB over 100.
- [ ] Adult declaration is stored only through `confirm_adult_status`; it is not described as official age or identity verification.
- [ ] Duplicate signup and incorrect password produce safe user-facing errors.
- [ ] Newly generated usernames remain within the 3–24 character format and have a collision-resistant suffix.
- [ ] Run the Auth signup trigger test only in an isolated non-production database; do not create disposable production accounts.

## Member profile and discovery

- [ ] Member can read and update their own display name, username, city, bio, interests and discoverability.
- [ ] Reputation rank keys render as Nouveau, Initié, Habitué, Confirmé, Référence and Légende; unknown keys fall back to Nouveau.
- [ ] Invalid or duplicate usernames are rejected.
- [ ] A pending or restricted profile remains excluded from discovery.
- [ ] Only approved profiles with discoverability enabled appear in People Discovery.
- [ ] Approved but non-discoverable profiles remain hidden from other members.
- [ ] The member list in Admin Console shows moderation status separately from discoverability.
- [ ] Existing member privacy choices are preserved by approval actions.

## Profile photos

- [ ] Photo upload validates JPEG, PNG or WebP and the 5 MiB limit.
- [ ] Pending photos are visible only to their owner and authorized moderators.
- [ ] Only approved photos appear publicly.
- [ ] Signed photo previews load for authorized moderators.

## Exhibitions and moderation

- [ ] Published events appear in the member event list.
- [ ] Event submissions and organizer applications follow their review status.
- [ ] Event interests and reports are associated with the signed-in member.
- [ ] Admin queues show the correct pending counts and records.
- [ ] A moderation action updates the target record, refreshes the queue and writes an audit entry.
- [ ] The owner account cannot moderate itself; the UI explains this restriction clearly.
- [ ] The Members tab can filter all, pending, approved, restricted and removed accounts.
- [ ] The Members tab shows visibility separately from moderation status.
- [ ] The Admin Console can return to Member View without reopening itself.

## Navigation and unfinished modules

- [ ] The five-item mobile navigation remains Likes, Messages, Discover, Profile and Settings.
- [ ] Discover shows implemented destinations only. Rooms, Communities, Moments and Audio placeholder panels remain hidden until functional.
- [ ] Wallet and direct messaging are not presented as working transactions or live conversations.
- [ ] No visible "Coming Soon" panel advertises a feature as usable before its implementation.

## UI and accessibility

- [ ] Signup, login, profile editor, Discover and Admin Console work at mobile width.
- [ ] Keyboard focus is visible and modal controls are reachable.
- [ ] Form errors are announced through live regions.
- [ ] Browser console has no uncaught errors.

## Release gates

- [ ] Latest feature-branch commit is deployed to the preview service.
- [ ] Preview smoke tests pass without writing test data.
- [ ] README and PR description accurately distinguish implemented features from roadmap work.
- [ ] PR is reviewed and mergeable.
- [ ] Merge to `main` is verified by commit SHA.
- [ ] Production Render deploy is triggered only after the merge and verified against the merge SHA.
- [ ] Production smoke tests pass.
