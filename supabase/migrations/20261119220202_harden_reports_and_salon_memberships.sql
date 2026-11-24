-- Enforce moderation queue defaults and correct Salon membership status checks.
-- This migration changes schema policy definitions only; it does not touch user rows.

DROP POLICY IF EXISTS reports_insert_own ON public.reports;
CREATE POLICY reports_insert_own
ON public.reports
FOR INSERT
TO authenticated
WITH CHECK (
  reporter_id = (SELECT auth.uid())
  AND ((reported_user_id IS NULL) OR (reported_user_id <> (SELECT auth.uid())))
  AND reports.status = 'open'
);

DROP POLICY IF EXISTS event_reports_insert_published ON public.event_reports;
CREATE POLICY event_reports_insert_published
ON public.event_reports
FOR INSERT
TO authenticated
WITH CHECK (
  reporter_id = (SELECT auth.uid())
  AND (SELECT private.is_adult_declared((SELECT auth.uid())))
  AND event_reports.status = 'pending'
  AND EXISTS (
    SELECT 1
    FROM public.events e
    WHERE e.id = event_reports.event_id
      AND e.status = 'published'
      AND e.created_by <> (SELECT auth.uid())
  )
);

DROP POLICY IF EXISTS memberships_insert_self_join ON public.space_memberships;
CREATE POLICY memberships_insert_self_join
ON public.space_memberships
FOR INSERT
TO authenticated
WITH CHECK (
  space_memberships.user_id = (SELECT auth.uid())
  AND space_memberships.role = 'member'
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
  AND EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = (SELECT auth.uid())
      AND p.moderation_status = 'approved'
  )
  AND (SELECT private.is_adult_declared((SELECT auth.uid())))
);

DROP POLICY IF EXISTS memberships_self_rejoin ON public.space_memberships;
CREATE POLICY memberships_self_rejoin
ON public.space_memberships
FOR UPDATE
TO authenticated
USING (
  space_memberships.user_id = (SELECT auth.uid())
  AND space_memberships.role = 'member'
  AND space_memberships.status = 'removed'
)
WITH CHECK (
  space_memberships.user_id = (SELECT auth.uid())
  AND space_memberships.role = 'member'
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
  AND EXISTS (
    SELECT 1
    FROM public.profiles p
    WHERE p.id = (SELECT auth.uid())
      AND p.moderation_status = 'approved'
  )
  AND (SELECT private.is_adult_declared((SELECT auth.uid())))
);