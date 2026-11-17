# BaddieLink Manual Test Plan

**Target branch:** `feature/baddielink-social-foundation`  
**Status:** Prepared; tests not yet executed  
**Environment:** Existing Supabase project; no separate staging environment verified

## Authentication

- [ ] Signup rejects missing fields and passwords shorter than eight characters.
- [ ] Signup rejects DOB under 18 and over 100.
- [ ] Signup accepts an adult DOB and creates one Auth user, one profile and one private settings row.
- [ ] Generated username is normalized, valid and unique.
- [ ] Email confirmation flow returns to the configured application URL.
- [ ] Confirmed user can sign in.
- [ ] Login does not require the signup-only terms checkbox.
- [ ] Login with no adult declaration asks for DOB and writes it only through `confirm_adult_status`.
- [ ] A user cannot set `age_verified_at` through the client.
- [ ] Session survives refresh and logout clears the session.
- [ ] Duplicate signup and incorrect password produce safe user-facing errors.

## Profile editor

- [ ] Owner can read their own profile.
- [ ] Owner can update display name, username, city, bio, interests and discoverability.
- [ ] Username validation rejects invalid format and duplicate username.
- [ ] Bio over 500 characters is rejected.
- [ ] City over 80 characters is rejected.
- [ ] Discoverability can be enabled only after adult declaration.
- [ ] A pending or restricted profile remains excluded from discovery.
- [ ] Client cannot update moderation status or protected account settings.
- [ ] Profile summary refreshes after successful save.
- [ ] Failed saves preserve the form contents and show an actionable error.

## Privacy and authorization

- [ ] A member cannot read another member's private settings.
- [ ] Unapproved profiles and photos are not visible in discovery.
- [ ] Blocked members cannot discover or message each other.
- [ ] Profile-photo storage access is restricted to the owner or approved discovery rules.
- [ ] Direct API requests cannot bypass RLS or column-level grants.

## UI and accessibility

- [ ] Signup, login and profile editor work at mobile width.
- [ ] Keyboard focus is visible and modal controls are reachable.
- [ ] Modal closes using close/cancel controls and backdrop.
- [ ] Form errors are announced through live regions.
- [ ] No fake users, sample conversations or fake wallet balances appear after login.
- [ ] Browser console has no uncaught errors.

## Execution controls

- Do not create test users or write production data without explicit approval.
- Prefer a dedicated staging project before broad end-to-end tests.
- Do not deploy to the existing Render service during this test phase.
