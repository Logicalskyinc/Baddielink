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
- [ ] A member cannot directly insert a profile row or set their own moderation status; the Auth account-record trigger creates the pending profile.
- [ ] A member cannot update their own moderation status; approval/restriction remains an admin-only operation.
- [ ] Reputation rank keys render as Nouveau, Initié, Habitué, Confirmé, Référence and Légende; unknown keys fall back to Nouveau.
- [ ] Invalid or duplicate usernames are rejected.
- [ ] A pending or restricted profile remains excluded from discovery.
- [ ] Only approved profiles with discoverability enabled appear in People Discovery.
- [ ] Approved but non-discoverable profiles remain hidden from other members.
- [ ] Reciprocal likes create exactly one match; test concurrent opposite likes with two database sessions at PostgreSQL `READ COMMITTED` in an isolated non-production database, confirming the second trigger sees the first committed like after waiting for the pair lock.
- [ ] The member list in Admin Console shows moderation status separately from discoverability.
- [ ] Existing member privacy choices are preserved by approval actions.

## Reporting and moderation queue
- [ ] A member can report another member with each allowed reason; the report is created only with status `open`.
- [ ] A member cannot report themselves or submit a report without a valid target.
- [ ] A member cannot read another member's reports or the moderation queue.
- [ ] Duplicate member reports are handled without exposing raw database/backend errors.
- [ ] A member can report a published event they did not create; event reports start as `pending`.
- [ ] Duplicate event reports are rejected clearly without exposing raw backend errors.
- [ ] Admins can read and process only the report queues allowed by their role.
- [ ] Report decisions outside the permitted set are rejected by the database functions.
- [ ] Each successful report decision creates an audit-log entry with before/after state.
- [ ] A moderator cannot change their own account moderation status.
- [ ] An owner cannot change their own role or demote another owner through moderator management.
- [ ] A non-admin cannot invoke moderation functions successfully, even if they bypass the UI.

## Likes and blocked accounts
- [ ] The authenticated Likes view retains its `#likes-grid` container after sign-in and renders sent and received likes.
- [ ] A member with no sent or received likes sees a clear empty state.
- [ ] A member can view only their own blocked-account list.
- [ ] Blocking a member refreshes the blocked-account list and removes the blocked profile from discovery.
- [ ] A member can unblock only their own blocked account; discovery refreshes after unblocking.
- [ ] Profiles hidden by either-direction block policies do not appear in Likes profile details.

## Reports, Salons and database authorization

- [ ] Member reports are created only in the `open` queue state; clients cannot submit pre-closed or actioned reports.
- [ ] Event reports are created only in the `pending` queue state.
- [ ] Public open Salons accept eligible members as `active`; approval Salons create `pending` memberships.
- [ ] Rejoining a removed Salon membership follows the Salon's current join policy.
- [ ] A member can cancel their own pending join request; the membership becomes `removed` and the member can request access again.
- [ ] An owner can invite a member with no prior membership.
- [ ] An owner can re-invite a previously removed member without creating a duplicate membership.
- [ ] An owner cannot bypass a banned membership by sending another invitation.
- [ ] Existing active or pending memberships are reported clearly instead of being inserted again.
- [ ] Non-owners cannot manage another member's Salon membership or elevate their own role.
- [ ] Direct `anon` and `authenticated` table access to `private.admin_roles` is denied; guarded admin RPCs preserve owner/moderator rules.

## Profile photos

- [ ] Photo upload validates JPEG, PNG or WebP and the 5 MiB limit.
- [ ] Pending photos are visible only to their owner and authorized moderators.
- [ ] Only approved photos appear publicly.
- [ ] Signed photo previews load for authorized moderators.
- [ ] Authenticated users cannot directly update photo ownership, object paths or moderation status.
- [ ] If photo metadata insertion fails after storage upload, the client attempts object cleanup and logs a cleanup failure for operator follow-up.
- [ ] The ten-photo per-user limit is enforced by the database trigger under concurrent submissions.

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

- [ ] Browser/runtime tests pass using a local or otherwise data-isolated non-production build.
- [ ] If no data-isolated environment is available, mark write-dependent tests blocked; do not use the shared-Supabase preview for test writes.
- [ ] Any preview deployment is separately approved and limited to read-only checks until a safe test database exists.
- [ ] README and PR description accurately distinguish implemented features from roadmap work.
- [ ] PR is reviewed and mergeable.
- [ ] Merge to `main` is verified by commit SHA.
- [ ] Production Render deploy is triggered only after the merge, verified against the merge SHA, and explicitly approved by the project owner.
- [ ] Production smoke tests pass.
