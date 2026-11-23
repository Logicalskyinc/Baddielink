-- Allow email-confirmed adult members to use member features before profile approval.
-- Profile approval continues to control discovery visibility.
-- This migration is a reviewed candidate and has NOT been applied to Supabase.

BEGIN;

CREATE OR REPLACE FUNCTION private.is_active_member()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    (SELECT auth.uid()) IS NOT NULL
    AND EXISTS (
      SELECT 1
      FROM auth.users u
      JOIN public.profiles p ON p.id = u.id
      WHERE u.id = (SELECT auth.uid())
        AND u.email_confirmed_at IS NOT NULL
        AND p.moderation_status NOT IN ('restricted', 'removed')
        AND private.is_adult_declared(u.id)
    );
$function$;

REVOKE ALL ON FUNCTION private.is_active_member() FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.is_active_member() TO authenticated;

-- Events: any active member may submit an event for review.
-- Only an approved/trusted organizer may submit directly as published.
DROP POLICY IF EXISTS events_submit_or_organizer_publish ON public.events;
CREATE POLICY events_submit_or_organizer_publish
ON public.events
FOR INSERT
TO authenticated
WITH CHECK (
  created_by = (SELECT auth.uid())
  AND (SELECT private.is_active_member())
  AND (
    status = 'pending_review'
    OR (
      status = 'published'
      AND EXISTS (
        SELECT 1
        FROM public.event_organizers eo
        WHERE eo.user_id = (SELECT auth.uid())
          AND eo.status IN ('approved', 'trusted')
      )
    )
  )
);

DROP POLICY IF EXISTS events_update_own_pending_or_organizer ON public.events;
CREATE POLICY events_update_own_pending_or_organizer
ON public.events
FOR UPDATE
TO authenticated
USING (
  created_by = (SELECT auth.uid())
  AND (SELECT private.is_active_member())
  AND (
    status = 'pending_review'
    OR (
      status = 'published'
      AND EXISTS (
        SELECT 1
        FROM public.event_organizers eo
        WHERE eo.user_id = (SELECT auth.uid())
          AND eo.status IN ('approved', 'trusted')
      )
    )
  )
)
WITH CHECK (
  created_by = (SELECT auth.uid())
  AND (SELECT private.is_active_member())
  AND (
    status IN ('pending_review', 'cancelled')
    OR (
      status = 'published'
      AND EXISTS (
        SELECT 1
        FROM public.event_organizers eo
        WHERE eo.user_id = (SELECT auth.uid())
          AND eo.status IN ('approved', 'trusted')
      )
    )
  )
);

-- Organizer applications can be submitted while the member profile is pending.
DROP POLICY IF EXISTS organizer_applications_insert_own ON public.organizer_applications;
CREATE POLICY organizer_applications_insert_own
ON public.organizer_applications
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = (SELECT auth.uid())
  AND (SELECT private.is_active_member())
);

-- Members may create Salons after email confirmation and adult declaration.
-- Discovery visibility remains unchanged and approved-only.
DROP POLICY IF EXISTS spaces_insert_approved_adult_owner ON public.spaces;
CREATE POLICY spaces_insert_approved_adult_owner
ON public.spaces
FOR INSERT
TO authenticated
WITH CHECK (
  owner_id = (SELECT auth.uid())
  AND space_type = 'salon'
  AND status = 'active'
  AND (SELECT private.is_active_member())
);

-- Self-join and rejoin eligibility is account activation, not profile approval.
DROP POLICY IF EXISTS memberships_insert_self_join ON public.space_memberships;
CREATE POLICY memberships_insert_self_join
ON public.space_memberships
FOR INSERT
TO authenticated
WITH CHECK (
  user_id = (SELECT auth.uid())
  AND role = 'member'
  AND (SELECT private.is_active_member())
  AND EXISTS (
    SELECT 1
    FROM public.spaces s
    WHERE s.id = space_memberships.space_id
      AND s.space_type = 'salon'
      AND s.status = 'active'
      AND s.visibility = 'public'
      AND (
        (s.join_policy = 'open' AND space_memberships.status = 'active')
        OR (s.join_policy = 'approval' AND space_memberships.status = 'pending')
      )
  )
);

