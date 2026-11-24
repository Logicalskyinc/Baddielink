-- Harden the internal administrator role directory.
-- Access remains exclusively through owner-checked SECURITY DEFINER functions.

ALTER TABLE private.admin_roles ENABLE ROW LEVEL SECURITY;

DO $$
DECLARE
  role_table_oid oid := 'private.admin_roles'::regclass;
  postgres_oid oid := (SELECT oid FROM pg_roles WHERE rolname = 'postgres');
BEGIN
  IF NOT (SELECT relrowsecurity FROM pg_class WHERE oid = role_table_oid) THEN
    RAISE EXCEPTION 'RLS was not enabled on private.admin_roles';
  END IF;

  IF EXISTS (SELECT 1 FROM pg_policy WHERE polrelid = role_table_oid) THEN
    RAISE EXCEPTION 'private.admin_roles must not have client-facing RLS policies';
  END IF;

  IF has_table_privilege('anon', role_table_oid, 'SELECT')
     OR has_table_privilege('anon', role_table_oid, 'INSERT')
     OR has_table_privilege('anon', role_table_oid, 'UPDATE')
     OR has_table_privilege('anon', role_table_oid, 'DELETE')
     OR has_table_privilege('authenticated', role_table_oid, 'SELECT')
     OR has_table_privilege('authenticated', role_table_oid, 'INSERT')
     OR has_table_privilege('authenticated', role_table_oid, 'UPDATE')
     OR has_table_privilege('authenticated', role_table_oid, 'DELETE') THEN
    RAISE EXCEPTION 'Client roles must not have direct privileges on private.admin_roles';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'is_baddielink_admin'
      AND p.prosecdef AND p.proowner = postgres_oid
  ) THEN
    RAISE EXCEPTION 'Expected postgres-owned SECURITY DEFINER admin check is missing';
  END IF;

  IF NOT EXISTS (
    SELECT 1 FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.proname = 'admin_set_moderator'
      AND p.prosecdef AND p.proowner = postgres_oid
  ) THEN
    RAISE EXCEPTION 'Expected postgres-owned SECURITY DEFINER moderator function is missing';
  END IF;
END
$$;
