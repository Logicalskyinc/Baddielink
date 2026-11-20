# BaddieLink migration archive status

Last reconciled: 2026-11-20  
Live Supabase project: `blibhehqdrgdoczcacpa`  
Archive/release-readiness branch: `scope-1/readiness-closeout`

## Status

The live Supabase project reports **24 applied migrations**. This branch contains SQL files for all 24 applied migrations, named with their exact live migration-history versions.

The first 22 applied migrations were recovered from `supabase_migrations.schema_migrations` and archived on `chore/archive-applied-migrations-20261119`. The archive recovery notes record byte-length and MD5 checks for the recovered statement sets where available, and document the exact hosted statement comparison for the two Salon migrations.

The two subsequent production corrections were applied separately after explicit approval:
- `20261119194013_harden_private_admin_roles_rls.sql`
- `20261119220202_harden_reports_and_salon_memberships.sql`

Their archived SQL files on this branch contain the exact SQL submitted for those production migrations. Their original feature-branch filenames used proposed timestamps; the archive copies use the actual live migration-history versions.

This is an archive recovery, not a request to execute or replay these migrations. **Do not run the archived files against the already-migrated production project.**

## Applied migrations

| Live version | Migration | Archived file |
|---|---|---|
| 20261117125934 | baddielink_core_foundation | `20261117125934_baddielink_core_foundation.sql` |
| 20261117135022 | baddielink_age_safety_and_access_grants | `20261117135022_baddielink_age_safety_and_access_grants.sql` |
| 20261117135257 | baddielink_adult_gate_and_private_photo_storage | `20261117135257_baddielink_adult_gate_and_private_photo_storage.sql` |
| 20261117135356 | baddielink_photo_access_hardening | `20261117135356_baddielink_photo_access_hardening.sql` |
| 20261117135407 | baddielink_photo_limit_concurrency_guard | `20261117135407_baddielink_photo_limit_concurrency_guard.sql` |
| 20261117211105 | events_and_reputation_foundation | `20261117211105_events_and_reputation_foundation.sql` |
| 20261117212451 | restrict_profile_photo_owner_updates | `20261117212451_restrict_profile_photo_owner_updates.sql` |
| 20261117212957 | event_cover_image_storage | `20261117212957_event_cover_image_storage.sql` |
| 20261117213055 | organizer_applications_and_event_reports | `20261117213055_organizer_applications_and_event_reports.sql` |
| 20261117213149 | index_event_reports_by_reporter | `20261117213149_index_event_reports_by_reporter.sql` |
| 20261117214041 | baddielink_admin_console_foundation | `20261117214041_baddielink_admin_console_foundation.sql` |
| 20261117214108 | baddielink_admin_access_check | `20261117214108_baddielink_admin_access_check.sql` |
| 20261117214545 | protect_baddielink_owner_role | `20261117214545_protect_baddielink_owner_role.sql` |
| 20261117214633 | baddielink_owner_role_directory | `20261117214633_baddielink_owner_role_directory.sql` |
| 20261117214645 | baddielink_owner_access_check | `20261117214645_baddielink_owner_access_check.sql` |
| 20261117214732 | baddielink_admin_storage_and_audit_indexes | `20261117214732_baddielink_admin_storage_and_audit_indexes.sql` |
| 20261118001833 | baddielink_salons_foundation | `20261118001833_baddielink_salons_foundation.sql` |
| 20261118001917 | salons_security_hardening | `20261118001917_salons_security_hardening.sql` |
| 20261119122243 | default_people_discovery_on | `20261119122243_default_people_discovery_on.sql` |
| 20261119135359 | space_messaging_foundation | `20261119135359_space_messaging_foundation.sql` |
| 20261119135415 | space_messaging_policy_hardening | `20261119135415_space_messaging_policy_hardening.sql` |
| 20261119141522 | space_messaging_permission_hardening | `20261119141522_space_messaging_permission_hardening.sql` |
| 20261119194013 | harden_private_admin_roles_rls | `20261119194013_harden_private_admin_roles_rls.sql` |
| 20261119220202 | harden_reports_and_salon_memberships | `20261119220202_harden_reports_and_salon_memberships.sql` |

## Unapplied historical migration kept separate

`supabase/archive/unapplied/20261117180000_default_people_discovery_on.sql` preserves the older unapplied historical SQL outside the active migration directory. It is intentionally not counted among the 24 applied migrations. The equivalent change actually applied to production is recorded as version `20261119122243`.

The two Scope 1 candidate fixes are staged separately on this branch and are **not applied**:
- `20261119230000_serialize_mutual_like_matching.sql` adds pair-scoped transaction advisory locking. Static review and PostgreSQL snapshot semantics support the design, but a real two-session concurrency test is still required.
- `20261119233000_strengthen_generated_usernames.sql` preserves the existing account-record trigger behavior while using an 8-character normalized base plus a 15-hex-character MD5 suffix (60 bits). A read-only SQL sample check passed the existing 3–24 character username format. It has not been run through a real Auth signup flow.

These candidates are separate from the 24-migration production archive and must not be applied until their remaining tests pass and the user explicitly approves the exact production migration.

## Safe use

1. Keep this archive/release-readiness branch separate from `main` until Scope 1 review is complete.
2. Never execute these 24 files against the current production project as a batch.
3. Before using this as a fresh-environment bootstrap, validate replay against a non-production database with no paid staging commitment, including RLS, grants, triggers, storage policies, publication membership, function ownership and application compatibility.
4. Keep future migration filenames and version identifiers aligned with the live migration history.