DROP POLICY IF EXISTS memberships_self_rejoin ON public.space_memberships;
CREATE POLICY memberships_self_rejoin
ON public.space_memberships
FOR UPDATE
TO authenticated
USING (
  user_id = (SELECT auth.uid())
  AND role = 'member'
  AND status = 'removed'
)
WITH CHECK (
  user_id = (SELECT auth.uid())
  AND role = 'member'
  AND (SELECT private.is_active_member())
  AND EXISTS (
    SELECT 1
    FROM public.spaces s
    WHERE s.id = space_memberships.space_id
      AND s.space_type = 'salon'
      AND s.status = 'active'
      AND s.visibility = 'public'
      AND (
        (s.join_policy = 'open' AND space_memberships.status = 'active')
        OR (s.join_policy = 'approval' AND space_memberships.status = 'pending')
      )
  )
);

-- Owners may invite any active, email-confirmed adult member, even while
-- the invitee's public profile is awaiting moderation.
DROP POLICY IF EXISTS memberships_owner_invite ON public.space_memberships;
CREATE POLICY memberships_owner_invite
ON public.space_memberships
FOR INSERT
TO authenticated
WITH CHECK (
  user_id <> (SELECT auth.uid())
  AND role = 'member'
  AND status = 'active'
  AND (SELECT private.is_space_owner(space_id))
  AND EXISTS (
    SELECT 1
    FROM auth.users u
    JOIN public.profiles p ON p.id = u.id
    WHERE u.id = space_memberships.user_id
      AND u.email_confirmed_at IS NOT NULL
      AND p.moderation_status NOT IN ('restricted', 'removed')
      AND private.is_adult_declared(u.id)
  )
);

DROP POLICY IF EXISTS memberships_owner_manage ON public.space_memberships;
CREATE POLICY memberships_owner_manage
ON public.space_memberships
FOR UPDATE
TO authenticated
USING (
  role <> 'owner'
  AND (SELECT private.is_space_owner(space_memberships.space_id))
)
WITH CHECK (
  role IN ('member', 'moderator')
  AND status IN ('active', 'removed', 'banned')
  AND (SELECT private.is_space_owner(space_memberships.space_id))
  AND (
    status <> 'active'
    OR EXISTS (
      SELECT 1
      FROM auth.users u
      JOIN public.profiles p ON p.id = u.id
      WHERE u.id = space_memberships.user_id
        AND u.email_confirmed_at IS NOT NULL
        AND p.moderation_status NOT IN ('restricted', 'removed')
        AND private.is_adult_declared(u.id)
    )
  )
);

-- Space-message access follows account activation. Discovery remains approved-only.
CREATE OR REPLACE FUNCTION private.can_access_space_messages(
  target_space_id uuid,
  target_sender_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = ''
AS $function$
  SELECT
    (SELECT auth.uid()) IS NOT NULL
    AND (SELECT private.is_active_member())
    AND EXISTS (
      SELECT 1
      FROM public.spaces s
      JOIN public.space_memberships m ON m.space_id = s.id
      JOIN auth.users sender_auth ON sender_auth.id = target_sender_id
      JOIN public.profiles sender_profile ON sender_profile.id = target_sender_id
      WHERE s.id = target_space_id
        AND s.status = 'active'
        AND m.user_id = (SELECT auth.uid())
        AND m.status = 'active'
        AND sender_auth.email_confirmed_at IS NOT NULL
        AND sender_profile.moderation_status NOT IN ('restricted', 'removed')
        AND private.is_adult_declared(target_sender_id)
        AND NOT private.is_blocked_with(target_sender_id)
    );
$function$;

REVOKE ALL ON FUNCTION private.can_access_space_messages(uuid, uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION private.can_access_space_messages(uuid, uuid) TO authenticated;

COMMIT;
