-- New BaddieLink accounts are discoverable by default.
-- Existing member choices are intentionally preserved.
-- RLS still requires profile approval, adult declaration by both users,
-- and excludes users who have blocked one another.
ALTER TABLE public.profiles
  ALTER COLUMN is_discoverable SET DEFAULT true;
