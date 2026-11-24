# Production migration-history recovery

## Purpose

Restore the exact SQL statements retained by the production Supabase migration-history table to the repository. The active local migration filenames will then use the exact production versions and names, without changing production migration metadata.

## Source and validation

- Supabase project: `blibhehqdrgdoczcacpa`
- Source: `supabase_migrations.schema_migrations`
- Read-only extraction date: 2026-11-24
- Production records retrieved: 24
- Each record contained one stored SQL statement.
- SQL statement lengths were checked against a separate read-only inventory before restoration.
- The three pre-existing repository-only migrations are preserved in `supabase/migration-archive/local-unmatched/`.

## Recovery steps

1. Preserve all 24 production migration-history records unchanged.
2. Restore each production SQL statement to `supabase/migrations/<version>_<name>.sql`.
3. Archive the three timestamp-mismatched repository files outside the active migrations directory.
4. Verify that the active local migration versions and names match the 24 production records exactly.
5. Run migration validation and BLC CI before considering any production BLC migration.

## Boundaries

- This recovery changes GitHub repository files only.
- It does not write to Supabase or alter production migration history.
- It does not apply/revert schema changes or modify user data.
- It does not change Storage buckets or Storage policies.
- BLC real-money top-ups, payment processing and cash-outs remain disabled.
- Applying BLC migrations to production and deploying the application require separate explicit approval.

## Production migrations restored

| Version | Name |
|---|---|
| 20261117125934 | baddielink_core_foundation |
| 20261117135022 | baddielink_age_safety_and_access_grants |
| 20261117135257 | baddielink_adult_gate_and_private_photo_storage |
| 20261117135356 | baddielink_photo_access_hardening |
| 20261117135407 | baddielink_photo_limit_concurrency_guard |
| 20261117211105 | events_and_reputation_foundation |
| 20261117212451 | restrict_profile_photo_owner_updates |
| 20261117212957 | event_cover_image_storage |
| 20261117213055 | organizer_applications_and_event_reports |
| 20261117213149 | index_event_reports_by_reporter |
| 20261117214041 | baddielink_admin_console_foundation |
| 20261117214108 | baddielink_admin_access_check |
| 20261117214545 | protect_baddielink_owner_role |
| 20261117214633 | baddielink_owner_role_directory |
| 20261117214645 | baddielink_owner_access_check |
| 20261117214732 | baddielink_admin_storage_and_audit_indexes |
| 20261118001833 | baddielink_salons_foundation |
| 20261118001917 | salons_security_hardening |
| 20261119122243 | default_people_discovery_on |
| 20261119135359 | space_messaging_foundation |
| 20261119135415 | space_messaging_policy_hardening |
| 20261119141522 | space_messaging_permission_hardening |
| 20261119194013 | harden_private_admin_roles_rls |
| 20261119220202 | harden_reports_and_salon_memberships |

## Archived repository-only files

- `20261117180000_default_people_discovery_on.sql`
- `20261118150000_baddielink_salons_foundation.sql`
- `20261118170000_salons_security_hardening.sql`
