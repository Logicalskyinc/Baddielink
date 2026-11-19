# BaddieLink migration archive status

Last reconciled: 2026-11-19  
Live Supabase project: `blibhehqdrgdoczcacpa`  
Branch: `chore/archive-applied-migrations-20261119`

## Status

The live Supabase project reports 22 applied migrations. All 22 applied SQL statement sets have now been recovered from `supabase_migrations.schema_migrations` and archived in this branch using their live version identifiers.

The recovered SQL is the exact statement content retained by the hosted migration history. For the 16 previously missing migrations, recovered byte lengths and MD5 hashes were checked against the migration recovery inventory. The two Salon migrations were compared with the hosted statement history; the first existing file matched byte-for-byte, and the second was replaced with the exact hosted statement text and corrected live version filename. The four later migrations were also checked against the recorded byte lengths and MD5 hashes where available.

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

## Unapplied migration kept separate

`20261117180000_default_people_discovery_on.sql` remains a separate unapplied historical file. It is intentionally not counted among the 22 applied migrations. The equivalent change actually applied to production is recorded as version `20261119122243`.

## Safe use

1. Keep this archive branch separate until reviewed.
2. Never execute these 22 files against the current production project as a batch.
3. For a new empty environment, validate replay on a disposable Supabase project first, including RLS, grants, triggers, storage policies, publication membership, and function ownership.
4. Keep future migration filenames and version identifiers aligned with the live migration history.
