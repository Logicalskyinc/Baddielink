# BaddieLink migration archive status

Last reconciled: 2026-11-19  
Live Supabase project: `blibhehqdrgdoczcacpa`  
Branch: `chore/archive-applied-migrations-20261119`

## Important status

The hosted Supabase project reports 22 applied migrations. This branch is **not a complete replayable migration archive**.

The original SQL files for 17 applied migrations were not found in the inspected GitHub branches. Do not infer or recreate their original SQL from migration names or the current schema and claim it is the historical migration.

## Live applied migration history

| Version | Migration | Original SQL file available in inspected GitHub branches? |
|---|---|---|
| 20261117125934 | baddielink_core_foundation | No |
| 20261117135022 | baddielink_age_safety_and_access_grants | No |
| 20261117135257 | baddielink_adult_gate_and_private_photo_storage | No |
| 20261117135356 | baddielink_photo_access_hardening | No |
| 20261117135407 | baddielink_photo_limit_concurrency_guard | No |
| 20261117211105 | events_and_reputation_foundation | No |
| 20261117212451 | restrict_profile_photo_owner_updates | No |
| 20261117212957 | event_cover_image_storage | No |
| 20261117213055 | organizer_applications_and_event_reports | No |
| 20261117213149 | index_event_reports_by_reporter | No |
| 20261117214041 | baddielink_admin_console_foundation | No |
| 20261117214108 | baddielink_admin_access_check | No |
| 20261117214545 | protect_baddielink_owner_role | No |
| 20261117214633 | baddielink_owner_role_directory | No |
| 20261117214645 | baddielink_owner_access_check | No |
| 20261117214732 | baddielink_admin_storage_and_audit_indexes | No |
| 20261118001833 | baddielink_salons_foundation | Yes: `20261118150000_baddielink_salons_foundation.sql` (filename timestamp differs from live version) |
| 20261118001917 | salons_security_hardening | Yes: `20261118170000_salons_security_hardening.sql` (filename timestamp differs from live version) |
| 20261119122243 | default_people_discovery_on | Yes: `20261119122243_default_people_discovery_on.sql` |
| 20261119135359 | space_messaging_foundation | No original file found in inspected branches |
| 20261119135415 | space_messaging_policy_hardening | No original file found in inspected branches |
| 20261119141522 | space_messaging_permission_hardening | Yes: `20261119141522_space_messaging_permission_hardening.sql` |

## Unapplied migration kept separate

`20261117180000_default_people_discovery_on.sql` remains an unapplied historical file. It is intentionally not counted as one of the 22 applied migrations. The applied equivalent is recorded separately as version `20261119122243`.

## Safe recovery plan

1. Search prior source-control history, local exports, and migration authoring records for the 17 missing original SQL files.
2. Recover each file only when its exact content and intended version can be established.
3. If exact originals cannot be recovered, create a separately labeled baseline/schema snapshot from the live database. Do not present it as the original sequence of migrations and do not blindly replay it.
4. Before any restore or replay, compare against a fresh database and validate dependencies, RLS, grants, triggers, storage policies, and function ownership.

No migration is executed by this archive document.
